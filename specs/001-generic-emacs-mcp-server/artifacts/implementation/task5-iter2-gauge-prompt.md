# Gauge Code Review — Task 5: Tool Registry Framework (Iteration 2)

You are a strict code reviewer. This is iteration 2 after fixing all 3 BLOCKING issues from iteration 1.

## Previous Issues (Iteration 1)

1. BLOCKING: `emacs-mcp--wrap-tool-result` did not handle list-of-content-alists. A handler returning `(((type . "text") (text . "ok")))` was stringified instead of used as the content array.
2. BLOCKING: Required arguments set to JSON null `:null` passed validation. FR-2.7 requires null to be rejected for required params.
3. BLOCKING: Array parameter `:items` was ignored — `emacs-mcp--tool-input-schema` emitted only `((type . "array"))` without an `items` sub-schema.

## Fixes Applied

1. `emacs-mcp--wrap-tool-result` now has a third cond branch that recognises a list whose `car` is an alist with a `type` key, converts it with `vconcat`, and wraps it as the content vector.
2. `emacs-mcp--validate-tool-args` now has an explicit check: when a param is required AND its value is `:null`, it signals "Missing required argument". Optional `:null` still passes.
3. `emacs-mcp--tool-input-schema` now reads `:items` from the param plist and, when present for an `array` type, appends `(items . ((type . <item-type>)))` to the property alist.

New tests added: `emacs-mcp-test-tools-validate-null-required`, `emacs-mcp-test-tools-wrap-content-list`, `emacs-mcp-test-tools-schema-array-items`.

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
             (items (plist-get p :items))
             (prop `((type . ,(emacs-mcp--type-to-json-schema type)))))
        (when (and (eq type 'array) items)
          (setq prop (append prop
                             `((items . ((type . ,(emacs-mcp--type-to-json-schema items))))))))
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
      ;; Required null check: null values only accepted for optional
      (when (and req pair (eq (cdr pair) :null))
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
- List of alists with `type' keys: convert to vector, isError=false.
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
   ;; List of content objects — convert to vector
   ((and (listp result)
         (consp (car result))
         (assq 'type (car result)))
    `((content . ,(vconcat result))
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

(ert-deftest emacs-mcp-test-tools-schema-array-items ()
  "Array parameter with :items generates items sub-schema."
  (let ((schema (emacs-mcp--tool-input-schema
                 '((:name "tags" :type array :items string
                    :required t)))))
    (let* ((props (alist-get 'properties schema))
           (tags (cdr (assoc "tags" props))))
      (should (equal (alist-get 'type tags) "array"))
      (should (equal (alist-get 'type (alist-get 'items tags))
                     "string")))))

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

(ert-deftest emacs-mcp-test-tools-validate-null-required ()
  "Null values rejected for required arguments."
  (should-error
   (emacs-mcp--validate-tool-args
    '((:name "x" :type string :required t))
    '(("x" . :null)))))

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

(ert-deftest emacs-mcp-test-tools-wrap-content-list ()
  "List of content alists converted to vector."
  (let* ((content '(((type . "text") (text . "ok"))))
         (result (emacs-mcp--wrap-tool-result content)))
    (should (equal (alist-get 'isError result) :false))
    (should (vectorp (alist-get 'content result)))
    (should (equal (alist-get 'text
                              (aref (alist-get 'content result) 0))
                   "ok"))))

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

## Review Focus

1. Verify all 3 BLOCKING issues from iteration 1 are fixed
2. Verify `emacs-mcp--wrap-tool-result` correctly handles list-of-content-alists (not just vector)
3. Verify required `:null` check fires before type-check
4. Verify array `:items` schema is emitted with correct structure
5. Check `emacs-mcp-test-tools-validate-null-required` test is present and correct
6. Check `emacs-mcp-test-tools-wrap-content-list` test correctly exercises the list branch
7. Check `emacs-mcp-test-tools-schema-array-items` test verifies items sub-schema
8. Any remaining issues?

List issues with severity: BLOCKING / WARNING / NOTE
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
