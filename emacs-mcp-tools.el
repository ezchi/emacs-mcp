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
