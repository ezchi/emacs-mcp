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

(ert-deftest emacs-mcp-test-protocol-tools-list-serializable ()
  "Tools/list response serializes with string-named schema properties."
  (emacs-mcp-test-with-protocol
    (emacs-mcp-register-tool
     :name "file-tool"
     :description "A file tool"
     :params '((:name "file" :type string :required t))
     :handler #'ignore)
    (let* ((msg (emacs-mcp-test--make-request 1 "tools/list"))
           (resp (emacs-mcp--handle-tools-list msg nil)))
      (should (string-match-p
               "\"file\""
               (emacs-mcp--jsonrpc-serialize resp))))))

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

;;;; Per-session project directory tests

(defun emacs-mcp-test--initialize-with-project-dir (project-dir)
  "Initialize with a specific PROJECT-DIR.
Returns (session-id . response)."
  (let* ((msg (emacs-mcp-test--make-request
               1 "initialize"
               `((protocolVersion . "2025-03-26")
                 (capabilities . ,(make-hash-table))
                 (clientInfo . ((name . "test") (version . "1.0")))
                 (projectDir . ,project-dir))))
         (resp (emacs-mcp--handle-initialize msg nil)))
    (cons (alist-get :session-id resp) resp)))

(defun emacs-mcp-test--make-session-ready (session-id)
  "Transition SESSION-ID to ready state."
  (let ((session (emacs-mcp--session-get session-id)))
    (when session
      (setf (emacs-mcp-session-state session) 'ready))))

;; AC-1: Two clients with different projectDir
(ert-deftest emacs-mcp-test-protocol-init-different-project-dirs ()
  "Two clients can have different project directories."
  (emacs-mcp-test-with-protocol
    (let* ((pair1 (emacs-mcp-test--initialize-with-project-dir
                   "/tmp"))
           (pair2 (emacs-mcp-test--initialize-with-project-dir
                   "/var"))
           (sid1 (car pair1))
           (sid2 (car pair2))
           (s1 (emacs-mcp--session-get sid1))
           (s2 (emacs-mcp--session-get sid2)))
      (should (stringp sid1))
      (should (stringp sid2))
      (should-not (string= (emacs-mcp-session-project-dir s1)
                            (emacs-mcp-session-project-dir s2))))))

;; AC-3: Invalid projectDir at initialize
(ert-deftest emacs-mcp-test-protocol-init-invalid-project-dir ()
  "Invalid projectDir returns error, no session created."
  (emacs-mcp-test-with-protocol
    (let ((count-before (hash-table-count emacs-mcp--sessions)))
      (let* ((resp (cdr (emacs-mcp-test--initialize-with-project-dir
                         "/nonexistent-abc123xyz"))))
        (should (alist-get 'error resp))
        (should (= (alist-get 'code (alist-get 'error resp))
                   -32602))
        (should (= (hash-table-count emacs-mcp--sessions)
                   count-before))))))

;; AC-5: Missing projectDir uses global fallback
(ert-deftest emacs-mcp-test-protocol-init-no-project-dir ()
  "Missing projectDir uses global fallback."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize))
           (sid (car pair))
           (session (emacs-mcp--session-get sid)))
      (should (equal (emacs-mcp-session-project-dir session)
                     "/test/project")))))

;; AC-2: setProjectDir changes project-dir
(ert-deftest emacs-mcp-test-protocol-set-project-dir ()
  "setProjectDir changes the session's project directory."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize-with-project-dir
                  "/tmp"))
           (sid (car pair)))
      (emacs-mcp-test--make-session-ready sid)
      (let* ((msg (emacs-mcp-test--make-request
                   2 "emacs-mcp/setProjectDir"
                   `((projectDir . "/var"))))
             (resp (emacs-mcp--handle-set-project-dir msg sid))
             (result (alist-get 'result resp))
             (session (emacs-mcp--session-get sid)))
        (should result)
        (should (stringp (alist-get 'projectDir result)))
        (should (string-match-p "/var"
                 (emacs-mcp-session-project-dir session)))))))

;; AC-2 (path auth): path authorization uses new dir
(ert-deftest emacs-mcp-test-protocol-set-project-dir-path-auth ()
  "After setProjectDir, path auth uses the new directory."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize-with-project-dir
                  "/tmp"))
           (sid (car pair)))
      (emacs-mcp-test--make-session-ready sid)
      ;; Change to /var
      (emacs-mcp--handle-set-project-dir
       (emacs-mcp-test--make-request
        2 "emacs-mcp/setProjectDir"
        `((projectDir . "/var")))
       sid)
      ;; Path auth should accept /var/... but reject /tmp/...
      (let* ((emacs-mcp--current-session-id sid)
             (session (emacs-mcp--session-get sid))
             (new-dir (emacs-mcp-session-project-dir session)))
        ;; /var/log should be accepted (inside new project dir)
        (should (file-in-directory-p "/var/log" new-dir))
        ;; /tmp/foo should be outside the new project dir
        (should-not (file-in-directory-p "/tmp/foo" new-dir))))))

;; AC-6: Hook fires on actual change, not on same-dir
(ert-deftest emacs-mcp-test-protocol-set-project-dir-hook ()
  "Hook fires on actual change, not on same directory."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize-with-project-dir
                  "/tmp"))
           (sid (car pair))
           (hook-args nil)
           (emacs-mcp-project-dir-changed-hook nil))
      (emacs-mcp-test--make-session-ready sid)
      (add-hook 'emacs-mcp-project-dir-changed-hook
                (lambda (s old new)
                  (setq hook-args (list s old new))))
      ;; Change to /var — hook should fire
      (emacs-mcp--handle-set-project-dir
       (emacs-mcp-test--make-request
        2 "emacs-mcp/setProjectDir"
        `((projectDir . "/var")))
       sid)
      (should hook-args)
      (should (equal (nth 0 hook-args) sid))
      (should (stringp (nth 1 hook-args)))  ; old-dir
      (should (stringp (nth 2 hook-args)))  ; new-dir
      (should (string-match-p "/tmp" (nth 1 hook-args)))
      (should (string-match-p "/var" (nth 2 hook-args)))
      ;; Reset and try same dir — hook should NOT fire
      (setq hook-args nil)
      (emacs-mcp--handle-set-project-dir
       (emacs-mcp-test--make-request
        3 "emacs-mcp/setProjectDir"
        `((projectDir . "/var")))
       sid)
      (should-not hook-args))))

;; Session not ready → error -32600
(ert-deftest emacs-mcp-test-protocol-set-project-dir-not-ready ()
  "setProjectDir on initializing session returns -32600."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize-with-project-dir
                  "/tmp"))
           (sid (car pair)))
      ;; Do NOT make session ready
      (let* ((msg (emacs-mcp-test--make-request
                   2 "emacs-mcp/setProjectDir"
                   `((projectDir . "/var"))))
             (resp (emacs-mcp--handle-set-project-dir msg sid)))
        (should (alist-get 'error resp))
        (should (= (alist-get 'code (alist-get 'error resp))
                   -32600))))))

;; Invalid path → -32602, project-dir unchanged
(ert-deftest emacs-mcp-test-protocol-set-project-dir-invalid ()
  "Invalid path returns -32602, project-dir unchanged."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize-with-project-dir
                  "/tmp"))
           (sid (car pair))
           (session (emacs-mcp--session-get sid))
           (original-dir (emacs-mcp-session-project-dir session)))
      (emacs-mcp-test--make-session-ready sid)
      (let* ((msg (emacs-mcp-test--make-request
                   2 "emacs-mcp/setProjectDir"
                   `((projectDir . "/nonexistent-abc123xyz"))))
             (resp (emacs-mcp--handle-set-project-dir msg sid)))
        (should (alist-get 'error resp))
        (should (= (alist-get 'code (alist-get 'error resp))
                   -32602))
        ;; Project dir should be unchanged
        (should (equal (emacs-mcp-session-project-dir session)
                       original-dir))))))

;; Notification guard
(ert-deftest emacs-mcp-test-protocol-set-project-dir-notification ()
  "Notification does not mutate session state."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize-with-project-dir
                  "/tmp"))
           (sid (car pair))
           (session (emacs-mcp--session-get sid))
           (original-dir (emacs-mcp-session-project-dir session)))
      (emacs-mcp-test--make-session-ready sid)
      ;; Send as notification (no id field)
      (let* ((msg `((jsonrpc . "2.0")
                    (method . "emacs-mcp/setProjectDir")
                    (params . ((projectDir . "/var")))))
             (resp (emacs-mcp--handle-set-project-dir msg sid)))
        (should-not resp)
        (should (equal (emacs-mcp-session-project-dir session)
                       original-dir))))))

;; Deferred context variable binding
(ert-deftest emacs-mcp-test-protocol-deferred-project-dir ()
  "emacs-mcp--current-project-dir is bound during tool dispatch."
  (emacs-mcp-test-with-protocol
    (let* ((pair (emacs-mcp-test--initialize-with-project-dir
                  "/tmp"))
           (sid (car pair))
           (captured-dir nil))
      (emacs-mcp-test--make-session-ready sid)
      (emacs-mcp-register-tool
       :name "capture-dir"
       :handler (lambda (_args)
                  (setq captured-dir
                        emacs-mcp--current-project-dir)
                  "ok"))
      (emacs-mcp--dispatch-tool "capture-dir" nil sid 99)
      (should captured-dir)
      (should (string-match-p "/tmp" captured-dir)))))

(provide 'emacs-mcp-test-protocol)
;;; emacs-mcp-test-protocol.el ends here
