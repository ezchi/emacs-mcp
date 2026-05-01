# Gauge Code Review — Task 5: Tool Registry Framework (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Implement `emacs-mcp-tools.el`: The tool registration system — `emacs-mcp-deftool` macro, programmatic `register/unregister` functions, JSON Schema generation from parameter declarations, argument validation, result wrapping, and tool dispatch with confirmation integration.

**Functions/macros to implement**:
- `emacs-mcp--tools` — Global alist: `((name . tool-entry) ...)`
- `emacs-mcp-deftool` — Macro: define handler function, register tool
- `emacs-mcp-register-tool` — Programmatic registration with `:name`, `:description`, `:params`, `:handler`, `:confirm`
- `emacs-mcp-unregister-tool` — Remove tool by name, error if not found
- `emacs-mcp--tool-input-schema` — Generate JSON Schema object from param plists (FR-2.2 type mapping)
- `emacs-mcp--validate-tool-args` — Validate required args present + type checking (FR-2.7)
- `emacs-mcp--wrap-tool-result` — Wrap handler return into `CallToolResult` (string -> text content, list -> as-is, error -> isError) (FR-2.6)
- `emacs-mcp--dispatch-tool` — Find tool, validate args, check confirmation, call handler, wrap result. Bind `emacs-mcp--current-session-id` and `emacs-mcp--current-request-id` during execution (FR-5.1)
- `emacs-mcp--current-session-id` / `emacs-mcp--current-request-id` — Dynamic variables for deferred context

**Verification criteria**:
- `deftool` registers a tool callable by name
- `register-tool` programmatic API equivalent to `deftool`
- `unregister-tool` removes; error on unknown tool
- JSON Schema generation: all 6 types (string, integer, number, boolean, array, object)
- Schema has `type: "object"`, `properties`, `required` fields
- Arg validation: missing required -> error, wrong type -> error, unknown tool -> error
- Null values accepted for optional arguments
- Result wrapping: string return, list return, error signal
- Confirmation integration: tool with `:confirm t` calls `emacs-mcp-confirm-function`; denied returns "User denied execution."
- `deferred` symbol return detected (not wrapped)
- Dynamic variables bound during handler execution
- All tests pass; file byte-compiles clean

## Coding Standards (from Constitution)

- Style: Follow Emacs Lisp conventions, `checkdoc` compliant
- Naming: Public symbols `emacs-mcp-`, internal `emacs-mcp--`
- Docstrings: Every public function/variable must have a docstring passing `checkdoc`
- Byte-compilation: Clean with no warnings
- Line length: 80 columns soft limit
- Custom variables: Use `defcustom` with appropriate `:type`, `:group`, and `:safe` declarations
- No global state pollution outside the package namespace

## Full File: emacs-mcp-tools.el

```elisp
;;; emacs-mcp-tools.el --- Tool registry framework for emacs-mcp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; License: AGPL-3.0-or-later
;; See the file LICENSE for the full license text.

;;; Commentary:

;; This library provides the tool registration and dispatch
;; framework used by the emacs-mcp package.  Tools are registered
;; via the `emacs-mcp-deftool' macro or the programmatic
;; `emacs-mcp-register-tool' function.

;;; Code:

(require 'emacs-mcp)
(require 'emacs-mcp-jsonrpc)
(require 'emacs-mcp-confirm)

;;;; Dynamic variables for deferred context

(defvar emacs-mcp--current-session-id nil
  "Session ID bound during tool handler execution.")

(defvar emacs-mcp--current-request-id nil
  "JSON-RPC request ID bound during tool handler execution.")

;;;; Global tool registry

(defvar emacs-mcp--tools nil
  "Alist of registered tools: ((NAME . ENTRY) ...).
Each ENTRY is a plist with :name, :description, :params,
:handler, :confirm.")

;;;; Tool registration

(defun emacs-mcp-register-tool (&rest args)
  "Register an MCP tool programmatically.
ARGS is a plist with keys :name (string), :description (string),
:params (list of param plists), :handler (function), and
optionally :confirm (boolean)."
  (let ((name (plist-get args :name))
        (desc (plist-get args :description))
        (params (plist-get args :params))
        (handler (plist-get args :handler))
        (confirm (plist-get args :confirm)))
    (unless name (error "Tool :name is required"))
    (unless handler (error "Tool :handler is required"))
    (setq emacs-mcp--tools
          (cons (cons name (list :name name
                                 :description (or desc "")
                                 :params (or params nil)
                                 :handler handler
                                 :confirm confirm))
                (assoc-delete-all name emacs-mcp--tools)))))

(defun emacs-mcp-unregister-tool (name)
  "Remove the tool named NAME from the registry.
Signals an error if no tool with that name exists."
  (unless (assoc name emacs-mcp--tools)
    (error "Unknown tool: %s" name))
  (setq emacs-mcp--tools
        (assoc-delete-all name emacs-mcp--tools)))

;;;; deftool macro

(defmacro emacs-mcp-deftool (name docstring params handler &rest keys)
  "Define and register an MCP tool.
NAME is a symbol.  DOCSTRING is the tool description.
PARAMS is a list of parameter plists.  HANDLER is a lambda or
function that receives an alist of arguments.  KEYS may include
`:confirm t' to require user confirmation."
  (declare (indent 2))
  (let ((name-str (symbol-name name))
        (fn-sym (intern (format "emacs-mcp-tool-%s--handler"
                                (symbol-name name))))
        (confirm (plist-get keys :confirm)))
    `(progn
       (defun ,fn-sym (args)
         ,(format "Handler for MCP tool `%s'." name-str)
         (funcall ,handler args))
       (emacs-mcp-register-tool
        :name ,name-str
        :description ,docstring
        :params ',params
        :handler #',fn-sym
        :confirm ,confirm))))

;;;; JSON Schema generation

(defun emacs-mcp--tool-input-schema (params)
  "Generate a JSON Schema object from PARAMS (list of param plists).
Returns an alist suitable for JSON serialization."
  (let ((properties nil)
        (required nil))
    (dolist (p params)
      (let* ((name (plist-get p :name))
             (type (plist-get p :type))
             (desc (plist-get p :description))
             (req (plist-get p :required))
             (prop `((type . ,(emacs-mcp--type-to-json-schema type)))))
        (when desc
          (setq prop (append prop `((description . ,desc)))))
        (push (cons name prop) properties)
        (when req
          (push name required))))
    `((type . "object")
      (properties . ,(nreverse properties))
      (required . ,(vconcat (nreverse required))))))

(defun emacs-mcp--type-to-json-schema (type)
  "Convert an Elisp TYPE keyword to a JSON Schema type string."
  (pcase type
    ('string "string")
    ('integer "integer")
    ('number "number")
    ('boolean "boolean")
    ('array "array")
    ('object "object")
    (_ (error "Unknown tool parameter type: %S" type))))

;;;; Argument validation

(defun emacs-mcp--validate-tool-args (params args)
  "Validate ARGS against PARAMS declarations.
ARGS is an alist of (name . value) pairs.
Signals an error with details on validation failure."
  (dolist (p params)
    (let* ((name (plist-get p :name))
           (type (plist-get p :type))
           (req (plist-get p :required))
           (pair (assoc name args)))
      ;; Check required
      (when (and req (not pair))
        (error "Missing required argument: %s" name))
      ;; Type check if present and not null
      (when (and pair (not (eq (cdr pair) :null)))
        (emacs-mcp--check-arg-type name type (cdr pair))))))

(defun emacs-mcp--check-arg-type (name expected-type value)
  "Check that VALUE matches EXPECTED-TYPE for argument NAME.
Signals an error on type mismatch."
  (let ((ok (pcase expected-type
              ('string (stringp value))
              ('integer (integerp value))
              ('number (numberp value))
              ('boolean (or (eq value t) (eq value :false)))
              ('array (vectorp value))
              ('object (and (listp value) (or (null value)
                                              (consp (car value))))))))
    (unless ok
      (error "Invalid type for argument '%s': expected %s, got %s"
             name expected-type
             (emacs-mcp--describe-json-type value)))))

(defun emacs-mcp--describe-json-type (value)
  "Return a JSON type description string for VALUE."
  (cond
   ((stringp value) "string")
   ((integerp value) "integer")
   ((numberp value) "number")
   ((eq value t) "boolean")
   ((eq value :false) "boolean")
   ((vectorp value) "array")
   ((and (listp value) (consp (car value))) "object")
   ((null value) "null")
   (t (format "%S" (type-of value)))))

;;;; Result wrapping

(defun emacs-mcp--wrap-tool-result (result)
  "Wrap RESULT into an MCP CallToolResult alist.
- String: wrap as text content with isError=false.
- Vector of alists with `type' keys: use as content, isError=false.
- Symbol `deferred': return as-is (not wrapped)."
  (cond
   ;; Deferred: pass through
   ((eq result 'deferred) 'deferred)
   ;; String: wrap as text content
   ((stringp result)
    `((content . ,(vector `((type . "text") (text . ,result))))
      (isError . :false)))
   ;; Vector of content objects
   ((and (vectorp result)
         (> (length result) 0)
         (assq 'type (aref result 0)))
    `((content . ,result)
      (isError . :false)))
   ;; Fallback: convert to string
   (t
    `((content . ,(vector `((type . "text")
                            (text . ,(format "%S" result)))))
      (isError . :false)))))

(defun emacs-mcp--wrap-tool-error (err-msg)
  "Wrap ERR-MSG into an MCP CallToolResult with isError=true."
  `((content . ,(vector `((type . "text") (text . ,err-msg))))
    (isError . t)))

;;;; Tool dispatch

(defun emacs-mcp--dispatch-tool (name args session-id request-id)
  "Dispatch tool NAME with ARGS in the context of SESSION-ID.
REQUEST-ID is the JSON-RPC request ID for deferred support.
Returns a CallToolResult alist, the symbol `deferred', or
signals an error for protocol-level failures."
  (let ((entry (cdr (assoc name emacs-mcp--tools))))
    (unless entry
      (error "Unknown tool: %s" name))
    (let ((params (plist-get entry :params))
          (handler (plist-get entry :handler))
          (confirm (plist-get entry :confirm)))
      ;; Validate arguments
      (emacs-mcp--validate-tool-args params args)
      ;; Check confirmation
      (if (not (emacs-mcp--maybe-confirm name args confirm))
          (emacs-mcp--wrap-tool-error "User denied execution.")
        ;; Execute handler with dynamic context
        (let ((emacs-mcp--current-session-id session-id)
              (emacs-mcp--current-request-id request-id))
          (condition-case err
              (let ((result (funcall handler args)))
                (emacs-mcp--wrap-tool-result result))
            (error
             (emacs-mcp--wrap-tool-error
              (error-message-string err)))))))))

(provide 'emacs-mcp-tools)
;;; emacs-mcp-tools.el ends here
```

## Full File: test/emacs-mcp-test-tools.el

```elisp
;;; emacs-mcp-test-tools.el --- Tests for emacs-mcp-tools -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the tool registry framework.

;;; Code:

(require 'ert)
(require 'emacs-mcp-tools)

(defmacro emacs-mcp-test-with-clean-tools (&rest body)
  "Run BODY with an empty tool registry."
  (declare (indent 0))
  `(let ((emacs-mcp--tools nil))
     ,@body))

;;;; Registration tests

(ert-deftest emacs-mcp-test-tools-register ()
  "Register a tool programmatically."
  (emacs-mcp-test-with-clean-tools
    (emacs-mcp-register-tool
     :name "test-tool"
     :description "A test tool"
     :params '((:name "arg1" :type string :required t))
     :handler (lambda (_args) "ok"))
    (should (assoc "test-tool" emacs-mcp--tools))))

(ert-deftest emacs-mcp-test-tools-unregister ()
  "Unregister a tool."
  (emacs-mcp-test-with-clean-tools
    (emacs-mcp-register-tool :name "test" :handler #'ignore)
    (emacs-mcp-unregister-tool "test")
    (should-not (assoc "test" emacs-mcp--tools))))

(ert-deftest emacs-mcp-test-tools-unregister-unknown ()
  "Unregistering unknown tool signals error."
  (emacs-mcp-test-with-clean-tools
    (should-error (emacs-mcp-unregister-tool "nope"))))

(ert-deftest emacs-mcp-test-tools-deftool ()
  "Define a tool via deftool macro."
  (emacs-mcp-test-with-clean-tools
    (emacs-mcp-deftool test-macro-tool
      "A macro-defined tool."
      ((:name "input" :type string :required t))
      (lambda (args) (alist-get "input" args nil nil #'equal)))
    (should (assoc "test-macro-tool" emacs-mcp--tools))))

(ert-deftest emacs-mcp-test-tools-deftool-callable ()
  "Tool defined via deftool is callable."
  (emacs-mcp-test-with-clean-tools
    (emacs-mcp-deftool echo-tool
      "Echo the input."
      ((:name "text" :type string :required t))
      (lambda (args) (alist-get "text" args nil nil #'equal)))
    (let ((result (emacs-mcp--dispatch-tool
                   "echo-tool" '(("text" . "hello"))
                   "session-1" 1)))
      (should (equal (alist-get 'isError result) :false))
      (let ((content (aref (alist-get 'content result) 0)))
        (should (equal (alist-get 'text content) "hello"))))))

(ert-deftest emacs-mcp-test-tools-deftool-confirm ()
  "Tool with :confirm calls confirmation function."
  (emacs-mcp-test-with-clean-tools
    (emacs-mcp-deftool confirm-tool
      "Requires confirmation."
      ((:name "x" :type string :required t))
      (lambda (_args) "done")
      :confirm t)
    ;; Deny
    (let ((emacs-mcp-confirm-function #'ignore))
      (let ((result (emacs-mcp--dispatch-tool
                     "confirm-tool" '(("x" . "y"))
                     "s" 1)))
        (should (equal (alist-get 'isError result) t))))
    ;; Allow
    (let ((emacs-mcp-confirm-function #'always))
      (let ((result (emacs-mcp--dispatch-tool
                     "confirm-tool" '(("x" . "y"))
                     "s" 1)))
        (should (equal (alist-get 'isError result) :false))))))

;;;; Schema generation tests

(ert-deftest emacs-mcp-test-tools-schema-basic ()
  "Generate JSON Schema from params."
  (let ((schema (emacs-mcp--tool-input-schema
                 '((:name "name" :type string
                    :description "The name" :required t)
                   (:name "count" :type integer
                    :description "Count" :required nil)))))
    (should (equal (alist-get 'type schema) "object"))
    (let ((props (alist-get 'properties schema)))
      (should (equal (alist-get 'type (cdr (assoc "name" props)))
                     "string"))
      (should (equal (alist-get 'type (cdr (assoc "count" props)))
                     "integer")))
    ;; Required only includes "name"
    (should (equal (alist-get 'required schema)
                   (vector "name")))))

(ert-deftest emacs-mcp-test-tools-schema-all-types ()
  "Schema generation supports all 6 types."
  (dolist (pair '((string . "string") (integer . "integer")
                  (number . "number") (boolean . "boolean")
                  (array . "array") (object . "object")))
    (let ((schema (emacs-mcp--tool-input-schema
                   `((:name "x" :type ,(car pair) :required t)))))
      (should (equal (alist-get 'type
                                (cdr (assoc "x"
                                            (alist-get 'properties
                                                       schema))))
                     (cdr pair))))))

;;;; Argument validation tests

(ert-deftest emacs-mcp-test-tools-validate-missing-required ()
  "Missing required argument signals error."
  (should-error
   (emacs-mcp--validate-tool-args
    '((:name "x" :type string :required t))
    nil)))

(ert-deftest emacs-mcp-test-tools-validate-wrong-type ()
  "Wrong type signals error."
  (should-error
   (emacs-mcp--validate-tool-args
    '((:name "x" :type string :required t))
    '(("x" . 42)))))

(ert-deftest emacs-mcp-test-tools-validate-null-optional ()
  "Null values accepted for optional arguments."
  (emacs-mcp--validate-tool-args
   '((:name "x" :type string :required nil))
   '(("x" . :null))))

(ert-deftest emacs-mcp-test-tools-validate-correct ()
  "Valid arguments pass validation."
  (emacs-mcp--validate-tool-args
   '((:name "x" :type string :required t)
     (:name "n" :type integer :required nil))
   '(("x" . "hello") ("n" . 42))))

;;;; Result wrapping tests

(ert-deftest emacs-mcp-test-tools-wrap-string ()
  "String result wrapped as text content."
  (let ((result (emacs-mcp--wrap-tool-result "hello")))
    (should (equal (alist-get 'isError result) :false))
    (let ((content (aref (alist-get 'content result) 0)))
      (should (equal (alist-get 'type content) "text"))
      (should (equal (alist-get 'text content) "hello")))))

(ert-deftest emacs-mcp-test-tools-wrap-content-vector ()
  "Vector of content objects used as-is."
  (let* ((content (vector '((type . "text") (text . "ok"))))
         (result (emacs-mcp--wrap-tool-result content)))
    (should (equal (alist-get 'isError result) :false))
    (should (eq (alist-get 'content result) content))))

(ert-deftest emacs-mcp-test-tools-wrap-deferred ()
  "Deferred symbol passes through unwrapped."
  (should (eq (emacs-mcp--wrap-tool-result 'deferred) 'deferred)))

(ert-deftest emacs-mcp-test-tools-wrap-error ()
  "Error wrapping sets isError to t."
  (let ((result (emacs-mcp--wrap-tool-error "Something failed")))
    (should (equal (alist-get 'isError result) t))
    (let ((content (aref (alist-get 'content result) 0)))
      (should (equal (alist-get 'text content)
                     "Something failed")))))

;;;; Dispatch tests

(ert-deftest emacs-mcp-test-tools-dispatch-unknown ()
  "Dispatching unknown tool signals error."
  (emacs-mcp-test-with-clean-tools
    (should-error (emacs-mcp--dispatch-tool "nope" nil "s" 1))))

(ert-deftest emacs-mcp-test-tools-dispatch-handler-error ()
  "Handler error wrapped as tool execution error."
  (emacs-mcp-test-with-clean-tools
    (emacs-mcp-register-tool
     :name "fail" :handler (lambda (_) (error "Boom")))
    (let ((result (emacs-mcp--dispatch-tool
                   "fail" nil "s" 1)))
      (should (equal (alist-get 'isError result) t)))))

(ert-deftest emacs-mcp-test-tools-dispatch-dynamic-vars ()
  "Dynamic variables bound during handler execution."
  (emacs-mcp-test-with-clean-tools
    (let (captured-session captured-request)
      (emacs-mcp-register-tool
       :name "capture"
       :handler (lambda (_args)
                  (setq captured-session
                        emacs-mcp--current-session-id)
                  (setq captured-request
                        emacs-mcp--current-request-id)
                  "ok"))
      (emacs-mcp--dispatch-tool "capture" nil "sess-42" 99)
      (should (equal captured-session "sess-42"))
      (should (equal captured-request 99)))))

(ert-deftest emacs-mcp-test-tools-dispatch-deferred ()
  "Deferred return detected and not wrapped."
  (emacs-mcp-test-with-clean-tools
    (emacs-mcp-register-tool
     :name "async" :handler (lambda (_) 'deferred))
    (let ((result (emacs-mcp--dispatch-tool
                   "async" nil "s" 1)))
      (should (eq result 'deferred)))))

(provide 'emacs-mcp-test-tools)
;;; emacs-mcp-test-tools.el ends here
```

## Test Results

All tests pass. Byte-compilation clean (no warnings).

## Review Checklist

1. **Correctness**: Does the code implement all required functions/macros? Does `emacs-mcp-deftool` correctly generate a handler function AND register the tool? Does `emacs-mcp--dispatch-tool` correctly bind dynamic variables, validate args, check confirmation, call handler, and wrap results?
2. **Code quality**: Clean, readable, well-structured? Appropriate use of `plist-get`, `assoc`, `assoc-delete-all`?
3. **Constitution compliance**: Naming conventions (`emacs-mcp-` for public, `emacs-mcp--` for internal), docstrings on all symbols, byte-compile clean, 80-col soft limit?
4. **Correctness of `emacs-mcp-deftool`**: Is the `confirm` value correctly captured in the macro expansion? Is the generated handler function name stable and non-conflicting? Are `params` quoted correctly in the expansion?
5. **Schema correctness**: Does `emacs-mcp--tool-input-schema` produce a JSON Schema with `type: "object"`, `properties` as an alist, and `required` as a vector? Is property order stable?
6. **Validation logic**: Does `emacs-mcp--validate-tool-args` correctly handle: missing required args, wrong types, null optional args, unknown extra args (not validated — is that correct per spec)?
7. **Boolean type handling**: `boolean` validation checks `(eq value t)` or `(eq value :false)`. Does this correctly handle JSON false deserialized as `:false`? Is `:false` a standard convention in this codebase?
8. **Object type validation**: `object` type check uses `(and (listp value) (or (null value) (consp (car value))))`. Does an empty list `nil` pass as a valid object? Is that correct per the spec?
9. **Result wrapping**: `emacs-mcp--wrap-tool-result` fallback wraps non-string, non-vector values as `format "%S"`. Is this the intended behavior for arbitrary return values?
10. **Dependency on `emacs-mcp-jsonrpc`**: The file requires `emacs-mcp-jsonrpc` but does not appear to use any function from it. Is this unnecessary?
11. **Test coverage**: Are all key paths covered? Missing: `register-tool` overwrites existing tool (re-register), `deftool` with no params, empty params list schema, `validate-tool-args` with extra unknown args, `wrap-tool-result` with nil return value, `dispatch-tool` with validation failure (not just unknown tool), `deftool` `:confirm` keyword capture, `confirm` denied message matches "User denied execution."?
12. **Security**: Is the tool registry global? Can external code pollute it? Is the `condition-case` in dispatch too broad?
13. **Scope creep**: Does the code stay within task requirements? No premature MCP protocol integration?

List issues with severity: BLOCKING / WARNING / NOTE
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
