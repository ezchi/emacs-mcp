;;; emacs-mcp-test-jsonrpc.el --- Tests for emacs-mcp-jsonrpc -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the JSON-RPC 2.0 message handling layer.

;;; Code:

(require 'ert)
(require 'emacs-mcp-jsonrpc)

;;;; Parse tests

(ert-deftest emacs-mcp-test-jsonrpc-parse-single-request ()
  "Parse a valid single JSON-RPC request."
  (let ((msg (emacs-mcp--jsonrpc-parse
              "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\",\"params\":{}}")))
    (should (equal (alist-get 'jsonrpc msg) "2.0"))
    (should (equal (alist-get 'id msg) 1))
    (should (equal (alist-get 'method msg) "test"))))

(ert-deftest emacs-mcp-test-jsonrpc-parse-notification ()
  "Parse a valid JSON-RPC notification (no id)."
  (let ((msg (emacs-mcp--jsonrpc-parse
              "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")))
    (should (equal (alist-get 'method msg) "notifications/initialized"))
    (should-not (assq 'id msg))))

(ert-deftest emacs-mcp-test-jsonrpc-parse-response ()
  "Parse a valid JSON-RPC response."
  (let ((msg (emacs-mcp--jsonrpc-parse
              "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"key\":\"val\"}}")))
    (should (equal (alist-get 'id msg) 1))
    (should (alist-get 'result msg))))

(ert-deftest emacs-mcp-test-jsonrpc-parse-batch ()
  "Parse a valid JSON-RPC batch array."
  (let ((msgs (emacs-mcp--jsonrpc-parse
               "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"a\"},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"b\"}]")))
    (should (emacs-mcp--jsonrpc-batch-p msgs))
    (should (= (length msgs) 2))
    (should (equal (alist-get 'method (car msgs)) "a"))
    (should (equal (alist-get 'method (cadr msgs)) "b"))))

(ert-deftest emacs-mcp-test-jsonrpc-parse-malformed ()
  "Malformed JSON signals an error."
  (should-error (emacs-mcp--jsonrpc-parse "not json")
                :type 'json-parse-error))

(ert-deftest emacs-mcp-test-jsonrpc-parse-string-id ()
  "Parse a request with a string ID."
  (let ((msg (emacs-mcp--jsonrpc-parse
              "{\"jsonrpc\":\"2.0\",\"id\":\"abc-123\",\"method\":\"test\"}")))
    (should (equal (alist-get 'id msg) "abc-123"))))

(ert-deftest emacs-mcp-test-jsonrpc-parse-null-id ()
  "Parse a request with null ID — assq finds the id key with :null value."
  (let ((msg (emacs-mcp--jsonrpc-parse
              "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"test\"}")))
    (should (assq 'id msg))
    (should (eq (alist-get 'id msg) :null))))

;;;; Type predicate tests

(ert-deftest emacs-mcp-test-jsonrpc-request-p ()
  "Identify a JSON-RPC request."
  (let ((msg (emacs-mcp--jsonrpc-parse
              "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}")))
    (should (emacs-mcp--jsonrpc-request-p msg))
    (should-not (emacs-mcp--jsonrpc-notification-p msg))))

(ert-deftest emacs-mcp-test-jsonrpc-notification-p ()
  "Identify a JSON-RPC notification."
  (let ((msg (emacs-mcp--jsonrpc-parse
              "{\"jsonrpc\":\"2.0\",\"method\":\"notify\"}")))
    (should (emacs-mcp--jsonrpc-notification-p msg))
    (should-not (emacs-mcp--jsonrpc-request-p msg))))

(ert-deftest emacs-mcp-test-jsonrpc-response-p ()
  "Identify a JSON-RPC response."
  (let ((msg (emacs-mcp--jsonrpc-parse
              "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}")))
    (should (emacs-mcp--jsonrpc-response-p msg))
    (should-not (emacs-mcp--jsonrpc-notification-p msg))))

(ert-deftest emacs-mcp-test-jsonrpc-batch-p-single ()
  "A single message is not a batch."
  (let ((msg (emacs-mcp--jsonrpc-parse
              "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"test\"}")))
    (should-not (emacs-mcp--jsonrpc-batch-p msg))))

(ert-deftest emacs-mcp-test-jsonrpc-batch-p-empty ()
  "An empty list is not a batch."
  (should-not (emacs-mcp--jsonrpc-batch-p nil)))

;;;; Response construction tests

(ert-deftest emacs-mcp-test-jsonrpc-make-response ()
  "Build a success response."
  (let ((resp (emacs-mcp--jsonrpc-make-response 1 '((key . "val")))))
    (should (equal (alist-get 'jsonrpc resp) "2.0"))
    (should (equal (alist-get 'id resp) 1))
    (should (equal (alist-get 'key (alist-get 'result resp)) "val"))))

(ert-deftest emacs-mcp-test-jsonrpc-make-response-string-id ()
  "Response preserves string ID exactly."
  (let ((resp (emacs-mcp--jsonrpc-make-response "abc-123" '((ok . t)))))
    (should (equal (alist-get 'id resp) "abc-123"))))

(ert-deftest emacs-mcp-test-jsonrpc-make-error ()
  "Build an error response."
  (let ((resp (emacs-mcp--jsonrpc-make-error 1 -32601 "Method not found")))
    (should (equal (alist-get 'jsonrpc resp) "2.0"))
    (should (equal (alist-get 'id resp) 1))
    (let ((err (alist-get 'error resp)))
      (should (equal (alist-get 'code err) -32601))
      (should (equal (alist-get 'message err) "Method not found")))))

(ert-deftest emacs-mcp-test-jsonrpc-make-error-with-data ()
  "Build an error response with additional data."
  (let ((resp (emacs-mcp--jsonrpc-make-error 1 -32602 "Invalid params" "details")))
    (let ((err (alist-get 'error resp)))
      (should (equal (alist-get 'data err) "details")))))

(ert-deftest emacs-mcp-test-jsonrpc-make-error-null-id ()
  "Error response with :null ID (for parse errors)."
  (let ((resp (emacs-mcp--jsonrpc-make-error :null -32700 "Parse error")))
    (should (eq (alist-get 'id resp) :null))))

;;;; Serialization tests

(ert-deftest emacs-mcp-test-jsonrpc-serialize-response ()
  "Serialize a success response to JSON."
  (let* ((resp (emacs-mcp--jsonrpc-make-response 1 '((key . "val"))))
         (json (emacs-mcp--jsonrpc-serialize resp)))
    (should (stringp json))
    ;; Round-trip: parse it back
    (let ((parsed (emacs-mcp--jsonrpc-parse json)))
      (should (equal (alist-get 'id parsed) 1))
      (should (equal (alist-get 'key (alist-get 'result parsed)) "val")))))

(ert-deftest emacs-mcp-test-jsonrpc-serialize-error ()
  "Serialize an error response to JSON."
  (let* ((resp (emacs-mcp--jsonrpc-make-error 1 -32601 "Not found"))
         (json (emacs-mcp--jsonrpc-serialize resp)))
    (should (stringp json))
    (let ((parsed (emacs-mcp--jsonrpc-parse json)))
      (should (equal (alist-get 'code (alist-get 'error parsed)) -32601)))))

(ert-deftest emacs-mcp-test-jsonrpc-serialize-batch ()
  "Serialize a batch of responses."
  (let* ((batch (list (emacs-mcp--jsonrpc-make-response 1 '((a . 1)))
                      (emacs-mcp--jsonrpc-make-response 2 '((b . 2)))))
         (json (emacs-mcp--jsonrpc-serialize batch)))
    (should (stringp json))
    (let ((parsed (emacs-mcp--jsonrpc-parse json)))
      (should (emacs-mcp--jsonrpc-batch-p parsed))
      (should (= (length parsed) 2)))))

;;;; Error code constant tests

(ert-deftest emacs-mcp-test-jsonrpc-error-codes ()
  "Error code constants have correct values."
  (should (= emacs-mcp--jsonrpc-parse-error -32700))
  (should (= emacs-mcp--jsonrpc-invalid-request -32600))
  (should (= emacs-mcp--jsonrpc-method-not-found -32601))
  (should (= emacs-mcp--jsonrpc-invalid-params -32602))
  (should (= emacs-mcp--jsonrpc-internal-error -32603)))

(provide 'emacs-mcp-test-jsonrpc)
;;; emacs-mcp-test-jsonrpc.el ends here
