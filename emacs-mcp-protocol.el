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
Returns a JSON-RPC response alist, or nil for notifications.
Notifications (no id) always return nil.  Requests with null id
are rejected with error -32600."
  (let ((method (alist-get 'method msg))
        (id (alist-get 'id msg)))
    (cond
     ;; Notification: dispatch silently, return nil
     ((emacs-mcp--jsonrpc-notification-p msg)
      (let ((handler (cdr (assoc method
                                 emacs-mcp--method-dispatch-table))))
        (when handler
          (funcall handler msg session-id)))
      nil)
     ;; Request with null ID: reject
     ((eq id :null)
      (emacs-mcp--jsonrpc-make-error
       :null
       emacs-mcp--jsonrpc-invalid-request
       "Null request IDs not allowed"))
     ;; Request: dispatch to handler
     (t
      (let ((handler (cdr (assoc method
                                 emacs-mcp--method-dispatch-table))))
        (if handler
            (funcall handler msg session-id)
          (emacs-mcp--jsonrpc-make-error
           id
           emacs-mcp--jsonrpc-method-not-found
           (format "Method not found: %s" method))))))))

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
  (let ((id (alist-get 'id msg)))
    (condition-case err
        (let* ((params (alist-get 'params msg))
               (tool-name (and (listp params)
                               (alist-get 'name params))))
          (unless (stringp tool-name)
            (error "Missing required field: name"))
          (let* ((tool-args (alist-get 'arguments params))
                 (args-alist
                  (when (and tool-args (listp tool-args))
                    (mapcar (lambda (pair)
                              (cons (symbol-name (car pair))
                                    (cdr pair)))
                            tool-args)))
                 (result (emacs-mcp--dispatch-tool
                          tool-name args-alist
                          session-id id)))
            (if (eq result 'deferred)
                (let ((resp (emacs-mcp--jsonrpc-make-response
                             id nil)))
                  (push (cons :deferred t) resp)
                  resp)
              (emacs-mcp--jsonrpc-make-response id result))))
      (error
       (emacs-mcp--jsonrpc-make-error
        id
        emacs-mcp--jsonrpc-invalid-params
        (error-message-string err))))))

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
