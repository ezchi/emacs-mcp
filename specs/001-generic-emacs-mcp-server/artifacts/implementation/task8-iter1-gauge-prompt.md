# Gauge Code Review — Task 8: MCP Protocol Handlers (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Implement `emacs-mcp-protocol.el`: The MCP JSON-RPC protocol method handlers.  This layer sits between the transport (HTTP) and the tool/session infrastructure.  It dispatches incoming JSON-RPC messages to per-method handlers and knows nothing about HTTP.

**Functions/variables to implement**:
- `emacs-mcp--method-dispatch-table` — alist mapping MCP method strings to handler functions
- `emacs-mcp--protocol-dispatch` — top-level dispatch: look up method, call handler, return response or nil for notifications; return method-not-found error for unknown methods
- `emacs-mcp--handle-initialize` — handle `initialize` request: create session, run hook, return `InitializeResult` with `protocolVersion`, `capabilities`, `serverInfo`; attach `:session-id` metadata for transport
- `emacs-mcp--handle-initialized` — handle `notifications/initialized` notification: transition session state to `ready`; return nil
- `emacs-mcp--handle-ping` — handle `ping` request: return empty `{}` result
- `emacs-mcp--handle-tools-list` — handle `tools/list`: return all registered tools with `inputSchema`
- `emacs-mcp--handle-tools-call` — handle `tools/call`: validate params, dispatch to `emacs-mcp--dispatch-tool`, handle deferred result with `:deferred` metadata, translate errors to JSON-RPC error responses
- `emacs-mcp--handle-resources-list` — return empty resources list
- `emacs-mcp--handle-prompts-list` — return empty prompts list
- `emacs-mcp-complete-deferred` — store a completed deferred response in the session's deferred hash for transport delivery

**Verification criteria**:
- `initialize` returns `protocolVersion "2025-03-26"`, correct capabilities, `serverInfo` with name `"emacs-mcp"`
- `:session-id` metadata attached to initialize response for transport to extract
- `notifications/initialized` transitions session state to `ready`; returns nil
- `ping` returns empty hash-table result
- `tools/list` returns a vector of tool entries each with `name`, `description`, `inputSchema`
- `tools/call` with null id returns `-32600 invalid-request`
- `tools/call` with missing `name` field returns `-32602 invalid-params`
- `tools/call` with unknown tool returns error response
- `tools/call` deferred result produces response with `:deferred t` metadata
- Unknown method on a request returns `-32601 method-not-found`; on a notification returns nil
- `complete-deferred` stores response in `(emacs-mcp-session-deferred session)` keyed by request-id
- All tests pass; file byte-compiles clean

## Coding Standards (from Constitution)

- Style: Follow Emacs Lisp conventions, `checkdoc` compliant
- Naming: Public symbols `emacs-mcp-`, internal `emacs-mcp--`
- Docstrings: Every public function/variable must have a docstring passing `checkdoc`
- Byte-compilation: Clean with no warnings
- Line length: 80 columns soft limit
- No global state pollution outside the package namespace

## Full File: emacs-mcp-protocol.el

```elisp
;;; emacs-mcp-protocol.el --- MCP protocol method handlers for emacs-mcp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; License: AGPL-3.0-or-later
;; See the file LICENSE for the full license text.

;;; Commentary:

;; This library implements the MCP protocol method handlers
;; (initialize, tools/list, tools/call, etc.) for the emacs-mcp
;; package.  Handlers work with parsed JSON-RPC data structures
;; and know nothing about HTTP.

;;; Code:

(require 'emacs-mcp)
(require 'emacs-mcp-jsonrpc)
(require 'emacs-mcp-session)
(require 'emacs-mcp-tools)

;;;; Method dispatch table

(defvar emacs-mcp--method-dispatch-table
  '(("initialize" . emacs-mcp--handle-initialize)
    ("notifications/initialized" . emacs-mcp--handle-initialized)
    ("ping" . emacs-mcp--handle-ping)
    ("tools/list" . emacs-mcp--handle-tools-list)
    ("tools/call" . emacs-mcp--handle-tools-call)
    ("resources/list" . emacs-mcp--handle-resources-list)
    ("prompts/list" . emacs-mcp--handle-prompts-list))
  "Alist mapping MCP method strings to handler functions.")

;;;; Protocol dispatch

(defun emacs-mcp--protocol-dispatch (msg session-id)
  "Dispatch a parsed JSON-RPC MSG in SESSION-ID context.
Returns a JSON-RPC response alist, or nil for notifications."
  (let* ((method (alist-get 'method msg))
         (id (alist-get 'id msg))
         (handler (cdr (assoc method
                              emacs-mcp--method-dispatch-table))))
    (if handler
        (funcall handler msg session-id)
      ;; Unknown method
      (when (emacs-mcp--jsonrpc-request-p msg)
        (emacs-mcp--jsonrpc-make-error
         id
         emacs-mcp--jsonrpc-method-not-found
         (format "Method not found: %s" method))))))

;;;; Handler: initialize

(defun emacs-mcp--handle-initialize (msg _session-id)
  "Handle MCP `initialize' request MSG.
Creates a new session and returns InitializeResult."
  (let* ((id (alist-get 'id msg))
         (params (alist-get 'params msg))
         (client-info (alist-get 'clientInfo params))
         (project-dir (or emacs-mcp--project-dir
                          (emacs-mcp--resolve-project-dir)))
         (new-session-id (emacs-mcp--session-create
                          project-dir client-info)))
    ;; Run hook
    (run-hook-with-args 'emacs-mcp-client-connected-hook
                        new-session-id)
    ;; Return result with session ID attached as metadata
    (let ((response (emacs-mcp--jsonrpc-make-response
                     id
                     `((protocolVersion . "2025-03-26")
                       (capabilities
                        . ((tools . ((listChanged . :false)))
                           (resources . ,(make-hash-table))
                           (prompts . ,(make-hash-table))))
                       (serverInfo
                        . ((name . "emacs-mcp")
                           (version . "0.1.0")))))))
      ;; Attach session ID for transport to extract
      (push (cons :session-id new-session-id) response)
      response)))

;;;; Handler: notifications/initialized

(defun emacs-mcp--handle-initialized (_msg session-id)
  "Handle `notifications/initialized' notification.
Transitions session to ready state.  Returns nil (notification)."
  (let ((session (emacs-mcp--session-get session-id)))
    (when session
      (setf (emacs-mcp-session-state session) 'ready)))
  nil)

;;;; Handler: ping

(defun emacs-mcp--handle-ping (msg _session-id)
  "Handle `ping' request MSG.  Returns empty result."
  (let ((id (alist-get 'id msg)))
    (if (emacs-mcp--jsonrpc-request-p msg)
        (emacs-mcp--jsonrpc-make-response
         id (make-hash-table))
      nil)))

;;;; Handler: tools/list

(defun emacs-mcp--handle-tools-list (msg _session-id)
  "Handle `tools/list' request MSG.
Returns all registered tools with inputSchema."
  (let ((id (alist-get 'id msg))
        (tools (mapcar
                (lambda (entry)
                  (let ((tool (cdr entry)))
                    `((name . ,(plist-get tool :name))
                      (description . ,(plist-get tool :description))
                      (inputSchema
                       . ,(emacs-mcp--tool-input-schema
                           (plist-get tool :params))))))
                emacs-mcp--tools)))
    (emacs-mcp--jsonrpc-make-response
     id `((tools . ,(vconcat tools))))))

;;;; Handler: tools/call

(defun emacs-mcp--handle-tools-call (msg session-id)
  "Handle `tools/call' request MSG in SESSION-ID context."
  (let* ((id (alist-get 'id msg))
         (params (alist-get 'params msg)))
    (cond
     ;; Reject null request IDs
     ((eq id :null)
      (emacs-mcp--jsonrpc-make-error
       :null
       emacs-mcp--jsonrpc-invalid-request
       "Null request IDs not allowed"))
     ;; Validate params: name must be present
     ((not (alist-get 'name params))
      (emacs-mcp--jsonrpc-make-error
       id
       emacs-mcp--jsonrpc-invalid-params
       "Missing required field: name"))
     ;; Normal dispatch
     (t
      (let* ((tool-name (alist-get 'name params))
             (tool-args (alist-get 'arguments params))
             (args-alist
              (when tool-args
                (mapcar (lambda (pair)
                          (cons (symbol-name (car pair))
                                (cdr pair)))
                        tool-args))))
        (condition-case err
            (let ((result (emacs-mcp--dispatch-tool
                           tool-name args-alist
                           session-id id)))
              (if (eq result 'deferred)
                  (let ((resp (emacs-mcp--jsonrpc-make-response
                               id nil)))
                    (push (cons :deferred t) resp)
                    resp)
                (emacs-mcp--jsonrpc-make-response id result)))
          (error
           (emacs-mcp--jsonrpc-make-error
            id
            emacs-mcp--jsonrpc-invalid-params
            (error-message-string err)))))))))

;;;; Handler: resources/list

(defun emacs-mcp--handle-resources-list (msg _session-id)
  "Handle `resources/list' request MSG.  Returns empty list."
  (let ((id (alist-get 'id msg)))
    (emacs-mcp--jsonrpc-make-response
     id `((resources . ,(vector))))))

;;;; Handler: prompts/list

(defun emacs-mcp--handle-prompts-list (msg _session-id)
  "Handle `prompts/list' request MSG.  Returns empty list."
  (let ((id (alist-get 'id msg)))
    (emacs-mcp--jsonrpc-make-response
     id `((prompts . ,(vector))))))

;;;; Deferred response completion

(defun emacs-mcp-complete-deferred (session-id request-id result
                                               &optional is-error)
  "Complete a deferred response for SESSION-ID and REQUEST-ID.
RESULT is the tool result (string or content list).
IS-ERROR if non-nil sets isError to true."
  (let ((session (emacs-mcp--session-get session-id)))
    (when session
      (let* ((wrapped (if is-error
                          (emacs-mcp--wrap-tool-error result)
                        (emacs-mcp--wrap-tool-result result)))
             (response (emacs-mcp--jsonrpc-make-response
                        request-id wrapped)))
        ;; Store in session's deferred hash for transport to deliver
        (puthash request-id response
                 (emacs-mcp-session-deferred session))))))

(provide 'emacs-mcp-protocol)
;;; emacs-mcp-protocol.el ends here
```

## Full File: test/emacs-mcp-test-protocol.el

```elisp
;;; emacs-mcp-test-protocol.el --- Tests for emacs-mcp-protocol -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for MCP protocol handlers.

;;; Code:

(require 'ert)
(require 'emacs-mcp-protocol)

(defmacro emacs-mcp-test-with-protocol (&rest body)
  "Run BODY with clean session and tool state."
  (declare (indent 0))
  `(let ((emacs-mcp--sessions (make-hash-table :test 'equal))
         (emacs-mcp--tools nil)
         (emacs-mcp-session-timeout 1800)
         (emacs-mcp--project-dir "/test/project"))
     (unwind-protect
         (progn ,@body)
       (maphash (lambda (_id session)
                  (when (emacs-mcp-session-timer session)
                    (cancel-timer (emacs-mcp-session-timer session))))
                emacs-mcp--sessions))))

(defun emacs-mcp-test--make-request (id method &optional params)
  "Build a JSON-RPC request alist with ID, METHOD, and PARAMS."
  (let ((msg `((jsonrpc . "2.0") (id . ,id) (method . ,method))))
    (when params
      (setq msg (append msg `((params . ,params)))))
    msg))

(defun emacs-mcp-test--initialize ()
  "Send an initialize request and return (session-id . response)."
  (let* ((msg (emacs-mcp-test--make-request
               1 "initialize"
               `((protocolVersion . "2025-03-26")
                 (capabilities . ,(make-hash-table))
                 (clientInfo . ((name . "test") (version . "1.0"))))))
         (resp (emacs-mcp--handle-initialize msg nil)))
    (cons (alist-get :session-id resp) resp)))

;;;; Initialize tests

(ert-deftest emacs-mcp-test-protocol-initialize ()
  "Initialize returns valid InitializeResult."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize))
           (session-id (car pair))
           (resp (cdr pair))
           (result (alist-get 'result resp)))
      (should (stringp session-id))
      (should (equal (alist-get 'protocolVersion result)
                     "2025-03-26"))
      (should (equal (alist-get 'name
                                (alist-get 'serverInfo result))
                     "emacs-mcp")))))

(ert-deftest emacs-mcp-test-protocol-initialize-capabilities ()
  "Initialize response includes correct capabilities."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize))
           (result (alist-get 'result (cdr pair)))
           (caps (alist-get 'capabilities result)))
      (should (alist-get 'tools caps))
      (should (alist-get 'resources caps))
      (should (alist-get 'prompts caps)))))

(ert-deftest emacs-mcp-test-protocol-initialize-hook ()
  "Initialize runs client-connected-hook with session ID."
  (emacs-mcp-test-with-protocol
    (let ((hook-arg nil)
          (emacs-mcp-client-connected-hook nil))
      (add-hook 'emacs-mcp-client-connected-hook
                (lambda (sid) (setq hook-arg sid)))
      (let* ((pair (emacs-mcp-test--initialize))
             (session-id (car pair)))
        (should (equal hook-arg session-id))))))

;;;; Initialized notification

(ert-deftest emacs-mcp-test-protocol-initialized ()
  "Notifications/initialized transitions session to ready."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize))
           (session-id (car pair))
           (msg `((jsonrpc . "2.0")
                  (method . "notifications/initialized"))))
      (emacs-mcp--handle-initialized msg session-id)
      (should (eq (emacs-mcp-session-state
                   (emacs-mcp--session-get session-id))
                  'ready)))))

;;;; Ping

(ert-deftest emacs-mcp-test-protocol-ping ()
  "Ping returns empty result."
  (emacs-mcp-test-with-protocol
    (let* ((msg (emacs-mcp-test--make-request 42 "ping"))
           (resp (emacs-mcp--handle-ping msg nil)))
      (should (equal (alist-get 'id resp) 42))
      (should (alist-get 'result resp)))))

;;;; tools/list

(ert-deftest emacs-mcp-test-protocol-tools-list ()
  "Tools/list returns registered tools with schemas."
  (emacs-mcp-test-with-protocol
    (emacs-mcp-register-tool
     :name "test-tool"
     :description "A test"
     :params '((:name "x" :type string :required t))
     :handler #'ignore)
    (let* ((msg (emacs-mcp-test--make-request 1 "tools/list"))
           (resp (emacs-mcp--handle-tools-list msg nil))
           (result (alist-get 'result resp))
           (tools (alist-get 'tools result)))
      (should (vectorp tools))
      (should (= (length tools) 1))
      (let ((tool (aref tools 0)))
        (should (equal (alist-get 'name tool) "test-tool"))
        (should (alist-get 'inputSchema tool))))))

;;;; tools/call

(ert-deftest emacs-mcp-test-protocol-tools-call ()
  "Tools/call dispatches and returns CallToolResult."
  (emacs-mcp-test-with-protocol
    (emacs-mcp-register-tool
     :name "echo" :handler (lambda (args)
                             (cdr (assoc "msg" args))))
    (let* ((pair (emacs-mcp-test--initialize))
           (sid (car pair))
           (msg (emacs-mcp-test--make-request
                 1 "tools/call"
                 `((name . "echo")
                   (arguments . ((msg . "hi"))))))
           (resp (emacs-mcp--handle-tools-call msg sid))
           (result (alist-get 'result resp)))
      (should (equal (alist-get 'isError result) :false)))))

(ert-deftest emacs-mcp-test-protocol-tools-call-unknown ()
  "Tools/call with unknown tool returns error."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize))
           (sid (car pair))
           (msg (emacs-mcp-test--make-request
                 1 "tools/call"
                 `((name . "nonexistent"))))
           (resp (emacs-mcp--handle-tools-call msg sid)))
      (should (alist-get 'error resp)))))

(ert-deftest emacs-mcp-test-protocol-tools-call-null-id ()
  "Tools/call with null request ID returns error."
  (emacs-mcp-test-with-protocol
    (let* ((msg `((jsonrpc . "2.0") (id . :null)
                  (method . "tools/call")
                  (params . ((name . "x")))))
           (resp (emacs-mcp--handle-tools-call msg "s")))
      (should (alist-get 'error resp))
      (should (= (alist-get 'code (alist-get 'error resp))
                 -32600)))))

(ert-deftest emacs-mcp-test-protocol-tools-call-string-id ()
  "Tools/call preserves string request IDs."
  (emacs-mcp-test-with-protocol
    (emacs-mcp-register-tool
     :name "ok" :handler (lambda (_) "ok"))
    (let* ((pair (emacs-mcp-test--initialize))
           (sid (car pair))
           (msg (emacs-mcp-test--make-request
                 "abc-123" "tools/call"
                 `((name . "ok"))))
           (resp (emacs-mcp--handle-tools-call msg sid)))
      (should (equal (alist-get 'id resp) "abc-123")))))

(ert-deftest emacs-mcp-test-protocol-tools-call-missing-name ()
  "Tools/call without name returns invalid params error."
  (emacs-mcp-test-with-protocol
    (let* ((msg (emacs-mcp-test--make-request
                 1 "tools/call" `((arguments . nil))))
           (resp (emacs-mcp--handle-tools-call msg "s")))
      (should (alist-get 'error resp))
      (should (= (alist-get 'code (alist-get 'error resp))
                 -32602)))))

;;;; resources/list and prompts/list

(ert-deftest emacs-mcp-test-protocol-resources-list ()
  "Resources/list returns empty array."
  (emacs-mcp-test-with-protocol
    (let* ((msg (emacs-mcp-test--make-request 1 "resources/list"))
           (resp (emacs-mcp--handle-resources-list msg nil))
           (result (alist-get 'result resp)))
      (should (equal (alist-get 'resources result) [])))))

(ert-deftest emacs-mcp-test-protocol-prompts-list ()
  "Prompts/list returns empty array."
  (emacs-mcp-test-with-protocol
    (let* ((msg (emacs-mcp-test--make-request 1 "prompts/list"))
           (resp (emacs-mcp--handle-prompts-list msg nil))
           (result (alist-get 'result resp)))
      (should (equal (alist-get 'prompts result) [])))))

;;;; Unknown method

(ert-deftest emacs-mcp-test-protocol-unknown-method ()
  "Unknown method returns method-not-found error."
  (emacs-mcp-test-with-protocol
    (let* ((msg (emacs-mcp-test--make-request 1 "bogus/method"))
           (resp (emacs-mcp--protocol-dispatch msg nil)))
      (should (alist-get 'error resp))
      (should (= (alist-get 'code (alist-get 'error resp))
                 -32601)))))

;;;; Deferred response

(ert-deftest emacs-mcp-test-protocol-complete-deferred ()
  "Complete-deferred stores response in session."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize))
           (sid (car pair)))
      (emacs-mcp-complete-deferred sid 42 "result value")
      (let* ((session (emacs-mcp--session-get sid))
             (deferred (emacs-mcp-session-deferred session))
             (resp (gethash 42 deferred)))
        (should resp)
        (should (equal (alist-get 'id resp) 42))))))

(provide 'emacs-mcp-test-protocol)
;;; emacs-mcp-test-protocol.el ends here
```

## Review Checklist

1. **Correctness of dispatch table**: Does `emacs-mcp--method-dispatch-table` include all required methods? Are there any method names that differ from the MCP spec?

2. **Protocol dispatch — unknown notification**: `emacs-mcp--protocol-dispatch` calls `emacs-mcp--jsonrpc-request-p` to gate the error response. `emacs-mcp--jsonrpc-request-p` checks for both `method` AND `id`. A notification has `method` but no `id`. If an unknown notification arrives, the `when` guard correctly returns nil. Verify this is the intended behavior per the MCP spec.

3. **initialize handler — `_session-id` ignored**: The handler ignores the incoming `session-id` and always creates a new session. This is correct: initialize always starts a fresh session. But note — if a client re-sends `initialize` on an already-initialized connection, a second session is created and the first is leaked (no timeout cancellation, no explicit removal). Is this acceptable?

4. **initialize handler — capabilities format**: The `tools` capability uses `(listChanged . :false)`, while `resources` and `prompts` use `(make-hash-table)` (empty objects). Per the MCP spec, an empty capability object `{}` is valid. However, `(make-hash-table)` serializes as `{}` via `json-serialize`, but is an opaque object in the alist. Verify that `json-serialize` handles this correctly and that `alist-get 'resources caps` in the test produces the hash-table (non-nil), satisfying `(should (alist-get 'resources caps))`.

5. **initialize hook**: `run-hook-with-args` is used rather than `run-hooks`. This requires the hook functions to accept arguments, which is correct. But it also means `add-hook` users who provide a zero-argument function will get a wrong-number-of-arguments error at runtime. This is intentional (hook contract requires a session-id argument), but is not documented in the hook's docstring. Is there a hook variable defined with a docstring in `emacs-mcp.el`?

6. **ping handler — request-p guard**: `emacs-mcp--handle-ping` checks `emacs-mcp--jsonrpc-request-p msg` before returning a response. If `ping` arrives as a notification (no `id`), it returns nil. However, `ping` is not listed in the MCP spec as a notification — it is always a request. This extra guard is defensive but not harmful. NOTE only.

7. **tools/list — empty tool registry**: When `emacs-mcp--tools` is nil, `mapcar` over nil returns nil, `vconcat nil` returns `[]`. The result is `((tools . []))`. This is correct.

8. **tools/call — args conversion**: `tool-args` comes from `(alist-get 'arguments params)`. After JSON parsing with `:object-type 'alist`, the arguments object is an alist with symbol keys (e.g., `((msg . "hi"))`). The conversion `(symbol-name (car pair))` turns symbols to strings. CRITICAL: What if the JSON was `{}` (empty arguments)? Then `tool-args` is a hash-table (empty hash-table from `make-hash-table`), not an alist. The `mapcar` would fail on a hash-table. Verify: is `{}` parsed as an alist `nil` or as a hash-table with `:object-type 'alist`?

9. **tools/call — deferred result**: When `emacs-mcp--dispatch-tool` returns `'deferred`, the handler builds a response with `(result . nil)` plus `:deferred t` metadata. `nil` result serializes as JSON `null`. The transport must check for `:deferred t` before serializing. Is this the agreed contract? Review the deferred handling path: `emacs-mcp--wrap-tool-result` returns `'deferred` symbol when given `'deferred` — but `emacs-mcp--dispatch-tool` is the caller that wraps results, so it returns the already-wrapped `'deferred` symbol. Confirm the call chain: `handle-tools-call` → `dispatch-tool` → `wrap-tool-result('deferred)` → returns `'deferred` → `(eq result 'deferred)` is t. This is correct.

10. **tools/call — error classification**: All tool dispatch errors are mapped to `-32602 invalid-params`. This is a mis-classification: a tool not found error is a protocol error closer to `-32601`, and an internal error during tool execution is closer to `-32603`. Using `-32602` for all cases is technically incorrect per JSON-RPC 2.0. However, the MCP spec may accept this. NOTE for now; could be BLOCKING depending on spec interpretation.

11. **tools/call — null id error response**: The error response for null id uses `:null` as the id (`(emacs-mcp--jsonrpc-make-error :null ...)`). The JSON-RPC spec says for null id requests the error response should have `id: null`. Verify that `:null` serializes to JSON `null` correctly via `json-serialize`.

12. **complete-deferred — `puthash` key type**: The key `request-id` could be a string or integer. The session deferred hash-table uses `:test 'equal` (from session struct definition `(deferred (make-hash-table :test 'equal))`). With `equal` test, both string and integer keys work correctly. Correct.

13. **complete-deferred — no session guard behavior**: If `session-id` is invalid, `emacs-mcp--session-get` returns nil, the `when` short-circuits, and the function silently does nothing. This is acceptable but means the caller gets no feedback on failure. NOTE only.

14. **Test: `emacs-mcp-test-with-protocol` macro**: The teardown cancels timers via `maphash` over `emacs-mcp--sessions`. However, `emacs-mcp--sessions` is dynamically rebound in the macro. This is correct: the `unwind-protect` runs in the same dynamic scope and sees the rebound value. Correct.

15. **Test: `emacs-mcp-test--initialize` helper**: Calls `emacs-mcp--handle-initialize` with `nil` as `session-id`. The handler ignores `session-id` (it creates a new one), so this is fine.

16. **Test: `emacs-mcp-test-protocol-ping`**: Checks `(alist-get 'result resp)` is truthy. But `(make-hash-table)` is a hash-table, and hash-tables are truthy in Elisp. However, the `result` key's value in the response is the raw hash-table. The test passes if result is non-nil. Correct, but does not verify the response serializes to `{}`. NOTE only.

17. **Test: `emacs-mcp-test-protocol-tools-call`**: The echo handler returns `(cdr (assoc "msg" args))` = `"hi"`. `emacs-mcp--wrap-tool-result` wraps this as `((content . [...]) (isError . :false))`. The test checks `(alist-get 'isError result)` equals `:false`. This is correct.

18. **Test: `emacs-mcp-test-protocol-tools-call-unknown`**: Calls `handle-tools-call` with tool name `"nonexistent"`. `dispatch-tool` signals `(error "Unknown tool: nonexistent")`, caught by the `condition-case` in `handle-tools-call`, mapped to a `-32602` error response. The test only checks `(alist-get 'error resp)` is non-nil. Does NOT check the error code. NOTE only.

19. **Test: `emacs-mcp-test-protocol-initialized`** does not verify the return value is nil. The MCP spec requires notifications to return nil. Missing assertion. NOTE only.

20. **Missing test coverage**:
    - No test for `emacs-mcp--protocol-dispatch` with a notification (unknown method → should return nil, not error)
    - No test for `emacs-mcp--protocol-dispatch` routing to a handler (only unknown method is tested)
    - No test for `tools/call` with a deferred result
    - No test for `complete-deferred` with `is-error` = t
    - No test for `complete-deferred` with invalid session-id (silent no-op)
    - No test verifying `initialized` handler returns nil
    - No test verifying `tools/list` with zero tools returns `[]`

List issues with severity: BLOCKING / WARNING / NOTE
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
