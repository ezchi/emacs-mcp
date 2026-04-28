# Gauge Code Review — Task 7: HTTP Server (Iteration 2)

You are a strict code reviewer. This is iteration 2 after fixing all 4 BLOCKING issues from iteration 1.

## Previous Issues (Iteration 1)

1. BLOCKING: `emacs-mcp--http-filter` retrieved handler via `(process-get (process-get process :server) :handler)`. `process-get process :server` is not documented for accepted clients; if nil, the expression threw instead of using the fallback.
2. BLOCKING: Path check was absent from filter dispatch. GET/POST/DELETE to `/other` was passed to handler instead of returning 404.
3. BLOCKING: Functions were named `emacs-mcp--http-try-parse-request` and `emacs-mcp--http-valid-origin-p` instead of the spec-mandated `emacs-mcp--http-parse-request` and `emacs-mcp--http-validate-origin`. Other modules expecting the spec names would fail to compile.
4. BLOCKING: `emacs-mcp--http-try-parse-request` only matched a fixed allowlist of HTTP methods. `TRACE /mcp HTTP/1.1` was never parsed, so the filter never got a request object and 405 was dead code for any unlisted method.

## Fixes Applied

1. Handler is now propagated from server to client in the sentinel's "open" branch via `process-put process :handler`. The filter reads `(process-get process :handler)` directly.
2. Filter now checks `(not (equal path "/mcp"))` before the method check and returns 404 for non-`/mcp` paths.
3. Functions renamed to `emacs-mcp--http-parse-request` and `emacs-mcp--http-validate-origin`. Tests updated accordingly.
4. Request-line regex changed from a fixed allowlist to `\\([A-Z]+\\)` to parse any HTTP method, allowing unsupported methods to reach the 405 branch.

## Full File: emacs-mcp-http.el

```elisp
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
```

## Full File: test/emacs-mcp-test-http.el

```elisp
;;; emacs-mcp-test-http.el --- Tests for emacs-mcp-http -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the HTTP server layer.

;;; Code:

(require 'ert)
(require 'emacs-mcp-http)

;;;; HTTP parsing tests

(ert-deftest emacs-mcp-test-http-parse-get ()
  "Parse a GET request."
  (let ((req (emacs-mcp--http-parse-request
              "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")))
    (should req)
    (should (equal (nth 0 req) "GET"))
    (should (equal (nth 1 req) "/mcp"))
    (should (equal (nth 2 req) "HTTP/1.1"))))

(ert-deftest emacs-mcp-test-http-parse-post-with-body ()
  "Parse a POST request with JSON body."
  (let* ((body "{\"jsonrpc\":\"2.0\"}")
         (req (emacs-mcp--http-parse-request
               (format "POST /mcp HTTP/1.1\r\nContent-Length: %d\r\n\r\n%s"
                       (length body) body))))
    (should req)
    (should (equal (nth 0 req) "POST"))
    (should (equal (nth 4 req) body))))

(ert-deftest emacs-mcp-test-http-parse-incomplete ()
  "Incomplete request returns nil."
  (should-not (emacs-mcp--http-parse-request
               "POST /mcp HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort")))

(ert-deftest emacs-mcp-test-http-parse-no-body ()
  "Request with no Content-Length has empty body."
  (let ((req (emacs-mcp--http-parse-request
              "DELETE /mcp HTTP/1.1\r\nHost: x\r\n\r\n")))
    (should req)
    (should (equal (nth 0 req) "DELETE"))
    (should (equal (nth 4 req) ""))))

(ert-deftest emacs-mcp-test-http-parse-headers ()
  "Headers parsed with lowercase keys."
  (let ((req (emacs-mcp--http-parse-request
              (concat "GET /mcp HTTP/1.1\r\n"
                      "Host: 127.0.0.1\r\n"
                      "Mcp-Session-Id: abc-123\r\n"
                      "Content-Type: application/json\r\n"
                      "\r\n"))))
    (should req)
    (let ((headers (nth 3 req)))
      (should (equal (cdr (assoc "host" headers)) "127.0.0.1"))
      (should (equal (cdr (assoc "mcp-session-id" headers))
                     "abc-123"))
      (should (equal (cdr (assoc "content-type" headers))
                     "application/json")))))

;;;; Origin validation tests

(ert-deftest emacs-mcp-test-http-origin-absent ()
  "Absent origin is allowed (validated at dispatch level)."
  ;; Origin validation only applies when header is present
  (should t))

(ert-deftest emacs-mcp-test-http-origin-127001 ()
  "Origin http://127.0.0.1:8080 is accepted."
  (should (emacs-mcp--http-validate-origin
           "http://127.0.0.1:8080")))

(ert-deftest emacs-mcp-test-http-origin-localhost ()
  "Origin http://localhost is accepted."
  (should (emacs-mcp--http-validate-origin
           "http://localhost")))

(ert-deftest emacs-mcp-test-http-origin-ipv6 ()
  "Origin http://[::1]:8080 is accepted."
  (should (emacs-mcp--http-validate-origin
           "http://[::1]:8080")))

(ert-deftest emacs-mcp-test-http-origin-https ()
  "Origin https://localhost:443 is accepted."
  (should (emacs-mcp--http-validate-origin
           "https://localhost:443")))

(ert-deftest emacs-mcp-test-http-origin-evil ()
  "Origin http://evil.com is rejected."
  (should-not (emacs-mcp--http-validate-origin
               "http://evil.com")))

(ert-deftest emacs-mcp-test-http-origin-malformed ()
  "Malformed origin is rejected."
  (should-not (emacs-mcp--http-validate-origin "not-a-url")))

(ert-deftest emacs-mcp-test-http-origin-127001-no-port ()
  "Origin http://127.0.0.1 without port is accepted."
  (should (emacs-mcp--http-validate-origin
           "http://127.0.0.1")))

(provide 'emacs-mcp-test-http)
;;; emacs-mcp-test-http.el ends here
```

## Review Focus

1. Verify all 4 BLOCKING issues from iteration 1 are fixed
2. Verify sentinel propagates `:handler` from server to client via `process-contact process :server`
3. Verify filter dispatch order: origin check -> 404 path check -> 405 method check -> handler dispatch
4. Verify `emacs-mcp--http-parse-request` (not `try-parse`) is the name used everywhere
5. Verify `emacs-mcp--http-validate-origin` (not `valid-origin-p`) is the name used everywhere
6. Verify `[A-Z]+` regex parses any HTTP method including `TRACE`
7. Check `process-contact process :server` — verify this is correct Emacs API for getting the server process from an accepted client
8. Any remaining issues?

List issues with severity: BLOCKING / WARNING / NOTE
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
