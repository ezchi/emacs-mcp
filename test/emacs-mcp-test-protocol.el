;;; emacs-mcp-test-protocol.el --- Tests for emacs-mcp-protocol -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for MCP protocol handlers.

;;; Code:

(require 'ert)
(require 'emacs-mcp-protocol)
(require 'emacs-mcp-transport)

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
  "Tools/call with null request ID returns error via dispatch."
  (emacs-mcp-test-with-protocol
    (let* ((msg `((jsonrpc . "2.0") (id . :null)
                  (method . "tools/call")
                  (params . ((name . "x")))))
           (resp (emacs-mcp--protocol-dispatch msg "s")))
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

;;;; Centralized null ID rejection

(ert-deftest emacs-mcp-test-protocol-null-id-any-method ()
  "Null request ID rejected for any method via dispatch."
  (emacs-mcp-test-with-protocol
    (dolist (method '("ping" "tools/list" "resources/list"))
      (let* ((msg `((jsonrpc . "2.0") (id . :null)
                    (method . ,method)))
             (resp (emacs-mcp--protocol-dispatch msg nil)))
        (should (alist-get 'error resp))
        (should (= (alist-get 'code (alist-get 'error resp))
                   -32600))))))

;;;; Notification handling

(ert-deftest emacs-mcp-test-protocol-notification-returns-nil ()
  "Known-method notifications return nil (no response)."
  (emacs-mcp-test-with-protocol
    (let* ((msg `((jsonrpc . "2.0") (method . "ping")))
           (resp (emacs-mcp--protocol-dispatch msg nil)))
      (should-not resp))))

;;;; Malformed params

(ert-deftest emacs-mcp-test-protocol-tools-call-malformed-params ()
  "Tools/call with non-alist params returns error."
  (emacs-mcp-test-with-protocol
    (let* ((msg `((jsonrpc . "2.0") (id . 1)
                  (method . "tools/call")
                  (params . "bad")))
           (resp (emacs-mcp--handle-tools-call msg "s")))
      (should (alist-get 'error resp)))))

(ert-deftest emacs-mcp-test-protocol-tools-call-null-arguments ()
  "Tools/call with null arguments does not crash."
  (emacs-mcp-test-with-protocol
    (emacs-mcp-register-tool
     :name "noargs" :handler (lambda (_) "ok"))
    (let* ((pair (emacs-mcp-test--initialize))
           (sid (car pair))
           (msg (emacs-mcp-test--make-request
                 1 "tools/call"
                 `((name . "noargs")
                   (arguments . :null))))
           (resp (emacs-mcp--handle-tools-call msg sid))
           (result (alist-get 'result resp)))
      (should (equal (alist-get 'isError result) :false)))))

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
  "Complete-deferred stores response in session for delivery."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize))
           (sid (car pair)))
      ;; No live SSE process, so it stores for reconnection
      (emacs-mcp-complete-deferred sid 42 "result value")
      (let* ((session (emacs-mcp--session-get sid))
             (deferred (emacs-mcp-session-deferred session))
             (entry (gethash 42 deferred)))
        (should entry)
        (should (eq (plist-get entry :status) 'completed))
        (let ((resp (plist-get entry :response)))
          (should (equal (alist-get 'id resp) 42)))))))

(provide 'emacs-mcp-test-protocol)
;;; emacs-mcp-test-protocol.el ends here
