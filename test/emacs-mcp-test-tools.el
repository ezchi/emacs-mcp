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
