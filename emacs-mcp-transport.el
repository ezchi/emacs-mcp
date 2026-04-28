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
