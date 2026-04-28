# Gauge Code Review — Task 2: JSON-RPC 2.0 Layer (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Implement `emacs-mcp-jsonrpc.el`: JSON-RPC 2.0 message parsing, response construction, and error handling. Pure data transformation layer — no network, no MCP knowledge.

**Functions to implement**:
- `emacs-mcp--jsonrpc-parse` — Parse JSON string into alist(s); detect single vs batch
- `emacs-mcp--jsonrpc-batch-p` — Predicate: is parsed JSON a batch array?
- `emacs-mcp--jsonrpc-request-p` — Predicate: has `method` and `id`
- `emacs-mcp--jsonrpc-notification-p` — Predicate: has `method`, no `id`
- `emacs-mcp--jsonrpc-response-p` — Predicate: has `result` or `error`, and `id`
- `emacs-mcp--jsonrpc-make-response` — Build `{jsonrpc: "2.0", id: ..., result: ...}`
- `emacs-mcp--jsonrpc-make-error` — Build `{jsonrpc: "2.0", id: ..., error: {code, message, data}}`
- `emacs-mcp--jsonrpc-serialize` — Serialize alist to JSON string
- Error code constants: `-32700`, `-32600`, `-32601`, `-32602`, `-32603`

**Verification criteria**:
- Parse valid single request, notification, response
- Parse valid batch array
- Reject malformed JSON with parse error
- `make-response` produces correct structure with exact `id` preservation (string or number)
- `make-error` produces correct error object with code, message, data
- Batch predicate correctly identifies arrays vs single objects
- Null `id` in requests can be detected (for later rejection at protocol layer)
- All tests pass via `ert-run-tests-batch`
- File byte-compiles clean

## Coding Standards (from Constitution)

- Style: Follow Emacs Lisp conventions, `checkdoc` compliant
- Naming: Public symbols `emacs-mcp-`, internal `emacs-mcp--`
- Docstrings: Every public function/variable must have a docstring passing `checkdoc`
- Byte-compilation: Clean with no warnings
- Line length: 80 columns soft limit

## Full File: emacs-mcp-jsonrpc.el

```elisp
;;; emacs-mcp-jsonrpc.el --- JSON-RPC 2.0 message handling for emacs-mcp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; License: AGPL-3.0-or-later
;; See the file LICENSE for the full license text.

;;; Commentary:

;; This library implements JSON-RPC 2.0 message encoding, decoding,
;; and type predicates for the emacs-mcp package.  It is a pure data
;; transformation layer with no network or MCP knowledge.

;;; Code:

;;;; Error code constants

(defconst emacs-mcp--jsonrpc-parse-error -32700
  "JSON-RPC error code for parse errors.")

(defconst emacs-mcp--jsonrpc-invalid-request -32600
  "JSON-RPC error code for invalid requests.")

(defconst emacs-mcp--jsonrpc-method-not-found -32601
  "JSON-RPC error code for method not found.")

(defconst emacs-mcp--jsonrpc-invalid-params -32602
  "JSON-RPC error code for invalid method parameters.")

(defconst emacs-mcp--jsonrpc-internal-error -32603
  "JSON-RPC error code for internal errors.")

;;;; Parsing

(defun emacs-mcp--jsonrpc-parse (json-string)
  "Parse JSON-STRING into a JSON-RPC message or list of messages.
Returns a single alist for a single message, or a list of alists
for a batch array.  Signals `json-parse-error' on malformed JSON."
  (let ((parsed (json-parse-string json-string
                                   :object-type 'alist
                                   :array-type 'list
                                   :null-object :null
                                   :false-object :false)))
    parsed))

;;;; Type predicates

(defun emacs-mcp--jsonrpc-batch-p (parsed)
  "Return non-nil if PARSED is a JSON-RPC batch (a list of alists)."
  (and (listp parsed)
       (not (null parsed))
       ;; An alist is also a list, so we distinguish by checking
       ;; whether the first element is itself a cons with a symbol car
       ;; (alist entry) or a full alist (batch element).
       ;; A batch is a list of alists; an alist has (symbol . value) pairs.
       ;; We check: if the car is a cons whose car is a symbol, it's an alist.
       ;; If the car is an alist (list of conses), it's a batch.
       (let ((first (car parsed)))
         (and (listp first)
              (consp (car first))))))

(defun emacs-mcp--jsonrpc-request-p (msg)
  "Return non-nil if MSG is a JSON-RPC request (has `method' and `id')."
  (and (alist-get 'method msg)
       (assq 'id msg)))

(defun emacs-mcp--jsonrpc-notification-p (msg)
  "Return non-nil if MSG is a JSON-RPC notification (has `method', no `id')."
  (and (alist-get 'method msg)
       (not (assq 'id msg))))

(defun emacs-mcp--jsonrpc-response-p (msg)
  "Return non-nil if MSG is a JSON-RPC response (has `result' or `error')."
  (and (assq 'id msg)
       (or (assq 'result msg)
           (assq 'error msg))))

;;;; Response construction

(defun emacs-mcp--jsonrpc-make-response (id result)
  "Build a JSON-RPC 2.0 success response alist.
ID is the request ID (string or number), RESULT is the result value."
  `((jsonrpc . "2.0")
    (id . ,id)
    (result . ,result)))

(defun emacs-mcp--jsonrpc-make-error (id code message &optional data)
  "Build a JSON-RPC 2.0 error response alist.
ID is the request ID (string, number, or :null for parse errors).
CODE is the error code integer.  MESSAGE is the error description.
DATA is optional additional error data."
  (let ((err `((code . ,code)
               (message . ,message))))
    (when data
      (setq err (append err `((data . ,data)))))
    `((jsonrpc . "2.0")
      (id . ,id)
      (error . ,err))))

;;;; Serialization

(defun emacs-mcp--jsonrpc-serialize (msg)
  "Serialize MSG (an alist or list of alists) to a JSON string.
MSG can be a single JSON-RPC message alist or a list of message
alists (batch response).  Batch lists are converted to vectors
for correct JSON array serialization."
  (let ((obj (if (emacs-mcp--jsonrpc-batch-p msg)
                 (vconcat msg)
               msg)))
    (json-serialize obj
                    :null-object :null
                    :false-object :false)))

(provide 'emacs-mcp-jsonrpc)
;;; emacs-mcp-jsonrpc.el ends here
```

## Full File: test/emacs-mcp-test-jsonrpc.el

```elisp
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
```

## Test Results

All 21 tests pass. Byte-compilation clean (no warnings).

## Review Checklist

1. **Correctness**: Does the code implement all required functions? Any logic errors?
2. **Code quality**: Clean, readable, well-structured?
3. **Constitution compliance**: Naming conventions, docstrings, byte-compile clean?
4. **Security**: Any issues? (This is a pure data layer, no I/O)
5. **Error handling**: Malformed JSON handled? Edge cases?
6. **Test coverage**: All key paths covered? Missing edge cases?
7. **Performance**: Any unbounded loops or allocations?
8. **Scope creep**: Does the code stay within task requirements?

List issues with severity: BLOCKING / WARNING / NOTE
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
