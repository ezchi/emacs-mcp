# Gauge Code Review — Task 10: Transport SSE & Deferred Response Lifecycle (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Extend the transport layer with deferred response handling and SSE stream lifecycle in `emacs-mcp-transport.el`. When a tool handler returns the `deferred` symbol, the transport opens an SSE stream instead of returning JSON, stores the pending request, and manages timeouts and reconnection.

**Functions to implement**:
- `emacs-mcp--transport-open-sse-stream` — Send SSE response headers (`Content-Type: text/event-stream`), keep connection open
- `emacs-mcp--transport-send-sse-event` — Send JSON-RPC response as SSE `data:` event
- `emacs-mcp--transport-handle-deferred` — Store deferred entry in session's `deferred` hash, start timeout timer via `run-at-time` using `emacs-mcp-deferred-timeout`, track SSE connection for delivery
- Update `emacs-mcp--transport-handle-post` — When a tool dispatch returns `deferred`, switch to SSE response mode. For batches: if ANY request triggers deferred, switch entire batch to SSE mode — send immediate responses as SSE events right away, send deferred responses when they complete.
- Update `emacs-mcp--transport-handle-get` — On GET SSE connection, check session's `deferred` hash for completed-but-undelivered responses, deliver them on the new stream (reconnection support, FR-5.5).
- Integration with `emacs-mcp-complete-deferred` — When called, write response as SSE event on the stored stream, close the stream, remove deferred entry.

**Verification criteria** (Task 10 focus):
- Deferred tool: POST returns SSE headers, then completion delivers JSON-RPC response as SSE event, stream closes
- Deferred timeout: after `emacs-mcp-deferred-timeout` seconds, server sends tool execution error ("Deferred operation timed out") on SSE stream, closes stream, removes deferred entry
- Batch with mixed immediate + deferred: SSE mode used, immediate responses sent as SSE events first, deferred sent when completed, stream closes after all delivered
- GET SSE reconnection: deferred response completed while client disconnected is delivered on next GET SSE stream
- SSE stream disconnect detected via connection sentinel, deferred entry retained for timeout duration
- All tests pass; file byte-compiles clean

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

### 1. `emacs-mcp--transport-open-deferred-sse` — Missing dedicated function

- The task spec requires implementing `emacs-mcp--transport-open-sse-stream` (send SSE headers, keep connection open) and `emacs-mcp--transport-send-sse-event` (send JSON-RPC response as SSE `data:` event) as named public API functions. The implementation instead delegates directly to `emacs-mcp--http-send-sse-headers` and `emacs-mcp--http-send-sse-event` without defining the wrapper functions specified in the task. The transport-level wrappers with their own docstrings are absent. NOTE whether this gap constitutes BLOCKING: the behavior may be functionally equivalent if the http-layer functions are sufficient.

### 2. `emacs-mcp--transport-handle-deferred` — Named function absent

- The spec requires a dedicated `emacs-mcp--transport-handle-deferred` function. The implementation inlines the deferred setup inside `emacs-mcp--transport-open-deferred-sse`. The named entry point is missing. If external callers need to trigger deferred handling by name, this is BLOCKING.

### 3. Disconnect sentinel — `process-put :on-disconnect` mechanism

- `(process-put process :on-disconnect (lambda ...))` stores a disconnect callback on the process property list. But: Emacs network processes do NOT automatically invoke `:on-disconnect` process properties. The sentinel must be set via `(set-process-sentinel process ...)`. If `emacs-mcp-http.el` installs a sentinel that reads `:on-disconnect` from the process and calls it, then this pattern works. If not, the disconnect handler NEVER fires. CRITICAL: verify that `emacs-mcp--http` sentinel machinery invokes `:on-disconnect` properties. If it does not, the reconnection state (`plist-put entry :process nil`) is never set, and the timeout fires on a dead process without updating the entry.

### 4. `plist-put entry :process nil` — Mutation semantics

- `(plist-put entry :process nil)` — `plist-put` returns the modified plist but does NOT guarantee in-place mutation when the list is not being modified at its `car`. If the `:process` key already exists, `plist-put` finds the cell and updates the `cadr` in-place. But if the plist is stored in a hash table as `(gethash request-id deferred)`, and `plist-put` allocates a new list, the hash table entry is NOT updated. The local `entry` binding points to the original list; `plist-put` may return a new list. The hash table still holds the old list.
- Correct approach: `(puthash request-id (plist-put entry :process nil) deferred)` to update the hash table. The current code does NOT update the hash table. BLOCKING BUG.

### 5. `emacs-mcp--transport-deferred-timeout` — Timeout fires after `complete-deferred`

- When `emacs-mcp-complete-deferred` successfully delivers a response, it calls `puthash request-id response ...` (a complete JSON-RPC response object). Later, the timeout timer fires and calls `gethash request-id ...`. At this point, the value is a response alist, not a plist. The check `(listp entry)` is true for both alists and plists, so `(plist-get entry :process)` is called on a JSON-RPC response alist — e.g., `((jsonrpc . "2.0") (id . 1) (result . ...))`. `plist-get` looks for `:process` in this alist, finds nothing, returns nil. The `when` guard is nil — no SSE event is sent. Then `remhash` fires and removes the entry. This is actually safe behavior: the timer cleans up an already-completed entry without double-sending. However, it is fragile — the code relies on `plist-get` returning nil for non-plist data. A more robust check would be to test whether the value is a plist (has `:process` key) or a completed response before acting. NOTE but worth documenting.

### 6. `emacs-mcp-complete-deferred` integration — SSE delivery not performed

- `emacs-mcp-complete-deferred` (defined in `emacs-mcp-protocol.el`) stores the completed response in the session's deferred hash via `puthash`. It does NOT send the SSE event. The transport is expected to detect the stored response and deliver it via GET reconnection.
- BUT: if the SSE connection is still live (the client is still connected), the response is only delivered when the client re-GETs (reconnects). There is no active push on the existing open stream.
- The task spec says: "Integration with `emacs-mcp-complete-deferred` — When called, write response as SSE event on the stored stream, close the stream, remove deferred entry." The current `emacs-mcp-complete-deferred` does NOT write to the stream — it only stores in the hash. The transport layer has no callback mechanism to actively push on the live stream. BLOCKING: the completion-to-stream delivery path is broken for connected clients. The deferred entry stores `:process PROC` but `complete-deferred` ignores it. The stream stays open forever (until timeout or disconnect) even after the result is ready.

### 7. `emacs-mcp--transport-handle-get` — Deferred hash type confusion

- During `emacs-mcp--transport-handle-get`, the code iterates `(emacs-mcp-session-deferred session)` and calls `emacs-mcp--jsonrpc-serialize resp` on every value. The deferred hash can contain two types of values: (a) in-progress entries: plists `(:process PROC :session-id SID)`, and (b) completed entries: JSON-RPC response alists.
- When a client reconnects via GET while deferred operations are in-progress (type a), the code tries to serialize a plist as a JSON-RPC response and sends it as an SSE event. This corrupts the SSE stream with garbage data. BLOCKING BUG: the GET reconnect handler must distinguish completed responses from in-progress deferred entries.
- A completed entry can be identified by checking for `(alist-get 'jsonrpc resp)` or checking whether `(plist-get resp :process)` is non-nil for in-progress entries.

### 8. `emacs-mcp--transport-open-batch-sse` — Stream never closes

- `emacs-mcp--transport-open-batch-sse` sends immediate responses as SSE events and registers deferred entries with timeout timers. But: after all deferred entries complete (or time out), there is NO mechanism to close the SSE stream.
- `emacs-mcp--transport-deferred-timeout` calls `emacs-mcp--http-close-connection` only when `(process-live-p proc)` is true. But for batch deferred entries, the connection is shared across multiple deferred requests. After each one times out and closes, the process is closed. If a second deferred entry still has a reference to the (now-closed) process, `process-live-p` returns nil and the timeout handler silently removes the entry without sending a response.
- There is no tracking of "all deferred entries in this batch have been resolved, now close the stream." BLOCKING: batch SSE streams with multiple deferred entries are never cleanly closed.

### 9. `emacs-mcp--transport-open-batch-sse` — `assq-delete-all` side-effect on shared structure

- `(let* ((clean (assq-delete-all :deferred resp)) ...)` — `assq-delete-all` may return a modified version of `resp`. But `resp` was accumulated in the `responses` list by reference. If the original alist is modified, it could affect other parts of the code that still hold references to the same cons cells. In practice, `assq-delete-all` removes cells from the list by relinking; the original variable still points to the old head. This is subtle but correct since `clean` gets the result and `resp` is not used after this point. NOTE.

### 10. Timeout timer not cancelled on successful completion

- `run-at-time` creates a timer stored in no variable. When `emacs-mcp-complete-deferred` is called (successful completion), the timer is NOT cancelled. After `emacs-mcp-deferred-timeout` seconds, `emacs-mcp--transport-deferred-timeout` fires, finds a completed response in the hash (type b), calls `plist-get` on it, gets nil, then calls `remhash`. This removes a completed-and-delivered response from the hash — at this point the response was already delivered, so `remhash` is removing a stale entry. The behavior is correct (no double send) but only by accident. BLOCKING: if the completed response is stored in the hash and has NOT yet been delivered (waiting for reconnect), the timeout fires and removes it before it can be delivered on reconnect. This deletes the response entirely. The client reconnects, finds nothing in the deferred hash, and never receives the response. The timer MUST be cancelled when the response is completed.

### 11. `emacs-mcp--transport-open-deferred-sse` — `response` argument unused after `id` extraction

- `(alist-get 'id response)` extracts the request-id for the deferred hash key. The `response` alist itself (which contains `(result . nil)` since the deferred placeholder has nil result) is never stored or sent. The client receives SSE headers but no initial SSE event acknowledging the deferred operation. Is there a need to send an initial event? Per MCP spec, the deferred pattern means the server opens SSE and sends the response when ready. No initial event is required. Correct.

### 12. Test coverage — SSE/deferred completely untested

- The test file has zero tests for: `emacs-mcp--transport-open-deferred-sse`, `emacs-mcp--transport-deferred-timeout`, `emacs-mcp--transport-open-batch-sse`, GET reconnection with deferred responses, or batch SSE delivery.
- The forge output's note ("SSE/deferred behavior is better tested in integration tests (Task 13)") defers all coverage to a future task. This means Task 10 cannot be verified independently. For a standalone gauge review, the lack of unit tests for the core deferred lifecycle is a significant gap.
- At minimum: a unit test for `emacs-mcp--transport-deferred-timeout` behavior (using a mock session), and a test for the plist mutation bug (#4 above) would catch the BLOCKING issues.

### 13. `emacs-mcp--transport-open-deferred-sse` — No `emacs-mcp--http-close-connection` call path

- The happy path: `emacs-mcp-complete-deferred` stores response → GET reconnect delivers it. But who closes the SSE connection after delivery? In `emacs-mcp--transport-handle-get`, after `maphash` delivers and removes all completed entries, the function returns — but the process remains open. The connection stays alive indefinitely. A client expecting the SSE stream to close after receiving the deferred response would wait forever.
- `emacs-mcp--transport-deferred-timeout` closes the connection via `emacs-mcp--http-close-connection` — but only in the timeout path. The success path (delivered via GET reconnect) has no close call. BLOCKING: SSE streams are never closed on successful deferred completion via reconnect.

### 14. Byte-compilation concern — `emacs-mcp--wrap-tool-error` undefined in this file

- `emacs-mcp--transport-deferred-timeout` calls `emacs-mcp--wrap-tool-error`. This function is defined in `emacs-mcp-tools.el` (or similar), but `emacs-mcp-transport.el` does not `(require 'emacs-mcp-tools)`. At byte-compilation time, this will produce an "unknown function" warning. At runtime, if `emacs-mcp-tools` is loaded before the timeout fires (likely), it works. But the byte-compiler warning indicates a missing `require`. WARNING.

List issues with severity: BLOCKING / WARNING / NOTE.
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
