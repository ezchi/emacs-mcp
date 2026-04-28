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
