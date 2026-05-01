# Gauge Code Review — Task 9: Transport Core Routing (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Implement the core MCP Streamable HTTP transport in `emacs-mcp-transport.el`: request routing by HTTP method, session ID extraction and validation, POST handling for single requests and batches (non-deferred), GET/DELETE handling, and session activity tracking on every request. This task handles the synchronous request/response path. Deferred/SSE lifecycle is Task 10.

**Functions to implement**:
- `emacs-mcp--transport-handle-request` — Top-level handler called by HTTP server; routes by HTTP method to POST/GET/DELETE handlers
- `emacs-mcp--transport-validate-session` — Extract and validate `Mcp-Session-Id` header (missing -> 400, syntactically invalid -> 400, unknown/expired/terminated -> 404). On success, call `emacs-mcp--session-update-activity` to update `last-activity` and restart idle timer.
- `emacs-mcp--transport-handle-post` — Parse body (catch malformed JSON -> JSON-RPC `-32700`), handle single/batch, route initialize specially (no session required, return `Mcp-Session-Id` header), handle notifications-only (-> 202), dispatch requests to protocol, return JSON response or JSON array for batch
- `emacs-mcp--transport-handle-get` — Validate session, open SSE stream, register in session's `sse-streams`
- `emacs-mcp--transport-handle-delete` — Validate session, clean up, return 200
- `emacs-mcp--transport-send-json` — Send single JSON response with `Mcp-Session-Id` header
- `emacs-mcp--transport-send-json-batch` — Send JSON array of responses
- Batch handling: initialize in batch -> error `-32600`; notifications in batch produce no response entry

**Verification criteria** (Task 9 focus):
- POST with `initialize` creates session, returns `Mcp-Session-Id` header
- POST with valid session calls protocol dispatch
- POST without session header (non-initialize) -> 400
- POST with syntactically invalid `Mcp-Session-Id` -> 400
- POST with unknown/expired session -> 404
- POST with notifications-only -> 202 Accepted, no body
- POST with batch of 2 requests -> JSON array of 2 responses
- POST with `initialize` inside batch -> error `-32600`
- POST with malformed JSON body -> JSON-RPC error `-32700` with correct response shape
- POST with missing/unexpected `Accept` header still processes correctly (server is lenient, FR-1.2)
- GET without session -> 400
- DELETE without session -> 400
- DELETE with valid session -> 200 and session removed

## Coding Standards (from Constitution)

- Style: Follow Emacs Lisp conventions, `checkdoc` compliant
- Naming: Public symbols `emacs-mcp-`, internal `emacs-mcp--`
- Docstrings: Every public function/variable must have a docstring passing `checkdoc`
- Byte-compilation: Clean with no warnings
- Line length: 80 columns soft limit
- No global state pollution outside the package namespace

## Full File: emacs-mcp-transport.el

```elisp
;;; emacs-mcp-transport.el --- MCP Streamable HTTP transport for emacs-mcp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; License: AGPL-3.0-or-later
;; See the file LICENSE for the full license text.

;;; Commentary:

;; This library implements the MCP Streamable HTTP transport layer,
;; bridging the HTTP server to the MCP protocol handlers.  It handles
;; session validation, POST/GET/DELETE routing, batch processing,
;; SSE streams, and deferred response lifecycle.

;;; Code:

(require 'emacs-mcp)
(require 'emacs-mcp-jsonrpc)
(require 'emacs-mcp-session)
(require 'emacs-mcp-protocol)
(require 'emacs-mcp-http)

;;;; Session validation

(defun emacs-mcp--transport-validate-session (headers)
  "Validate the Mcp-Session-Id from HEADERS.
Returns (session . session-id) on success.
Returns (:error . STATUS-CODE) on failure, where STATUS-CODE is
400 for missing/invalid or 404 for unknown/expired."
  (let ((session-id (cdr (assoc "mcp-session-id" headers))))
    (cond
     ((not session-id)
      (cons :error 400))
     ((not (stringp session-id))
      (cons :error 400))
     ((string-empty-p session-id)
      (cons :error 400))
     (t
      (let ((session (emacs-mcp--session-get session-id)))
        (if session
            (progn
              (emacs-mcp--session-update-activity session)
              (cons session session-id))
          (cons :error 404)))))))

;;;; Top-level request handler

(defun emacs-mcp--transport-handle-request (process method
                                                    _path headers body)
  "Handle an MCP HTTP request from PROCESS.
METHOD is the HTTP method.  HEADERS is an alist.  BODY is a string."
  (pcase method
    ("POST" (emacs-mcp--transport-handle-post
             process headers body))
    ("GET" (emacs-mcp--transport-handle-get
            process headers))
    ("DELETE" (emacs-mcp--transport-handle-delete
              process headers))))

;;;; POST handler

(defun emacs-mcp--transport-handle-post (process headers body)
  "Handle an MCP POST request from PROCESS with HEADERS and BODY."
  (let ((parsed (condition-case _err
                    (emacs-mcp--jsonrpc-parse body)
                  (json-parse-error nil))))
    (if (not parsed)
        (emacs-mcp--transport-send-json
         process
         (emacs-mcp--jsonrpc-make-error
          :null emacs-mcp--jsonrpc-parse-error "Parse error")
         nil)
      (if (emacs-mcp--jsonrpc-batch-p parsed)
          (emacs-mcp--transport-handle-batch
           process headers parsed)
        (emacs-mcp--transport-handle-single
         process headers parsed)))))

(defun emacs-mcp--transport-handle-single (process headers msg)
  "Handle a single JSON-RPC MSG from PROCESS with HEADERS."
  (let ((method (alist-get 'method msg)))
    (cond
     ;; Initialize: no session required
     ((equal method "initialize")
      (let ((resp (emacs-mcp--protocol-dispatch msg nil)))
        (when resp
          (let ((session-id (alist-get :session-id resp)))
            ;; Remove internal metadata before sending
            (setq resp (assq-delete-all :session-id resp))
            (emacs-mcp--transport-send-json
             process resp session-id)))))
     ;; All other methods: validate session
     (t
      (let ((validation (emacs-mcp--transport-validate-session
                         headers)))
        (if (eq (car validation) :error)
            (emacs-mcp--transport-send-http-error
             process (cdr validation))
          (let* ((session-id (cdr validation))
                 (resp (emacs-mcp--protocol-dispatch
                        msg session-id)))
            ;; Check for deferred
            (cond
             ;; No response (notification)
             ((not resp)
              (emacs-mcp--http-send-response
               process 202 "Accepted" nil nil))
             ;; Deferred response
             ((alist-get :deferred resp)
              (let ((clean-resp (assq-delete-all :deferred resp)))
                (emacs-mcp--transport-open-deferred-sse
                 process session-id clean-resp)))
             ;; Normal response
             (t
              (emacs-mcp--transport-send-json
               process resp session-id))))))))))

(defun emacs-mcp--transport-handle-batch (process headers batch)
  "Handle a JSON-RPC BATCH from PROCESS with HEADERS."
  ;; Check for initialize in batch -> error
  (let ((has-init nil))
    (seq-doseq (msg batch)
      (when (equal (alist-get 'method msg) "initialize")
        (setq has-init t)))
    (if has-init
        (emacs-mcp--transport-send-json
         process
         (emacs-mcp--jsonrpc-make-error
          :null emacs-mcp--jsonrpc-invalid-request
          "initialize must not appear in a batch")
         nil)
      ;; Validate session
      (let ((validation (emacs-mcp--transport-validate-session
                         headers)))
        (if (eq (car validation) :error)
            (emacs-mcp--transport-send-http-error
             process (cdr validation))
          (let ((session-id (cdr validation))
                (responses nil)
                (has-deferred nil))
            (seq-doseq (msg batch)
              (let ((resp (emacs-mcp--protocol-dispatch
                           msg session-id)))
                (when resp
                  (when (alist-get :deferred resp)
                    (setq has-deferred t))
                  (push resp responses))))
            (cond
             ((null responses)
              (emacs-mcp--http-send-response
               process 202 "Accepted" nil nil))
             (has-deferred
              (emacs-mcp--transport-open-batch-sse
               process session-id (nreverse responses)))
             (t
              (let ((clean (mapcar
                            (lambda (r)
                              (assq-delete-all :deferred r))
                            (nreverse responses))))
                (emacs-mcp--transport-send-json-batch
                 process clean session-id))))))))))

;;;; GET handler (SSE stream)

(defun emacs-mcp--transport-handle-get (process headers)
  "Handle GET request from PROCESS with HEADERS.  Opens SSE stream."
  (let ((validation (emacs-mcp--transport-validate-session
                     headers)))
    (if (eq (car validation) :error)
        (emacs-mcp--transport-send-http-error
         process (cdr validation))
      (let* ((session-id (cdr validation))
             (session (emacs-mcp--session-get session-id)))
        ;; Open SSE stream
        (emacs-mcp--http-send-sse-headers
         process `(("Mcp-Session-Id" . ,session-id)))
        ;; Register stream
        (push process (emacs-mcp-session-sse-streams session))
        ;; Check for completed deferred responses to deliver
        (let ((deferred (emacs-mcp-session-deferred session)))
          (maphash (lambda (req-id resp)
                     (emacs-mcp--http-send-sse-event
                      process
                      (emacs-mcp--jsonrpc-serialize resp))
                     (remhash req-id deferred))
                   (copy-hash-table deferred)))))))

;;;; DELETE handler

(defun emacs-mcp--transport-handle-delete (process headers)
  "Handle DELETE request from PROCESS with HEADERS."
  (let ((validation (emacs-mcp--transport-validate-session
                     headers)))
    (if (eq (car validation) :error)
        (emacs-mcp--transport-send-http-error
         process (cdr validation))
      (let ((session-id (cdr validation)))
        (emacs-mcp--session-remove session-id)
        (emacs-mcp--http-send-response
         process 200 "OK" nil nil)))))

;;;; Response helpers

(defun emacs-mcp--transport-send-json (process response
                                               session-id)
  "Send a JSON-RPC RESPONSE to PROCESS.
Includes Mcp-Session-Id header when SESSION-ID is non-nil."
  (let ((headers `(("Content-Type" . "application/json")))
        (json (emacs-mcp--jsonrpc-serialize response)))
    (when session-id
      (push (cons "Mcp-Session-Id" session-id) headers))
    (emacs-mcp--http-send-response
     process 200 "OK" headers json)))

(defun emacs-mcp--transport-send-json-batch (process responses
                                                     session-id)
  "Send a JSON array of RESPONSES to PROCESS."
  (let ((headers `(("Content-Type" . "application/json")))
        (json (emacs-mcp--jsonrpc-serialize
               (vconcat responses))))
    (when session-id
      (push (cons "Mcp-Session-Id" session-id) headers))
    (emacs-mcp--http-send-response
     process 200 "OK" headers json)))

(defun emacs-mcp--transport-send-http-error (process status)
  "Send an HTTP error STATUS response to PROCESS."
  (let ((reason (pcase status
                  (400 "Bad Request")
                  (404 "Not Found")
                  (_ "Error"))))
    (emacs-mcp--http-send-response
     process status reason
     '(("Content-Type" . "text/plain"))
     reason)))

;;;; Deferred SSE lifecycle

(defun emacs-mcp--transport-open-deferred-sse (process
                                               session-id response)
  "Open an SSE stream for a deferred RESPONSE from PROCESS.
SESSION-ID identifies the session.  RESPONSE is the placeholder."
  (let* ((session (emacs-mcp--session-get session-id))
         (request-id (alist-get 'id response)))
    (emacs-mcp--http-send-sse-headers
     process `(("Mcp-Session-Id" . ,session-id)))
    ;; Store deferred entry with connection info
    (puthash request-id
             (list :process process :session-id session-id)
             (emacs-mcp-session-deferred session))
    ;; Start timeout timer
    (run-at-time emacs-mcp-deferred-timeout nil
                 #'emacs-mcp--transport-deferred-timeout
                 session-id request-id)
    ;; Set disconnect handler
    (process-put process :on-disconnect
                 (lambda (_proc)
                   ;; Retain deferred entry for reconnection
                   (let ((entry (gethash
                                 request-id
                                 (emacs-mcp-session-deferred
                                  session))))
                     (when (and entry (listp entry))
                       (plist-put entry :process nil)))))))

(defun emacs-mcp--transport-deferred-timeout (session-id
                                              request-id)
  "Handle deferred timeout for REQUEST-ID in SESSION-ID."
  (let ((session (emacs-mcp--session-get session-id)))
    (when session
      (let ((entry (gethash request-id
                            (emacs-mcp-session-deferred session))))
        (when entry
          ;; Send timeout error if connection is live
          (when (and (listp entry) (plist-get entry :process))
            (let ((proc (plist-get entry :process)))
              (when (process-live-p proc)
                (emacs-mcp--http-send-sse-event
                 proc
                 (emacs-mcp--jsonrpc-serialize
                  (emacs-mcp--jsonrpc-make-response
                   request-id
                   (emacs-mcp--wrap-tool-error
                    "Deferred operation timed out"))))
                (emacs-mcp--http-close-connection proc))))
          (remhash request-id
                   (emacs-mcp-session-deferred session)))))))

(defun emacs-mcp--transport-open-batch-sse (process session-id
                                                    responses)
  "Open SSE stream for a batch with deferred RESPONSES."
  (emacs-mcp--http-send-sse-headers
   process `(("Mcp-Session-Id" . ,session-id)))
  ;; Send immediate responses now, track deferred
  (dolist (resp responses)
    (if (alist-get :deferred resp)
        (let* ((clean (assq-delete-all :deferred resp))
               (req-id (alist-get 'id clean))
               (session (emacs-mcp--session-get session-id)))
          (puthash req-id
                   (list :process process
                         :session-id session-id)
                   (emacs-mcp-session-deferred session))
          (run-at-time emacs-mcp-deferred-timeout nil
                       #'emacs-mcp--transport-deferred-timeout
                       session-id req-id))
      (emacs-mcp--http-send-sse-event
       process
       (emacs-mcp--jsonrpc-serialize resp)))))

(provide 'emacs-mcp-transport)
;;; emacs-mcp-transport.el ends here
```

## Full File: test/emacs-mcp-test-transport.el

```elisp
;;; emacs-mcp-test-transport.el --- Tests for emacs-mcp-transport -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the MCP Streamable HTTP transport layer.

;;; Code:

(require 'ert)
(require 'emacs-mcp-transport)

(defmacro emacs-mcp-test-with-transport (&rest body)
  "Run BODY with clean session/tool state for transport tests."
  (declare (indent 0))
  `(let ((emacs-mcp--sessions (make-hash-table :test 'equal))
         (emacs-mcp--tools nil)
         (emacs-mcp-session-timeout 1800)
         (emacs-mcp-deferred-timeout 300)
         (emacs-mcp--project-dir "/test/project"))
     (unwind-protect
         (progn ,@body)
       (maphash (lambda (_id session)
                  (when (emacs-mcp-session-timer session)
                    (cancel-timer
                     (emacs-mcp-session-timer session))))
                emacs-mcp--sessions))))

;;;; Session validation tests

(ert-deftest emacs-mcp-test-transport-validate-missing ()
  "Missing session ID returns 400."
  (let ((result (emacs-mcp--transport-validate-session nil)))
    (should (eq (car result) :error))
    (should (= (cdr result) 400))))

(ert-deftest emacs-mcp-test-transport-validate-empty ()
  "Empty session ID returns 400."
  (let ((result (emacs-mcp--transport-validate-session
                 '(("mcp-session-id" . "")))))
    (should (eq (car result) :error))
    (should (= (cdr result) 400))))

(ert-deftest emacs-mcp-test-transport-validate-unknown ()
  "Unknown session ID returns 404."
  (emacs-mcp-test-with-transport
    (let ((result (emacs-mcp--transport-validate-session
                   '(("mcp-session-id" . "nonexistent")))))
      (should (eq (car result) :error))
      (should (= (cdr result) 404)))))

(ert-deftest emacs-mcp-test-transport-validate-valid ()
  "Valid session ID returns session."
  (emacs-mcp-test-with-transport
    (let* ((id (emacs-mcp--session-create "/test"))
           (result (emacs-mcp--transport-validate-session
                    `(("mcp-session-id" . ,id)))))
      (should-not (eq (car result) :error))
      (should (equal (cdr result) id)))))

(ert-deftest emacs-mcp-test-transport-validate-updates-activity ()
  "Validation updates session activity timestamp."
  (emacs-mcp-test-with-transport
    (let* ((id (emacs-mcp--session-create "/test"))
           (session (emacs-mcp--session-get id))
           (old-time (emacs-mcp-session-last-activity session)))
      (sleep-for 0.01)
      (emacs-mcp--transport-validate-session
       `(("mcp-session-id" . ,id)))
      (should (> (emacs-mcp-session-last-activity session)
                 old-time)))))

;;;; HTTP error helper

(ert-deftest emacs-mcp-test-transport-error-400 ()
  "400 error has correct reason."
  (let ((reason (pcase 400 (400 "Bad Request") (_ "Error"))))
    (should (equal reason "Bad Request"))))

(ert-deftest emacs-mcp-test-transport-error-404 ()
  "404 error has correct reason."
  (let ((reason (pcase 404 (404 "Not Found") (_ "Error"))))
    (should (equal reason "Not Found"))))

(provide 'emacs-mcp-test-transport)
;;; emacs-mcp-test-transport.el ends here
```

## Review Checklist

### 1. Session Validation Correctness

- `emacs-mcp--transport-validate-session` receives HEADERS as an alist. When called with `nil` (no headers), does `(cdr (assoc "mcp-session-id" nil))` return nil correctly? Verify the nil-headers edge case.
- The function checks `(not session-id)` then `(not (stringp session-id))`. Since `assoc` returns nil when key is not found, `cdr` of nil is nil, and `(not nil)` is t — so the first `cond` clause fires. However, if the header value is somehow a non-string (e.g., a symbol), the second clause fires. In practice, HTTP header values are always strings; this guard is defensive. NOTE.
- `(string-empty-p session-id)` — correct check for empty string `""`.
- On success: returns `(cons session session-id)` where `car` is the session struct and `cdr` is the session-id string. The caller pattern is `(eq (car validation) :error)` to check for failure, else `(cdr validation)` to get session-id. But `(cdr (cons session session-id))` is `session-id` (the string), not `session`. The caller never extracts the session struct from the success return — it re-fetches via `(emacs-mcp--session-get session-id)`. Verify this is intentional and consistent across all call sites. Is the session struct in `car` ever used?
- `emacs-mcp--session-update-activity` is called on the session struct (the raw object), NOT on the session-id. Confirm the function signature matches.

### 2. `emacs-mcp--transport-handle-request` — unhandled methods

- The `pcase` has three arms: POST, GET, DELETE. Any other HTTP method (PUT, PATCH, HEAD, OPTIONS) returns nil silently — no response is sent to the process. The MCP spec requires only these three methods, so other methods are not expected at the `/mcp` endpoint. However, a misbehaving client sending a PUT would get no response and the connection would hang. Should there be a fallthrough that sends 405 Method Not Allowed? BLOCKING or WARNING based on spec interpretation.
- The `_path` parameter is ignored. In a real deployment, the server likely restricts to `/mcp`. If the HTTP server calls this handler for all paths, non-`/mcp` paths are silently accepted. Is path filtering done upstream in `emacs-mcp-http.el`? If not, this is a gap.

### 3. POST — Malformed JSON error code

- `(condition-case _err (emacs-mcp--jsonrpc-parse body) (json-parse-error nil))` catches `json-parse-error` and returns nil.
- The error response is `(emacs-mcp--jsonrpc-make-error :null emacs-mcp--jsonrpc-parse-error "Parse error")`.
- Per JSON-RPC 2.0, parse errors use code `-32700` and the `id` must be `null`. Using `:null` for the id is correct IF `:null` serializes to JSON `null`. Verify: does `emacs-mcp--jsonrpc-serialize` handle `:null` → `null`?
- The error string is `"Parse error"` — matches JSON-RPC 2.0 standard message. Correct.
- CRITICAL: What exceptions does `emacs-mcp--jsonrpc-parse` raise? Only `json-parse-error`? Or could it raise other signals (e.g., `error`, `wrong-type-argument`) on pathological input? If `emacs-mcp--jsonrpc-parse` uses Emacs 29's `json-parse-string`, it raises `json-parse-error` on bad JSON. But what if `body` is nil (no body in the POST)? `json-parse-string nil` signals `wrong-type-argument`. This would propagate uncaught and crash the handler.

### 4. POST — Single request: initialize path

- `emacs-mcp--protocol-dispatch msg nil` is called with nil session-id for initialize. The protocol handler returns a response with `:session-id` metadata attached.
- `(alist-get :session-id resp)` extracts the new session ID.
- `(assq-delete-all :session-id resp)` removes the metadata key. CRITICAL: `assq-delete-all` uses `eq` for key comparison. `:session-id` is a keyword symbol. `alist-get` with default third arg uses `equal`. Both should work with keyword symbols since `(eq :session-id :session-id)` is t in Elisp (keywords are interned). Correct.
- `(when resp ...)` — if `emacs-mcp--protocol-dispatch` returns nil for initialize (should not happen, but hypothetically), nothing is sent. The client gets no response and hangs. Minor robustness gap. NOTE.

### 5. POST — Single request: notification path

- Non-initialize requests: session is validated, then `emacs-mcp--protocol-dispatch` is called.
- If the method is a notification (no `id`), the protocol returns nil.
- `(not resp)` triggers `(emacs-mcp--http-send-response process 202 "Accepted" nil nil)`.
- This sends 202 for ANY notification, including `notifications/initialized`. Per FR-1.2: "If the input consists solely of notifications and/or responses, the server SHALL return HTTP 202 Accepted." A single notification is "solely notifications" — 202 is correct.
- NOTE: `notifications/initialized` requires session validation (handled). But what if a client sends `notifications/initialized` BEFORE `initialize` — they have no session-id, validation fails with 400. This is correct behavior (session must exist first).

### 6. POST — Batch: initialize detection

- `seq-doseq` iterates the batch. `(equal (alist-get 'method msg) "initialize")` — uses `equal` for string comparison. Correct.
- If initialize is found, returns a JSON-RPC error with code `-32600` (invalid request) and id `:null`. Per the task spec and FR-1.2, this is correct.
- CRITICAL: The batch is a vector (parsed from JSON array). Does `seq-doseq` work with vectors? Yes, `seq-doseq` is sequence-generic. Correct.
- The early-exit from initialize detection uses `setq has-init t` inside `seq-doseq` — there is no early break. `seq-doseq` always iterates the full batch even after finding initialize. This is slightly inefficient but not a bug.

### 7. POST — Batch: response collection ordering

- `(push resp responses)` accumulates responses in reverse order. `(nreverse responses)` corrects ordering.
- Per JSON-RPC 2.0: "The Response objects being returned from a batch call MAY be returned in any order within the Array." Ordering is not required. However, matching request order is conventional. The `nreverse` reverses the push order, yielding the original batch order — correct.
- Notifications produce no response entry (correct: `(when resp ...)` skips nil returns).

### 8. POST — Batch: notifications-only batch -> 202

- If ALL batch items are notifications, `responses` is nil.
- `(null responses)` is t -> sends 202 Accepted. Correct per FR-1.2.
- But session validation still occurs BEFORE dispatching notifications. This means a notifications-only batch still requires a valid session. Is this correct? The spec says non-initialize requests require a session — even notifications. This is consistent with the session model.

### 9. `emacs-mcp--transport-handle-get` — session struct extraction

- `(let* ((session-id (cdr validation)) (session (emacs-mcp--session-get session-id)))` — re-fetches session from the registry by ID. The session struct from `(car validation)` in `emacs-mcp--transport-validate-session` is already available but not used. This double-lookup is redundant but harmless.
- `(emacs-mcp-session-sse-streams session)` — accesses the `sse-streams` field of the session struct. `push process` modifies the session's stream list. This is side-effectful in-place modification via `setf`... wait: `(push process (emacs-mcp-session-sse-streams session))` — `push` on a `cl-defstruct` accessor slot. Does this work? `push` expands to `(setf place (cons val place))`. `cl-defstruct` generates `setf`-compatible accessors only if the slot is defined with `:read-only nil` (default). Verify that `emacs-mcp-session-sse-streams` supports `setf`. If `emacs-mcp-session` is defined with `cl-defstruct`, this should work. CRITICAL to verify.

### 10. `emacs-mcp--transport-handle-get` — deferred delivery on reconnect

- `(copy-hash-table deferred)` is used to iterate while modifying the original table. `maphash` on a copy, `remhash` on the original — this avoids modifying the table during iteration, which is correct. Correct.
- But: the deferred hash at this point contains COMPLETED responses (stored by `emacs-mcp-complete-deferred`). However, during an active deferred operation, the hash stores a plist `(:process PROC :session-id SID)`, NOT a JSON-RPC response. The GET handler blindly calls `emacs-mcp--jsonrpc-serialize` on every value in the deferred hash — if the value is a plist (in-progress deferred), this would serialize a plist, not a JSON-RPC response. CRITICAL BUG: the GET reconnection logic does not distinguish between in-progress deferred entries and completed responses.

### 11. `emacs-mcp--transport-handle-delete` — response after session removal

- `emacs-mcp--session-remove session-id` removes the session. Then `emacs-mcp--http-send-response` sends 200. This order is correct — the session is cleaned up before responding.
- The spec says DELETE returns 200 on success and 404 if session doesn't exist. Session validation catches the 404 case before reaching `emacs-mcp--session-remove`. Correct.

### 12. `emacs-mcp--transport-send-json` — header ordering

- `(push (cons "Mcp-Session-Id" session-id) headers)` prepends the session header. The `Content-Type` header is defined first in the `let`, then session-id is pushed to front. Header order doesn't matter for HTTP correctness but note that `push` mutates the binding, not the original list (since `headers` is a fresh list from the backtick). Correct.

### 13. `emacs-mcp--transport-send-json-batch` — vector serialization

- `(vconcat responses)` converts the response list to a vector. Then `emacs-mcp--jsonrpc-serialize` of a vector — verify this serializes to a JSON array `[...]`. Correct per `json-serialize` behavior with vectors.

### 14. Test coverage gaps

- No test for `emacs-mcp--transport-handle-post` with malformed JSON body — the parse error path is untested.
- No test for `emacs-mcp--transport-handle-post` with `initialize` method (creating a session and returning `Mcp-Session-Id` header).
- No test for POST with valid session dispatching to protocol.
- No test for notifications-only -> 202.
- No test for batch with initialize in it -> `-32600`.
- No test for batch with 2 requests -> JSON array.
- No test for `emacs-mcp--transport-handle-get` (SSE stream open).
- No test for `emacs-mcp--transport-handle-delete`.
- The test file only covers session validation and basic error reason strings. The routing logic has zero direct test coverage.
- Tests `emacs-mcp-test-transport-error-400` and `emacs-mcp-test-transport-error-404` test inline pcase expressions, not `emacs-mcp--transport-send-http-error` itself. They would pass regardless of whether the real function is correct.

### 15. `emacs-mcp--transport-handle-batch` — `assq-delete-all` in batch

- In the all-synchronous batch path: `(assq-delete-all :deferred r)` is called on each response even though `has-deferred` is false at this point. When `has-deferred` is false, no response has `:deferred` in it, so `assq-delete-all` is a no-op. Correct but slightly wasteful.

### 16. Missing `emacs-mcp--transport-handle-request` fallthrough

- See point 2 above. No `_` arm in the pcase returns nil (no response). Confirm whether the HTTP server layer handles this or expects the transport to always respond.

List issues with severity: BLOCKING / WARNING / NOTE.
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
