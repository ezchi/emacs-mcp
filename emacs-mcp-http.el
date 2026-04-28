;;; emacs-mcp-http.el --- HTTP server for emacs-mcp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; License: AGPL-3.0-or-later
;; See the file LICENSE for the full license text.

;;; Commentary:

;; This library implements the HTTP server that accepts incoming
;; MCP connections for the emacs-mcp package.  It handles TCP
;; connection accept, request accumulation, HTTP parsing, response
;; writing, and SSE streaming.  It knows nothing about MCP — just HTTP.

;;; Code:

(require 'emacs-mcp)

;;;; Server lifecycle

(defvar emacs-mcp--http-clients nil
  "List of active client connection processes.")

(defun emacs-mcp--http-start (port handler)
  "Start an HTTP server on PORT, dispatching parsed requests to HANDLER.
HANDLER is called with (process method path headers body).
Returns the server process.  Binds to 127.0.0.1 only."
  (make-network-process
   :name "emacs-mcp-http"
   :server t
   :host "127.0.0.1"
   :service (or port 0)
   :family 'ipv4
   :coding 'no-conversion
   :filter #'emacs-mcp--http-filter
   :sentinel #'emacs-mcp--http-sentinel
   :noquery t
   :plist (list :handler handler)))

(defun emacs-mcp--http-stop (server)
  "Stop the HTTP SERVER and close all client connections."
  (dolist (client emacs-mcp--http-clients)
    (when (process-live-p client)
      (ignore-errors (delete-process client))))
  (setq emacs-mcp--http-clients nil)
  (when (process-live-p server)
    (delete-process server)))

;;;; Connection sentinel

(defun emacs-mcp--http-sentinel (process event)
  "Handle connection state changes for PROCESS with EVENT."
  (cond
   ;; New client connection from server accept
   ((string-prefix-p "open" event)
    (push process emacs-mcp--http-clients)
    (process-put process :buffer "")
    ;; Propagate handler from server to client process
    (let ((server (process-contact process :server)))
      (when (processp server)
        (process-put process :handler
                     (process-get server :handler)))))
   ;; Client disconnected
   ((or (string-prefix-p "connection broken" event)
        (string-prefix-p "deleted" event)
        (string-prefix-p "failed" event))
    (setq emacs-mcp--http-clients
          (delq process emacs-mcp--http-clients))
    ;; Notify SSE disconnect handler if set
    (let ((on-disconnect (process-get process :on-disconnect)))
      (when on-disconnect
        (funcall on-disconnect process))))))

;;;; Request accumulation and dispatch

(defun emacs-mcp--http-filter (process data)
  "Accumulate DATA from PROCESS and dispatch complete HTTP requests."
  (let ((buf (concat (or (process-get process :buffer) "") data)))
    (process-put process :buffer buf)
    (let ((request (emacs-mcp--http-parse-request buf)))
      (when request
        (process-put process :buffer "")
        (let* ((method (nth 0 request))
               (path (nth 1 request))
               (headers (nth 3 request))
               (body (nth 4 request)))
          ;; Origin validation first
          (let ((origin (cdr (assoc "origin" headers))))
            (cond
             ;; Invalid origin -> 403
             ((and origin
                   (not (emacs-mcp--http-validate-origin origin)))
              (emacs-mcp--http-send-response
               process 403 "Forbidden"
               '(("Content-Type" . "text/plain"))
               "Forbidden"))
             ;; Path not /mcp -> 404
             ((not (equal path "/mcp"))
              (emacs-mcp--http-send-response
               process 404 "Not Found"
               '(("Content-Type" . "text/plain"))
               "Not Found"))
             ;; Unsupported method -> 405
             ((not (member method '("POST" "GET" "DELETE")))
              (emacs-mcp--http-send-response
               process 405 "Method Not Allowed"
               '(("Content-Type" . "text/plain")
                 ("Allow" . "POST, GET, DELETE"))
               "Method Not Allowed"))
             ;; Dispatch to handler
             (t
              (let ((handler (process-get process :handler)))
                (if handler
                    (funcall handler process method path
                             headers body)
                  (emacs-mcp--http-send-response
                   process 500 "Internal Server Error"
                   '(("Content-Type" . "text/plain"))
                   "No handler")))))))))))

;;;; HTTP parsing

(defun emacs-mcp--http-parse-request (data)
  "Try to parse DATA as a complete HTTP request.
Returns (method path http-version headers body) if complete, nil
if more data is needed."
  (let ((header-end (string-search "\r\n\r\n" data)))
    (when header-end
      (let* ((header-str (substring data 0 header-end))
             (body-start (+ header-end 4))
             (lines (split-string header-str "\r\n"))
             (request-line (car lines))
             (header-lines (cdr lines)))
        ;; Parse request line — accept any HTTP method
        (when (string-match
               "^\\([A-Z]+\\) \\(\\S-+\\) \\(HTTP/[0-9.]+\\)"
               request-line)
          (let* ((method (match-string 1 request-line))
                 (path (match-string 2 request-line))
                 (version (match-string 3 request-line))
                 (headers (emacs-mcp--http-parse-headers
                           header-lines))
                 (content-length
                  (let ((cl (cdr (assoc "content-length"
                                        headers))))
                    (if cl (string-to-number cl) 0)))
                 (body-available (- (length data) body-start)))
            (when (>= body-available content-length)
              (let ((body (if (> content-length 0)
                              (substring data body-start
                                         (+ body-start
                                            content-length))
                            "")))
                (list method path version headers body)))))))))

(defun emacs-mcp--http-parse-headers (lines)
  "Parse header LINES into an alist with lowercase keys."
  (let (headers)
    (dolist (line lines)
      (when (string-match "^\\([^:]+\\):\\s-*\\(.*\\)" line)
        (push (cons (downcase (match-string 1 line))
                    (match-string 2 line))
              headers)))
    (nreverse headers)))

;;;; Response writing

(defun emacs-mcp--http-send-response (process status reason
                                              headers body)
  "Send an HTTP response to PROCESS.
STATUS is the numeric status code.  REASON is the reason phrase.
HEADERS is an alist.  BODY is a string (or nil)."
  (when (process-live-p process)
    (let* ((body-bytes (if body
                           (encode-coding-string body 'utf-8)
                         ""))
           (all-headers
            (append headers
                    (unless (assoc "Content-Length" headers)
                      `(("Content-Length"
                         . ,(number-to-string
                             (length body-bytes)))))))
           (response
            (concat
             (format "HTTP/1.1 %d %s\r\n" status reason)
             (mapconcat (lambda (h)
                          (format "%s: %s" (car h) (cdr h)))
                        all-headers "\r\n")
             "\r\n\r\n"
             body-bytes)))
      (process-send-string process response))))

;;;; SSE support

(defun emacs-mcp--http-send-sse-headers (process
                                         &optional extra-headers)
  "Send SSE response headers to PROCESS.
EXTRA-HEADERS is an optional alist of additional headers."
  (when (process-live-p process)
    (let ((headers
           (append '(("Content-Type" . "text/event-stream")
                     ("Cache-Control" . "no-cache")
                     ("Connection" . "keep-alive"))
                   extra-headers)))
      (process-send-string
       process
       (concat "HTTP/1.1 200 OK\r\n"
               (mapconcat (lambda (h)
                            (format "%s: %s" (car h) (cdr h)))
                          headers "\r\n")
               "\r\n\r\n")))))

(defun emacs-mcp--http-send-sse-event (process data)
  "Send DATA as an SSE event to PROCESS."
  (when (process-live-p process)
    (process-send-string process (format "data: %s\n\n" data))))

;;;; Connection management

(defun emacs-mcp--http-close-connection (process)
  "Close the client connection PROCESS."
  (when (process-live-p process)
    (delete-process process)))

;;;; Origin validation

(defun emacs-mcp--http-validate-origin (origin)
  "Return non-nil if ORIGIN is a valid localhost origin.
Allows http/https on 127.0.0.1, localhost, or [::1] with any port."
  (and (stringp origin)
       (string-match
        "^https?://\\(127\\.0\\.0\\.1\\|localhost\\|\\[::1\\]\\)\\(:[0-9]+\\)?$"
        origin)))

(provide 'emacs-mcp-http)
;;; emacs-mcp-http.el ends here
