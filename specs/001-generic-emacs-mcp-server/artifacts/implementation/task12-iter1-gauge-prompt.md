# Gauge Code Review — Task 12: Built-in Tools — Introspection, Diagnostics & Execute (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Implement the remaining 6 built-in tools in `emacs-mcp-tools-builtin.el`: diagnostics, imenu introspection, xref references, xref apropos, tree-sitter node inspection, and execute-elisp. These tools share the file with Task 11's buffer/file tools.

**Tools to implement** (Task 12 scope):
5. `get-diagnostics` — Flymake/flycheck diagnostics as JSON array (FR-3.6). Auto-detect backend: prefer flymake, fall back to flycheck (soft dependency via runtime detection), else empty. Flycheck is optional — guard with runtime detection.
6. `imenu-symbols` — Parse imenu index for file (FR-3.4). Path authorization check. Format: `category: name (line N)`.
7. `xref-find-references` — Find references via xref backend (FR-3.1). Optional file param for buffer context. Path authorization check.
8. `xref-find-apropos` — Search symbols matching pattern (FR-3.2). Results scoped to project-dir where possible.
9. `treesit-info` — Tree-sitter node inspection (FR-3.5). Path authorization check. Error if no tree-sitter for file type.
10. `execute-elisp` — Eval expression with confirmation (FR-3.10). Disabled by default (`emacs-mcp-enable-tool-execute-elisp` = nil). When disabled, not registered. When enabled, calls `emacs-mcp-confirm-function` before eval; denied returns "User denied execution."

**Verification criteria** (Task 12 focus):
- `get-diagnostics` with flymake returns diagnostics in correct JSON format (file, line, column, severity, message, source)
- `get-diagnostics` without flymake/flycheck returns empty array
- `imenu-symbols` returns `category: name (line N)` format; rejects outside paths
- `xref-find-references` returns `file:line: summary` entries or "No references found."
- `xref-find-apropos` returns matching symbols with locations
- `treesit-info` with tree-sitter file returns node info; without returns error
- `execute-elisp` disabled: not in tools registry
- `execute-elisp` enabled + confirm allowed: evaluates and returns `prin1-to-string` result
- `execute-elisp` enabled + confirm denied: returns "User denied execution."
- All tests pass; file byte-compiles clean

## Coding Standards (from Constitution)

- Style: Follow Emacs Lisp conventions, `checkdoc` compliant
- Naming: Public symbols `emacs-mcp-`, internal `emacs-mcp--`
- Docstrings: Every public function/variable must have a docstring passing `checkdoc`
- Byte-compilation: Clean with no warnings
- Line length: 80 columns soft limit
- No global state pollution outside the package namespace

## Full File: emacs-mcp-tools-builtin.el

```elisp
;;; emacs-mcp-tools-builtin.el --- Built-in MCP tools for emacs-mcp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; License: AGPL-3.0-or-later
;; See the file LICENSE for the full license text.

;;; Commentary:

;; This library defines the built-in MCP tools shipped with the
;; emacs-mcp package: project-info, list-buffers, open-file,
;; get-buffer-content, get-diagnostics, imenu-symbols,
;; xref-find-references, xref-find-apropos, treesit-info, and
;; execute-elisp.

;;; Code:

(require 'emacs-mcp)
(require 'emacs-mcp-tools)
(require 'emacs-mcp-session)
(require 'emacs-mcp-confirm)
(require 'imenu)
(require 'xref)
(require 'flymake)

;; Forward declarations for optional/treesit functions
(declare-function treesit-parser-list "treesit")
(declare-function treesit-node-at "treesit")
(declare-function treesit-node-type "treesit")
(declare-function treesit-node-text "treesit")
(declare-function treesit-node-start "treesit")
(declare-function treesit-node-end "treesit")
(declare-function treesit-node-child "treesit")
(declare-function treesit-node-child-count "treesit")
(declare-function treesit-parser-root-node "treesit")
(declare-function treesit-parser-language "treesit")
(declare-function flycheck-error-line "flycheck")
(declare-function flycheck-error-column "flycheck")
(declare-function flycheck-error-level "flycheck")
(declare-function flycheck-error-message "flycheck")

;;;; Enable defcustoms for all 10 tools

(defcustom emacs-mcp-enable-tool-project-info t
  "Whether the project-info tool is enabled."
  :type 'boolean :safe #'booleanp :group 'emacs-mcp)

(defcustom emacs-mcp-enable-tool-list-buffers t
  "Whether the list-buffers tool is enabled."
  :type 'boolean :safe #'booleanp :group 'emacs-mcp)

(defcustom emacs-mcp-enable-tool-open-file t
  "Whether the open-file tool is enabled."
  :type 'boolean :safe #'booleanp :group 'emacs-mcp)

(defcustom emacs-mcp-enable-tool-get-buffer-content t
  "Whether the get-buffer-content tool is enabled."
  :type 'boolean :safe #'booleanp :group 'emacs-mcp)

(defcustom emacs-mcp-enable-tool-get-diagnostics t
  "Whether the get-diagnostics tool is enabled."
  :type 'boolean :safe #'booleanp :group 'emacs-mcp)

(defcustom emacs-mcp-enable-tool-imenu-symbols t
  "Whether the imenu-symbols tool is enabled."
  :type 'boolean :safe #'booleanp :group 'emacs-mcp)

(defcustom emacs-mcp-enable-tool-xref-find-references t
  "Whether the xref-find-references tool is enabled."
  :type 'boolean :safe #'booleanp :group 'emacs-mcp)

(defcustom emacs-mcp-enable-tool-xref-find-apropos t
  "Whether the xref-find-apropos tool is enabled."
  :type 'boolean :safe #'booleanp :group 'emacs-mcp)

(defcustom emacs-mcp-enable-tool-treesit-info t
  "Whether the treesit-info tool is enabled."
  :type 'boolean :safe #'booleanp :group 'emacs-mcp)

(defcustom emacs-mcp-enable-tool-execute-elisp nil
  "Whether the execute-elisp tool is enabled.
Disabled by default for security."
  :type 'boolean :safe #'booleanp :group 'emacs-mcp)

;;;; Path authorization

(defun emacs-mcp--check-path-authorization (path)
  "Verify PATH is within the session's project directory.
Signals an error if PATH is outside the project directory."
  (let* ((session (emacs-mcp--session-get
                   emacs-mcp--current-session-id))
         (project-dir (when session
                        (emacs-mcp-session-project-dir session)))
         (abs-path (expand-file-name path)))
    (unless (and project-dir
                 (file-in-directory-p abs-path project-dir))
      (error "Path outside project directory: %s" abs-path))))

;;;; Tool 1: project-info

(defun emacs-mcp--tool-project-info (_args)
  "Return project metadata as a JSON string."
  (let* ((session (emacs-mcp--session-get
                   emacs-mcp--current-session-id))
         (project-dir (emacs-mcp-session-project-dir session))
         (active-buf (let ((buf (window-buffer
                                 (selected-window))))
                       (when (buffer-file-name buf)
                         (buffer-file-name buf))))
         (file-count (length
                      (directory-files-recursively
                       project-dir "." nil nil t))))
    (json-serialize
     `((projectDir . ,project-dir)
       (activeBuffer . ,(or active-buf :null))
       (fileCount . ,file-count))
     :null-object :null :false-object :false)))

;;;; Tool 2: list-buffers

(defun emacs-mcp--tool-list-buffers (_args)
  "Return project buffers as a JSON array."
  (let* ((session (emacs-mcp--session-get
                   emacs-mcp--current-session-id))
         (project-dir (emacs-mcp-session-project-dir session))
         (result nil))
    (dolist (buf (buffer-list))
      (let ((file (buffer-file-name buf)))
        (when (and file (file-in-directory-p file project-dir))
          (push `((path . ,file)
                  (modified . ,(if (buffer-modified-p buf) t
                                 :false))
                  (mode . ,(symbol-name
                            (buffer-local-value
                             'major-mode buf))))
                result))))
    (json-serialize (vconcat (nreverse result))
                    :null-object :null
                    :false-object :false)))

;;;; Tool 3: open-file

(defun emacs-mcp--tool-open-file (args)
  "Open a file with optional line/selection in ARGS."
  (let ((path (cdr (assoc "path" args)))
        (start-line (cdr (assoc "startLine" args)))
        (end-line (cdr (assoc "endLine" args))))
    (emacs-mcp--check-path-authorization path)
    (let ((buf (find-file-noselect path)))
      (with-current-buffer buf
        (when (and start-line (integerp start-line))
          (goto-char (point-min))
          (forward-line (1- start-line))
          (when (and end-line (integerp end-line))
            (push-mark (point) t t)
            (goto-char (point-min))
            (forward-line end-line))))
      (display-buffer buf)
      "FILE_OPENED")))

;;;; Tool 4: get-buffer-content

(defun emacs-mcp--tool-get-buffer-content (args)
  "Return buffer text, optionally for a line range in ARGS."
  (let ((file (cdr (assoc "file" args)))
        (start-line (cdr (assoc "startLine" args)))
        (end-line (cdr (assoc "endLine" args))))
    (emacs-mcp--check-path-authorization file)
    (let ((buf (get-file-buffer file)))
      (unless buf
        (error "Buffer not visiting file: %s" file))
      (with-current-buffer buf
        (if (and start-line end-line)
            (let ((start (save-excursion
                           (goto-char (point-min))
                           (forward-line (1- start-line))
                           (point)))
                  (end (save-excursion
                         (goto-char (point-min))
                         (forward-line end-line)
                         (point))))
              (buffer-substring-no-properties start end))
          (buffer-substring-no-properties
           (point-min) (point-max)))))))

;;;; Tool 5: get-diagnostics

(defun emacs-mcp--tool-get-diagnostics (args)
  "Return flymake/flycheck diagnostics as JSON in ARGS."
  (let ((file (cdr (assoc "file" args)))
        (diagnostics nil))
    (if file
        (let ((buf (get-file-buffer file)))
          (when buf
            (setq diagnostics
                  (emacs-mcp--collect-diagnostics buf))))
      ;; All project buffers
      (let* ((session (emacs-mcp--session-get
                       emacs-mcp--current-session-id))
             (project-dir
              (emacs-mcp-session-project-dir session)))
        (dolist (buf (buffer-list))
          (let ((bf (buffer-file-name buf)))
            (when (and bf (file-in-directory-p bf project-dir))
              (setq diagnostics
                    (append diagnostics
                            (emacs-mcp--collect-diagnostics
                             buf))))))))
    (json-serialize (vconcat diagnostics)
                    :null-object :null
                    :false-object :false)))

(defun emacs-mcp--collect-diagnostics (buffer)
  "Collect diagnostics from BUFFER using flymake or flycheck."
  (with-current-buffer buffer
    (let ((file (or (buffer-file-name) ""))
          (result nil))
      (cond
       ;; Prefer flymake
       ((bound-and-true-p flymake-mode)
        (dolist (diag (flymake-diagnostics))
          (push `((file . ,file)
                  (line . ,(line-number-at-pos
                            (flymake-diagnostic-beg diag)))
                  (column . ,(save-excursion
                               (goto-char
                                (flymake-diagnostic-beg diag))
                               (current-column)))
                  (severity
                   . ,(emacs-mcp--flymake-severity
                       (flymake-diagnostic-type diag)))
                  (message
                   . ,(flymake-diagnostic-text diag))
                  (source . "flymake"))
                result)))
       ;; Fall back to flycheck
       ((and (featurep 'flycheck)
             (bound-and-true-p flycheck-mode))
        (dolist (err (bound-and-true-p flycheck-current-errors))
          (push `((file . ,file)
                  (line . ,(flycheck-error-line err))
                  (column . ,(or (flycheck-error-column err) 0))
                  (severity
                   . ,(symbol-name (flycheck-error-level err)))
                  (message . ,(flycheck-error-message err))
                  (source . "flycheck"))
                result))))
      (nreverse result))))

(defun emacs-mcp--flymake-severity (type)
  "Convert flymake diagnostic TYPE to a severity string."
  (pcase type
    (:error "error")
    (:warning "warning")
    (:note "info")
    (_ "hint")))

;;;; Tool 6: imenu-symbols

(defun emacs-mcp--tool-imenu-symbols (args)
  "List symbols from imenu index for file in ARGS."
  (let ((file (cdr (assoc "file" args))))
    (emacs-mcp--check-path-authorization file)
    (let ((buf (find-file-noselect file)))
      (with-current-buffer buf
        (let ((index (ignore-errors (imenu--make-index-alist t)))
              (result nil))
          (emacs-mcp--flatten-imenu index nil
                                    (lambda (cat name pos)
                                      (push (format "%s: %s (line %d)"
                                                    cat name
                                                    (line-number-at-pos
                                                     pos))
                                            result)))
          (if result
              (string-join (nreverse result) "\n")
            "No symbols found."))))))

(defun emacs-mcp--flatten-imenu (index prefix callback)
  "Flatten imenu INDEX with PREFIX, calling CALLBACK for each entry."
  (dolist (item index)
    (cond
     ((and (consp item) (listp (cdr item)))
      ;; Sub-category
      (emacs-mcp--flatten-imenu (cdr item) (car item) callback))
     ((and (consp item) (or (markerp (cdr item))
                            (integerp (cdr item))
                            (overlayp (cdr item))))
      (let ((pos (cond
                  ((markerp (cdr item)) (marker-position (cdr item)))
                  ((overlayp (cdr item))
                   (overlay-start (cdr item)))
                  (t (cdr item)))))
        (funcall callback (or prefix "Other") (car item) pos))))))

;;;; Tool 7: xref-find-references

(defun emacs-mcp--tool-xref-find-references (args)
  "Find references to identifier in ARGS."
  (let ((identifier (cdr (assoc "identifier" args)))
        (file (cdr (assoc "file" args))))
    (when file
      (emacs-mcp--check-path-authorization file)
      (find-file-noselect file))
    (let ((xrefs (xref-matches-in-files
                  identifier
                  (project-files (project-current t)))))
      (if (null xrefs)
          "No references found."
        (mapconcat
         (lambda (xref)
           (let ((loc (xref-match-item-location xref)))
             (format "%s:%d: %s"
                     (xref-file-location-file loc)
                     (xref-file-location-line loc)
                     (xref-match-item-summary xref))))
         xrefs "\n")))))

;;;; Tool 8: xref-find-apropos

(defun emacs-mcp--tool-xref-find-apropos (args)
  "Search for symbols matching pattern in ARGS."
  (let* ((pattern (cdr (assoc "pattern" args)))
         (matches (xref-backend-apropos (xref-find-backend)
                                        pattern)))
    (if (null matches)
        "No symbols found."
      (mapconcat
       (lambda (item)
         (let ((loc (xref-item-location item)))
           (format "%s:%d: %s"
                   (xref-file-location-file loc)
                   (xref-file-location-line loc)
                   (xref-item-summary item))))
       matches "\n"))))

;;;; Tool 9: treesit-info

(defun emacs-mcp--tool-treesit-info (args)
  "Return tree-sitter info for file in ARGS."
  (let ((file (cdr (assoc "file" args)))
        (line (cdr (assoc "line" args)))
        (column (cdr (assoc "column" args))))
    (emacs-mcp--check-path-authorization file)
    (let ((buf (find-file-noselect file)))
      (with-current-buffer buf
        (unless (treesit-parser-list)
          (error "No tree-sitter parser for %s"
                 (file-name-extension file)))
        (if (and line (integerp line))
            ;; Node at position
            (let* ((pos (save-excursion
                          (goto-char (point-min))
                          (forward-line (1- line))
                          (when (and column (integerp column))
                            (forward-char column))
                          (point)))
                   (node (treesit-node-at pos)))
              (format "Type: %s\nText: %s\nRange: %d-%d"
                      (treesit-node-type node)
                      (truncate-string-to-width
                       (treesit-node-text node) 200)
                      (treesit-node-start node)
                      (treesit-node-end node)))
          ;; Top-level info
          (let* ((parser (car (treesit-parser-list)))
                 (root (treesit-parser-root-node parser))
                 (types nil))
            (dotimes (i (min (treesit-node-child-count root) 20))
              (let ((child (treesit-node-child root i)))
                (push (treesit-node-type child) types)))
            (format "Language: %s\nTop-level types: %s"
                    (treesit-parser-language parser)
                    (string-join (nreverse types) ", "))))))))

;;;; Tool 10: execute-elisp

(defun emacs-mcp--tool-execute-elisp (args)
  "Evaluate an Emacs Lisp expression from ARGS."
  (let ((expr (cdr (assoc "expression" args))))
    (unless (emacs-mcp--maybe-confirm "execute-elisp"
                                      args t)
      (error "User denied execution."))
    (prin1-to-string (eval (read expr) t))))

;;;; Tool registration

(defun emacs-mcp--register-builtin-tools ()
  "Register all enabled built-in tools."
  ;; Clear previous built-in registrations
  (dolist (name '("project-info" "list-buffers" "open-file"
                  "get-buffer-content" "get-diagnostics"
                  "imenu-symbols" "xref-find-references"
                  "xref-find-apropos" "treesit-info"
                  "execute-elisp"))
    (ignore-errors (emacs-mcp-unregister-tool name)))

  (when emacs-mcp-enable-tool-project-info
    (emacs-mcp-register-tool
     :name "project-info" :description "Return project metadata."
     :params nil :handler #'emacs-mcp--tool-project-info))

  (when emacs-mcp-enable-tool-list-buffers
    (emacs-mcp-register-tool
     :name "list-buffers"
     :description "Return open project buffers."
     :params nil :handler #'emacs-mcp--tool-list-buffers))

  (when emacs-mcp-enable-tool-open-file
    (emacs-mcp-register-tool
     :name "open-file"
     :description "Open a file in Emacs."
     :params '((:name "path" :type string :required t
                :description "Absolute path")
               (:name "startLine" :type integer :required nil
                :description "Start line")
               (:name "endLine" :type integer :required nil
                :description "End line"))
     :handler #'emacs-mcp--tool-open-file))

  (when emacs-mcp-enable-tool-get-buffer-content
    (emacs-mcp-register-tool
     :name "get-buffer-content"
     :description "Return buffer text."
     :params '((:name "file" :type string :required t
                :description "Absolute file path")
               (:name "startLine" :type integer :required nil)
               (:name "endLine" :type integer :required nil))
     :handler #'emacs-mcp--tool-get-buffer-content))

  (when emacs-mcp-enable-tool-get-diagnostics
    (emacs-mcp-register-tool
     :name "get-diagnostics"
     :description "Return diagnostics for file or project."
     :params '((:name "file" :type string :required nil
                :description "Optional file path"))
     :handler #'emacs-mcp--tool-get-diagnostics))

  (when emacs-mcp-enable-tool-imenu-symbols
    (emacs-mcp-register-tool
     :name "imenu-symbols"
     :description "List symbols in a file."
     :params '((:name "file" :type string :required t))
     :handler #'emacs-mcp--tool-imenu-symbols))

  (when emacs-mcp-enable-tool-xref-find-references
    (emacs-mcp-register-tool
     :name "xref-find-references"
     :description "Find references to a symbol."
     :params '((:name "identifier" :type string :required t)
               (:name "file" :type string :required nil))
     :handler #'emacs-mcp--tool-xref-find-references))

  (when emacs-mcp-enable-tool-xref-find-apropos
    (emacs-mcp-register-tool
     :name "xref-find-apropos"
     :description "Search symbols matching pattern."
     :params '((:name "pattern" :type string :required t))
     :handler #'emacs-mcp--tool-xref-find-apropos))

  (when emacs-mcp-enable-tool-treesit-info
    (emacs-mcp-register-tool
     :name "treesit-info"
     :description "Tree-sitter syntax info."
     :params '((:name "file" :type string :required t)
               (:name "line" :type integer :required nil)
               (:name "column" :type integer :required nil))
     :handler #'emacs-mcp--tool-treesit-info))

  (when emacs-mcp-enable-tool-execute-elisp
    (emacs-mcp-register-tool
     :name "execute-elisp"
     :description "Evaluate Emacs Lisp expression."
     :params '((:name "expression" :type string :required t))
     :handler #'emacs-mcp--tool-execute-elisp
     :confirm t)))

(provide 'emacs-mcp-tools-builtin)
;;; emacs-mcp-tools-builtin.el ends here
```

## Full File: test/emacs-mcp-test-tools-builtin.el

```elisp
;;; emacs-mcp-test-tools-builtin.el --- Tests for built-in tools -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for built-in MCP tools.

;;; Code:

(require 'ert)
(require 'emacs-mcp-tools-builtin)

(defmacro emacs-mcp-test-with-builtin (&rest body)
  "Run BODY with clean state and a test project directory."
  (declare (indent 0))
  `(let* ((tmpdir (make-temp-file "emacs-mcp-test-" t))
          (emacs-mcp--sessions (make-hash-table :test 'equal))
          (emacs-mcp--tools nil)
          (emacs-mcp-session-timeout 1800)
          (emacs-mcp--project-dir tmpdir)
          (session-id (emacs-mcp--session-create tmpdir))
          (emacs-mcp--current-session-id session-id)
          (emacs-mcp--current-request-id 1))
     (unwind-protect
         (progn ,@body)
       (maphash (lambda (_id s)
                  (when (emacs-mcp-session-timer s)
                    (cancel-timer (emacs-mcp-session-timer s))))
                emacs-mcp--sessions)
       (delete-directory tmpdir t))))

;;;; Path authorization tests

(ert-deftest emacs-mcp-test-builtin-path-auth-inside ()
  "Path inside project is accepted."
  (emacs-mcp-test-with-builtin
    (let ((file (expand-file-name "test.el" tmpdir)))
      (with-temp-file file (insert "test"))
      (emacs-mcp--check-path-authorization file))))

(ert-deftest emacs-mcp-test-builtin-path-auth-outside ()
  "Path outside project is rejected."
  (emacs-mcp-test-with-builtin
    (should-error
     (emacs-mcp--check-path-authorization "/etc/passwd"))))

;;;; Tool registration tests

(ert-deftest emacs-mcp-test-builtin-register-all ()
  "All enabled tools are registered."
  (emacs-mcp-test-with-builtin
    (emacs-mcp--register-builtin-tools)
    (should (assoc "project-info" emacs-mcp--tools))
    (should (assoc "list-buffers" emacs-mcp--tools))
    (should (assoc "open-file" emacs-mcp--tools))
    (should (assoc "get-buffer-content" emacs-mcp--tools))))

(ert-deftest emacs-mcp-test-builtin-execute-elisp-disabled ()
  "execute-elisp not registered when disabled."
  (emacs-mcp-test-with-builtin
    (let ((emacs-mcp-enable-tool-execute-elisp nil))
      (emacs-mcp--register-builtin-tools)
      (should-not (assoc "execute-elisp" emacs-mcp--tools)))))

(ert-deftest emacs-mcp-test-builtin-execute-elisp-enabled ()
  "execute-elisp registered with confirm when enabled."
  (emacs-mcp-test-with-builtin
    (let ((emacs-mcp-enable-tool-execute-elisp t))
      (emacs-mcp--register-builtin-tools)
      (should (assoc "execute-elisp" emacs-mcp--tools))
      (let ((entry (cdr (assoc "execute-elisp"
                                emacs-mcp--tools))))
        (should (plist-get entry :confirm))))))

;;;; project-info

(ert-deftest emacs-mcp-test-builtin-project-info ()
  "project-info returns project directory."
  (emacs-mcp-test-with-builtin
    (let ((result (emacs-mcp--tool-project-info nil)))
      (should (stringp result))
      (let ((parsed (json-parse-string result
                                       :object-type 'alist)))
        (should (equal (alist-get 'projectDir parsed)
                       tmpdir))))))

;;;; list-buffers

(ert-deftest emacs-mcp-test-builtin-list-buffers ()
  "list-buffers returns only project buffers."
  (emacs-mcp-test-with-builtin
    (let ((file (expand-file-name "test.el" tmpdir)))
      (with-temp-file file (insert ";; test"))
      (find-file-noselect file)
      (let ((result (emacs-mcp--tool-list-buffers nil)))
        (should (stringp result))
        (let ((parsed (json-parse-string result
                                         :object-type 'alist
                                         :array-type 'list)))
          (should (cl-some
                   (lambda (buf)
                     (string-suffix-p "test.el"
                                      (alist-get 'path buf)))
                   parsed)))))))

;;;; open-file

(ert-deftest emacs-mcp-test-builtin-open-file ()
  "open-file returns FILE_OPENED."
  (emacs-mcp-test-with-builtin
    (let ((file (expand-file-name "test.el" tmpdir)))
      (with-temp-file file (insert ";; test"))
      (should (equal (emacs-mcp--tool-open-file
                      `(("path" . ,file)))
                     "FILE_OPENED")))))

(ert-deftest emacs-mcp-test-builtin-open-file-outside ()
  "open-file rejects paths outside project."
  (emacs-mcp-test-with-builtin
    (should-error (emacs-mcp--tool-open-file
                   '(("path" . "/etc/passwd"))))))

;;;; get-buffer-content

(ert-deftest emacs-mcp-test-builtin-get-buffer-content ()
  "get-buffer-content returns buffer text."
  (emacs-mcp-test-with-builtin
    (let ((file (expand-file-name "test.el" tmpdir)))
      (with-temp-file file (insert "line1\nline2\nline3"))
      (find-file-noselect file)
      (let ((result (emacs-mcp--tool-get-buffer-content
                     `(("file" . ,file)))))
        (should (string-match-p "line1" result))
        (should (string-match-p "line3" result))))))

(ert-deftest emacs-mcp-test-builtin-get-buffer-content-range ()
  "get-buffer-content with range returns correct lines."
  (emacs-mcp-test-with-builtin
    (let ((file (expand-file-name "test.el" tmpdir)))
      (with-temp-file file (insert "line1\nline2\nline3\n"))
      (find-file-noselect file)
      (let ((result (emacs-mcp--tool-get-buffer-content
                     `(("file" . ,file)
                       ("startLine" . 2)
                       ("endLine" . 2)))))
        (should (string-match-p "line2" result))
        (should-not (string-match-p "line1" result))))))

;;;; execute-elisp

(ert-deftest emacs-mcp-test-builtin-execute-elisp-confirm-deny ()
  "execute-elisp denied returns error."
  (emacs-mcp-test-with-builtin
    (let ((emacs-mcp-confirm-function #'ignore))
      (should-error
       (emacs-mcp--tool-execute-elisp
        '(("expression" . "(+ 1 2)")))))))

(ert-deftest emacs-mcp-test-builtin-execute-elisp-confirm-allow ()
  "execute-elisp allowed evaluates expression."
  (emacs-mcp-test-with-builtin
    (let ((emacs-mcp-confirm-function #'always))
      (should (equal (emacs-mcp--tool-execute-elisp
                      '(("expression" . "(+ 1 2)")))
                     "3")))))

;;;; Enable defcustoms

(ert-deftest emacs-mcp-test-builtin-all-defcustoms-exist ()
  "All 10 enable defcustoms exist."
  (dolist (name '(emacs-mcp-enable-tool-project-info
                  emacs-mcp-enable-tool-list-buffers
                  emacs-mcp-enable-tool-open-file
                  emacs-mcp-enable-tool-get-buffer-content
                  emacs-mcp-enable-tool-get-diagnostics
                  emacs-mcp-enable-tool-imenu-symbols
                  emacs-mcp-enable-tool-xref-find-references
                  emacs-mcp-enable-tool-xref-find-apropos
                  emacs-mcp-enable-tool-treesit-info
                  emacs-mcp-enable-tool-execute-elisp))
    (should (boundp name))))

(ert-deftest emacs-mcp-test-builtin-execute-elisp-default-nil ()
  "execute-elisp defaults to nil (disabled)."
  (should-not (default-value 'emacs-mcp-enable-tool-execute-elisp)))

(provide 'emacs-mcp-test-tools-builtin)
;;; emacs-mcp-test-tools-builtin.el ends here
```

## Review Checklist

### 1. `get-diagnostics` — flycheck dependency handling

- The task spec says flycheck must be a soft dependency guarded with `(require 'flycheck nil t)` or `(featurep 'flycheck)` runtime detection only. The file has `(require 'flymake)` at the top (hard require, correct — flymake is built-in). There is NO `(require 'flycheck nil t)` soft-require call anywhere. The flycheck path is guarded by `(featurep 'flycheck)` at runtime — correct. HOWEVER: the `declare-function` calls for flycheck (`flycheck-error-line`, `flycheck-error-column`, `flycheck-error-level`, `flycheck-error-message`) are present at the top. These are for byte-compiler silence only and do NOT cause a load-time error. Correct.
- BLOCKING: The task spec says `(require 'flycheck nil t)` should be used somewhere to optionally load flycheck. The current code only uses `(featurep 'flycheck)` to check if it's already loaded — it never tries to load flycheck. This means flycheck diagnostics are only available if the user already loaded flycheck before calling the tool. If a user has flycheck installed but not yet loaded in this session, `(featurep 'flycheck)` returns nil and the tool falls through to an empty result even though flycheck is available. The guard `(featurep 'flycheck)` is too conservative — it should also attempt `(require 'flycheck nil t)` before checking the feature. BLOCKING.

### 2. `emacs-mcp--collect-diagnostics` — flymake `line-number-at-pos` call

- `(line-number-at-pos (flymake-diagnostic-beg diag))` — `line-number-at-pos` with one argument (a position) works correctly. The position `(flymake-diagnostic-beg diag)` is the buffer position of the diagnostic start. `line-number-at-pos` returns the line number at that position. CORRECT.
- `(save-excursion (goto-char (flymake-diagnostic-beg diag)) (current-column))` — saves and restores excursion, goes to the diagnostic start position, returns the column. This is the correct way to get the column from a buffer position. CORRECT.
- The `result` list is reversed with `(nreverse result)` at the end. Since diagnostics are pushed in `dolist` order and then nreversed, the final order matches document order. CORRECT.

### 3. `emacs-mcp--collect-diagnostics` — `bound-and-true-p flycheck-current-errors`

- `(dolist (err (bound-and-true-p flycheck-current-errors) ...)` — `bound-and-true-p` is used as the list form in `dolist`. This evaluates `flycheck-current-errors` safely: if the variable is unbound, returns nil; if it's bound but nil, returns nil; if bound and non-nil, returns the list of errors. `dolist` then iterates over this list. CORRECT use of `bound-and-true-p` to guard the iteration.
- However, `bound-and-true-p` is documented as returning the value of the symbol, not just t/nil. This is correct Elisp usage. CORRECT.

### 4. `emacs-mcp--tool-imenu-symbols` — `emacs-mcp--flatten-imenu` logic

- `(ignore-errors (imenu--make-index-alist t))` — `ignore-errors` catches any error during index generation. If imenu fails entirely, `index` is nil, `result` stays nil, and "No symbols found." is returned. CORRECT graceful degradation.
- `emacs-mcp--flatten-imenu` first `cond` clause: `(and (consp item) (listp (cdr item)))` — this catches sub-categories (where cdr is a list of items). BUT: this also matches any cons cell whose cdr is a list, including items with `(cdr item)` being a list of markers. In imenu, leaf entries have `(car . POSITION)` where POSITION is a marker, integer, or overlay — not a list. Sub-categories have `(name . LIST-OF-ITEMS)`. The check `(listp (cdr item))` distinguishes lists from atoms. NOTE: a marker IS NOT a list, so `(listp (marker))` returns nil. CORRECT discrimination.
- BLOCKING: The `cond` clauses are ordered: subcategory check first, then leaf check. But `(and (consp item) (listp (cdr item)))` — in Elisp, every proper list (including nil) satisfies `listp`. A leaf entry `(name . 42)` has `(listp 42)` = nil — goes to second clause. A leaf entry `(name . MARKER)` has `(listp MARKER)` = nil — goes to second clause. A subcategory `(name ITEM1 ITEM2)` has `cdr` = `(ITEM1 ITEM2)`, so `(listp (cdr item))` = t — goes to first clause. CORRECT.
- The `(line-number-at-pos pos)` call inside the lambda — this is called while `with-current-buffer buf` is active (the lambda is called from within the `with-current-buffer` context since `emacs-mcp--flatten-imenu` is called inside it). `line-number-at-pos` works on the current buffer. If `pos` is from a marker in the same buffer, this is correct. If `pos` is from a marker in a different buffer (which can happen if imenu was rebuilt between calls), there is a potential for stale data. NOTE.

### 5. `emacs-mcp--tool-xref-find-references` — `xref-matches-in-files` usage

- `xref-matches-in-files` is an Emacs 28+ function. Since the package requires Emacs 29.1, this is safe. CORRECT.
- `(project-files (project-current t))` — `project-current` with `t` signals an error if no project is found (instead of returning nil). If the tool is called outside a project context, this will crash with an unguarded error. The task spec says results are "scoped to project-dir where possible" but `project-current t` errors unconditionally when no project is found. BLOCKING — should either use `nil` (return nil if no project) and handle it, or use the session's project-dir instead of calling `project-current` at all.
- The `file` parameter is optional — if provided, `find-file-noselect` opens it to establish buffer context. But `xref-matches-in-files` does not use buffer context; it searches files directly. The `find-file-noselect` call may have been intended to set the `xref-backend` context, but `xref-matches-in-files` uses grep-style search, not the active xref backend. The `find-file-noselect` call is therefore ineffective for its apparent purpose. WARNING.
- `(xref-match-item-location xref)` and `(xref-match-item-summary xref)` — `xref-match-item` is a specific subtype of `xref-item`. `xref-matches-in-files` returns `xref-match-item` objects, so these accessors are correct. CORRECT.

### 6. `emacs-mcp--tool-xref-find-apropos` — backend and scoping

- `(xref-find-backend)` — returns the current xref backend based on `major-mode`. In a batch/background context with no specific buffer, this may return `etags` or a default backend unrelated to the session's project. WARNING — the backend is not anchored to the project directory.
- `xref-backend-apropos` is a generic function. Its behavior depends on the backend. For `etags`, it requires a TAGS file. For `eglot`/`lsp`, it queries the language server. In a non-interactive context (no LSP, no TAGS), it may return nil or error. The nil case is handled ("No symbols found."). The error case is NOT caught — any error from `xref-backend-apropos` propagates uncaught. WARNING.
- The `xref-item-location` accessor is used (not `xref-match-item-location`) — `xref-find-apropos` returns `xref-item` objects, not `xref-match-item` objects, so this is correct. CORRECT.
- No path authorization check — the task spec does not require one for apropos (since there is no file parameter). The tool takes a pattern only. CORRECT.

### 7. `emacs-mcp--tool-treesit-info` — treesit availability check

- `(treesit-parser-list)` is called without checking if `treesit` is available. On Emacs 29.1+ built without tree-sitter support, `treesit-parser-list` is `fboundp` but signals `treesit-error` when called (Emacs is not compiled with treesit). The `declare-function` for `treesit-parser-list` allows byte-compilation. At runtime, calling `treesit-parser-list` on an Emacs without treesit would signal an error — but this is unguarded. BLOCKING — should check `(featurep 'treesit)` before calling any treesit function.
- When `(treesit-parser-list)` returns nil (no parsers for the buffer's mode), the error message is `"No tree-sitter parser for %s"` with `(file-name-extension file)`. This is reasonable. But `file-name-extension` returns nil if the file has no extension (e.g., `Makefile`). `(error "..." nil)` would produce `"No tree-sitter parser for nil"` — misleading. NOTE.
- `(treesit-node-at pos)` — if `pos` is beyond the buffer end (e.g., due to line > actual line count), `forward-line` stops at the end without error, and `treesit-node-at` gets the last node. This is silent and may return unexpected results. NOTE.
- The top-level info path (no line param): `(dotimes (i (min (treesit-node-child-count root) 20))` — limits to first 20 children. This is a reasonable cap to avoid huge output. CORRECT.

### 8. `emacs-mcp--tool-execute-elisp` — security and behavior

- `(emacs-mcp--maybe-confirm "execute-elisp" args t)` — the third argument `t` means "requires confirmation." This correctly calls `emacs-mcp-confirm-function`. CORRECT per spec.
- `(error "User denied execution.")` when confirmation is denied. The task spec says denied returns "User denied execution." but `error` signals an Emacs error condition, not returns a string. The test `emacs-mcp-test-builtin-execute-elisp-confirm-deny` uses `should-error`, which catches the signaled error. The tool-wrapping layer (`emacs-mcp--wrap-tool-result`) should catch this error and return it as a `isError: true` result. Whether the actual string "User denied execution." ends up in the response depends on how `emacs-mcp--wrap-tool-result` formats the error message. CORRECT per spec's intent — "User denied execution." is the error message.
- `(eval (read expr) t)` — `t` as second arg to `eval` means "evaluate in the lexical environment." Wait: the second argument to `eval` is the ENVIRONMENT (an alist in interpreted mode) or `t` to use the lexical environment. In Emacs 29, `(eval FORM t)` evaluates FORM with lexical binding enabled. This is safe and correct. CORRECT.
- No timeout or error catching on `eval` — a malicious or buggy expression that runs forever or signals an error. Infinite loops hang Emacs. Errors propagate uncaught and would be returned as tool errors via the wrapping layer. The hanging case is a security concern but is mentioned in the spec as user-controlled. NOTE.
- The `execute-elisp` tool is in the file even when `emacs-mcp-enable-tool-execute-elisp` is nil — the FUNCTION is always defined. Only the REGISTRATION is gated. If a user somehow calls `emacs-mcp--tool-execute-elisp` directly, they bypass the enable check. This is acceptable since the function is internal. NOTE.

### 9. Test coverage for Task 12 scope

- `get-diagnostics` — NO tests for the actual diagnostic output. The test file has zero tests for `emacs-mcp--tool-get-diagnostics` or `emacs-mcp--collect-diagnostics`. BLOCKING gap — the task verification criteria require testing flymake path and no-backend path.
- `imenu-symbols` — NO tests for `emacs-mcp--tool-imenu-symbols` or `emacs-mcp--flatten-imenu`. BLOCKING gap.
- `xref-find-references` — NO tests. BLOCKING gap.
- `xref-find-apropos` — NO tests. BLOCKING gap.
- `treesit-info` — NO tests. Treesit may be hard to unit test without a supported parser, but at minimum an error-when-no-parser test is feasible. WARNING gap.
- `execute-elisp` — TWO tests present: deny and allow. These ARE present and correct. CORRECT.
- `emacs-mcp-test-builtin-all-defcustoms-exist` — PRESENT, covers all 10 defcustoms. CORRECT.
- `emacs-mcp-test-builtin-execute-elisp-default-nil` — PRESENT. CORRECT.
- The registration tests (`emacs-mcp-test-builtin-register-all`) do NOT check registration of get-diagnostics, imenu-symbols, xref-find-references, xref-find-apropos, or treesit-info. WARNING.

### 10. `(require 'flymake)` hard-require

- `flymake` is a built-in Emacs package (included in Emacs 26.1+, certainly in 29.1+). Hard-requiring it at the top is correct and will not fail on the supported Emacs versions. CORRECT.
- However, this means `flymake` is loaded on every require of `emacs-mcp-tools-builtin` even if `get-diagnostics` is never called. For a package that aims for minimal side effects, lazy-loading would be better. NOTE.

### 11. Checklist: `emacs-mcp--flatten-imenu` — `*Index*` entry in imenu

- imenu index may contain a special `("*Index*" . POSITION)` or similar meta-entries. The flatten function does not filter these. Depending on the mode, spurious entries may appear. Minor robustness gap. NOTE.

### 12. `xref-find-references` vs task spec

- Task spec says: "`xref-find-references` — Find references via xref backend (FR-3.1)." But the implementation uses `xref-matches-in-files` which is a grep-based search, NOT the xref backend's `xref-backend-references`. The spec implies using the xref backend (which may be eglot/lsp for LSP-driven navigation), but the implementation does a literal text search across project files. This is a semantic mismatch — for LSP projects, text search misses semantic references (e.g., same-named symbol in different scopes). WARNING — behavior diverges from spec intent for LSP-backed projects.

List issues with severity: BLOCKING / WARNING / NOTE.
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
