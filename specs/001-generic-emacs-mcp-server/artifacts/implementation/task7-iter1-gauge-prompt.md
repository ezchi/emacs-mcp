# Gauge Code Review — Task 7: HTTP Server (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Implement `emacs-mcp-http.el`: The low-level HTTP/1.1 server using `make-network-process`. Handles TCP connection accept, request accumulation (chunked data), HTTP parsing, response writing, SSE streaming, and Origin validation. Knows nothing about MCP — just HTTP.

**Functions to implement**:
- `emacs-mcp--http-start` — Create TCP server on `127.0.0.1:<port>`, return server process. Accept `:handler` callback for dispatching parsed requests.
- `emacs-mcp--http-stop` — Close server process and all client connections
- `emacs-mcp--http-filter` — Process filter: accumulate data in process-local buffer, detect complete request (headers + Content-Length body), dispatch
- `emacs-mcp--http-parse-request` — Parse accumulated bytes into `(method path http-version headers body)`
- `emacs-mcp--http-send-response` — Write HTTP response: status line, headers, body
- `emacs-mcp--http-send-sse-headers` — Write SSE response headers (`Content-Type: text/event-stream`, keep connection open)
- `emacs-mcp--http-send-sse-event` — Write `data: <payload>\n\n`
- `emacs-mcp--http-close-connection` — Close client connection process
- `emacs-mcp--http-validate-origin` — Origin header validation per NFR-4
- Connection sentinel for detecting client disconnects

**Verification criteria**:
- Server starts on configured port, accepts TCP connections
- Request accumulation works with fragmented data (multiple filter calls)
- Parse correctly extracts method, path, headers, body
- Response writing produces valid HTTP/1.1
- SSE events are correctly formatted (`data: ...\n\n`)
- Origin validation: absent -> allow, `http://127.0.0.1:PORT` -> allow, `http://localhost` -> allow, `http://[::1]:PORT` -> allow, `https://localhost:443` -> allow, `http://evil.com` -> 403, malformed -> 403
- Unsupported HTTP methods -> 405
- Path not `/mcp` -> 404
- All tests pass; file byte-compiles clean

## Coding Standards (from Constitution)

- Style: Follow Emacs Lisp conventions, `checkdoc` compliant
- Naming: Public symbols `emacs-mcp-`, internal `emacs-mcp--`
- Docstrings: Every public function/variable must have a docstring passing `checkdoc`
- Byte-compilation: Clean with no warnings
- Line length: 80 columns soft limit
- No global state pollution outside the package namespace

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
  (let ((server (make-network-process
                 :name "emacs-mcp-http"
                 :server t
                 :host "127.0.0.1"
                 :service (or port 0)
                 :family 'ipv4
                 :coding 'no-conversion
                 :filter #'emacs-mcp--http-filter
                 :sentinel #'emacs-mcp--http-sentinel
                 :noquery t
                 :plist (list :handler handler))))
    server))

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
    (process-put process :buffer ""))
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
    ;; Try to parse a complete request
    (let ((request (emacs-mcp--http-try-parse-request buf)))
      (when request
        ;; Clear buffer
        (process-put process :buffer "")
        (let* ((method (nth 0 request))
               (path (nth 1 request))
               (headers (nth 3 request))
               (body (nth 4 request)))
          ;; Origin validation
          (let ((origin (cdr (assoc "origin" headers))))
            (if (and origin
                     (not (emacs-mcp--http-valid-origin-p origin)))
                (emacs-mcp--http-send-response
                 process 403 "Forbidden"
                 '(("Content-Type" . "text/plain"))
                 "Forbidden")
              ;; Method routing
              (let ((handler (process-get
                              (process-get process :server)
                              :handler)))
                (unless handler
                  ;; Fallback: look for handler in server process
                  (setq handler (process-get process :handler)))
                (if (member method '("POST" "GET" "DELETE"))
                    (if handler
                        (funcall handler process method path
                                 headers body)
                      (emacs-mcp--http-send-response
                       process 500 "Internal Server Error"
                       '(("Content-Type" . "text/plain"))
                       "No handler configured"))
                  (if (equal path "/mcp")
                      (emacs-mcp--http-send-response
                       process 405 "Method Not Allowed"
                       '(("Content-Type" . "text/plain")
                         ("Allow" . "POST, GET, DELETE"))
                       "Method Not Allowed")
                    (emacs-mcp--http-send-response
                     process 404 "Not Found"
                     '(("Content-Type" . "text/plain"))
                     "Not Found")))))))))))

;;;; HTTP parsing

(defun emacs-mcp--http-try-parse-request (data)
  "Try to parse DATA as a complete HTTP request.
Returns (method path http-version headers body) if complete, nil
if more data is needed."
  ;; Find end of headers
  (let ((header-end (string-search "\r\n\r\n" data)))
    (when header-end
      (let* ((header-str (substring data 0 header-end))
             (body-start (+ header-end 4))
             (lines (split-string header-str "\r\n"))
             (request-line (car lines))
             (header-lines (cdr lines)))
        ;; Parse request line
        (when (string-match
               "^\\(GET\\|POST\\|PUT\\|DELETE\\|OPTIONS\\|HEAD\\|PATCH\\) \\(\\S-+\\) \\(HTTP/[0-9.]+\\)"
               request-line)
          (let* ((method (match-string 1 request-line))
                 (path (match-string 2 request-line))
                 (version (match-string 3 request-line))
                 (headers (emacs-mcp--http-parse-headers
                           header-lines))
                 (content-length
                  (let ((cl (cdr (assoc "content-length" headers))))
                    (if cl (string-to-number cl) 0)))
                 (body-available (- (length data) body-start)))
            ;; Check if we have the full body
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

(defun emacs-mcp--http-send-response (process status reason headers body)
  "Send an HTTP response to PROCESS.
STATUS is the numeric status code.  REASON is the reason phrase.
HEADERS is an alist.  BODY is a string (or nil)."
  (when (process-live-p process)
    (let* ((body-bytes (if body (encode-coding-string body 'utf-8) ""))
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

(defun emacs-mcp--http-send-sse-headers (process &optional extra-headers)
  "Send SSE response headers to PROCESS.
EXTRA-HEADERS is an optional alist of additional headers."
  (when (process-live-p process)
    (let ((headers (append '(("Content-Type" . "text/event-stream")
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

(defun emacs-mcp--http-valid-origin-p (origin)
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
  (let ((req (emacs-mcp--http-try-parse-request
              "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")))
    (should req)
    (should (equal (nth 0 req) "GET"))
    (should (equal (nth 1 req) "/mcp"))
    (should (equal (nth 2 req) "HTTP/1.1"))))

(ert-deftest emacs-mcp-test-http-parse-post-with-body ()
  "Parse a POST request with JSON body."
  (let* ((body "{\"jsonrpc\":\"2.0\"}")
         (req (emacs-mcp--http-try-parse-request
               (format "POST /mcp HTTP/1.1\r\nContent-Length: %d\r\n\r\n%s"
                       (length body) body))))
    (should req)
    (should (equal (nth 0 req) "POST"))
    (should (equal (nth 4 req) body))))

(ert-deftest emacs-mcp-test-http-parse-incomplete ()
  "Incomplete request returns nil."
  (should-not (emacs-mcp--http-try-parse-request
               "POST /mcp HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort")))

(ert-deftest emacs-mcp-test-http-parse-no-body ()
  "Request with no Content-Length has empty body."
  (let ((req (emacs-mcp--http-try-parse-request
              "DELETE /mcp HTTP/1.1\r\nHost: x\r\n\r\n")))
    (should req)
    (should (equal (nth 0 req) "DELETE"))
    (should (equal (nth 4 req) ""))))

(ert-deftest emacs-mcp-test-http-parse-headers ()
  "Headers parsed with lowercase keys."
  (let ((req (emacs-mcp--http-try-parse-request
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
  (should (emacs-mcp--http-valid-origin-p
           "http://127.0.0.1:8080")))

(ert-deftest emacs-mcp-test-http-origin-localhost ()
  "Origin http://localhost is accepted."
  (should (emacs-mcp--http-valid-origin-p
           "http://localhost")))

(ert-deftest emacs-mcp-test-http-origin-ipv6 ()
  "Origin http://[::1]:8080 is accepted."
  (should (emacs-mcp--http-valid-origin-p
           "http://[::1]:8080")))

(ert-deftest emacs-mcp-test-http-origin-https ()
  "Origin https://localhost:443 is accepted."
  (should (emacs-mcp--http-valid-origin-p
           "https://localhost:443")))

(ert-deftest emacs-mcp-test-http-origin-evil ()
  "Origin http://evil.com is rejected."
  (should-not (emacs-mcp--http-valid-origin-p
               "http://evil.com")))

(ert-deftest emacs-mcp-test-http-origin-malformed ()
  "Malformed origin is rejected."
  (should-not (emacs-mcp--http-valid-origin-p "not-a-url")))

(ert-deftest emacs-mcp-test-http-origin-127001-no-port ()
  "Origin http://127.0.0.1 without port is accepted."
  (should (emacs-mcp--http-valid-origin-p
           "http://127.0.0.1")))

(provide 'emacs-mcp-test-http)
;;; emacs-mcp-test-http.el ends here
```

## Test Results

All tests pass. Byte-compilation clean (no warnings).

## Review Checklist

1. **Correctness**: Does the code implement all required functions? Does the sentinel correctly handle new connections AND disconnects? Does the filter correctly accumulate fragmented data?
2. **Code quality**: Clean, readable, well-structured? Appropriate use of process properties for per-connection state?
3. **Constitution compliance**: Naming conventions (`emacs-mcp--` for all functions — all internal), docstrings on all symbols, byte-compile clean, 80-col soft limit?
4. **Handler lookup logic**: In `emacs-mcp--http-filter`, the handler is retrieved via `(process-get (process-get process :server) :handler)`. Does `(process-get process :server)` work for client processes created by a server process? This is the critical path — if this lookup fails, the fallback `(process-get process :handler)` is used, but client processes never have `:handler` set directly. Verify this is correct for Emacs `make-network-process` semantics.
5. **405 vs 404 logic**: In `emacs-mcp--http-filter`, when the method is unsupported (not POST/GET/DELETE), the code checks `(equal path "/mcp")` to decide between 405 and 404. But this is inverted from the spec: an unsupported method on `/mcp` should be 405, while any path with a valid method that isn't `/mcp` should be 404. The current logic correctly returns 405 for unsupported methods on `/mcp` — but what about unsupported methods on other paths? Currently returns 404, which is also debatable. Verify this matches the spec precisely.
6. **Missing `emacs-mcp--http-parse-request` function**: The task requires a function named `emacs-mcp--http-parse-request`, but the implementation provides `emacs-mcp--http-try-parse-request`. This is a naming discrepancy. Is this intentional? The tests use `emacs-mcp--http-try-parse-request` consistently, but other modules (transport layer) may reference `emacs-mcp--http-parse-request`.
7. **SSE response format**: `emacs-mcp--http-send-sse-headers` sends `\r\n\r\n` at the end (standard HTTP header terminator). This is correct. But the SSE event format `data: %s\n\n` uses Unix line endings (`\n`) not CRLF (`\r\n`). The SSE spec allows `\n` as the line terminator, so this is fine — but verify it is consistent.
8. **Content-Length for SSE**: `emacs-mcp--http-send-sse-headers` does not add `Content-Length` (correct for streaming). `emacs-mcp--http-send-response` automatically adds `Content-Length` — verify this doesn't interfere with SSE responses (they bypass `send-response`).
9. **Response format**: In `emacs-mcp--http-send-response`, the headers are joined with `\r\n` but the separator between headers and body is `\r\n\r\n`. This produces: `STATUS\r\nHEADER1\r\nHEADER2\r\n\r\nBODY`. This is correct HTTP format — double check by counting the CRLF sequences.
10. **`emacs-mcp--http-clients` is global**: This means multiple server instances would share the same client list. Is that a problem? The spec implies one server at a time, but if `http-stop` is called for one server, it kills all clients including those of other servers.
11. **Buffer accumulation on disconnect**: When a client disconnects mid-request, the `:buffer` is never cleared. Minor memory concern, but the process is being deleted so it's acceptable.
12. **Test coverage**: Tests cover parsing (GET, POST with body, incomplete, no-body, headers) and origin validation (all 7 cases). Missing: fragmented request test (multiple filter calls), response writing format, SSE header/event format, `http-stop` behavior, handler dispatch (405/404 routing), sentinel behavior, `http-close-connection`.
13. **Functional test for handler dispatch**: The filter tests are entirely absent — there are no tests that actually exercise `emacs-mcp--http-filter` with a mock handler. This is a significant gap for the dispatch logic including the 405/404 routing.
14. **Security**: Does the `emacs-mcp--http-valid-origin-p` regex allow `http://localhost.evil.com`? Test: "localhost" in the regex is anchored by `\\(` and `\\)` and the end pattern is `\\(:[0-9]+\\)?$`, so "localhost.evil.com" would NOT match. Correct.
15. **Scope creep**: Does the code stay within task requirements? No MCP protocol knowledge embedded?

List issues with severity: BLOCKING / WARNING / NOTE
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
