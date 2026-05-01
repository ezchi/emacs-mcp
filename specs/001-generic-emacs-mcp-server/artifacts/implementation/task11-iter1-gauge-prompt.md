# Gauge Code Review — Task 11: Built-in Tools — Buffer & File Operations (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Implement the shared path-authorization helper, tool enable/disable defcustoms for ALL 10 tools, and the buffer/file built-in tools in `emacs-mcp-tools-builtin.el`. Also implement corresponding ERT tests in `test/emacs-mcp-test-tools-builtin.el`.

**Shared helpers to implement**:
- `emacs-mcp--check-path-authorization` — Verify path is within session's project-dir via `file-in-directory-p`. Reads project-dir from session via `emacs-mcp--current-session-id`. Signals error "Path outside project directory: <path>" on failure.
- `emacs-mcp-enable-tool-<name>` — Defcustoms for ALL 10 tools (all default `t` except `execute-elisp` which defaults to `nil`)

**Tools to implement** (Task 11 scope):
1. `project-info` — Return project-dir, active buffer, file count (FR-3.3). Uses session's project-dir, NOT global `project-current`.
2. `list-buffers` — Return project buffers as JSON array (FR-3.9). Filters by session's project-dir (FR-4.4).
3. `open-file` — Open file with optional line/selection (FR-3.7). Path authorization check.
4. `get-buffer-content` — Return buffer text with optional range (FR-3.8). Path authorization check.

**Verification criteria** (Task 11 focus):
- Path authorization rejects paths outside project-dir with tool execution error
- Path authorization accepts paths inside project-dir
- `project-info` returns valid JSON with projectDir matching session's project-dir
- `list-buffers` returns only buffers in session's project-dir
- `open-file` opens file and returns "FILE_OPENED"; rejects outside paths
- `get-buffer-content` returns correct text/range; rejects outside paths
- All 10 enable defcustoms exist with correct defaults
- Disabled tool not in registry (when checked via tools/list)
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

### 1. `emacs-mcp--check-path-authorization` — nil session handling

- When `emacs-mcp--current-session-id` is nil or the session has expired, `emacs-mcp--session-get` returns nil. The `(when session ...)` guard means `project-dir` becomes nil. The authorization check `(and project-dir (file-in-directory-p ...))` short-circuits to nil, and `unless` fires — the path is rejected with an error. This is the correct safe-fail behavior. However, the error message says "Path outside project directory" when the real issue is "no active session." This is misleading. WARNING.
- `(expand-file-name path)` without a base — uses `default-directory`. If `path` is already absolute, this is fine. If `path` is relative and `default-directory` is outside the project, the expanded path will also be outside, and the check will correctly reject it. Correct.
- There is no check that `path` is non-nil before calling `expand-file-name`. If a caller passes a nil path (e.g., optional "file" arg not provided), `(expand-file-name nil)` signals a `wrong-type-argument` error instead of the expected authorization error. BLOCKING — any tool that calls this with an optional arg that may be absent will crash with an unclear error rather than a clean validation message. callers should guard before calling this.

### 2. `emacs-mcp--tool-project-info` — nil session crash

- `(emacs-mcp--session-get emacs-mcp--current-session-id)` — if no session exists, returns nil. Then `(emacs-mcp-session-project-dir session)` will signal `wrong-type-argument` because it's called with nil. There is no nil guard here. BLOCKING — the tool crashes instead of returning an error when called without a valid session.
- `(directory-files-recursively project-dir "." nil nil t)` — the fifth argument `t` is `follow-symlinks`. The fourth argument `nil` is the predicate for including directories. The regex `"."` matches everything (including "." and ".." in some implementations). This could be slow on large projects. Also, `directory-files-recursively` with `"."` regex is unusual — the spec says "file count" but doesn't specify whether to count only files, not directories. The regex `"."` matches directory names too when the function recurses. WARNING — may over-count or be unexpectedly slow.
- `(window-buffer (selected-window))` — `selected-window` in a batch/background context (no interactive frame) may not return a meaningful window. `window-buffer` of a minibuffer window returns the minibuffer buffer, not a file buffer. The `(when (buffer-file-name buf) ...)` guard handles this safely. NOTE.

### 3. `emacs-mcp--tool-list-buffers` — nil session crash

- Same issue as project-info: no nil guard on `session` before calling `emacs-mcp-session-project-dir`. BLOCKING.
- `(buffer-local-value 'major-mode buf)` — for a buffer that has been killed between `buffer-list` and this call, `buffer-local-value` signals an error. Should use `(with-current-buffer buf (symbol-name major-mode))` inside a `condition-case` or check `(buffer-live-p buf)` first. WARNING.
- The `:false-object :false` in `json-serialize` — `modified` is set to either `t` or `:false`. The `:false-object :false` option tells `json-serialize` to serialize the keyword `:false` as JSON `false`. This is correct. Verify that `json-serialize` with a vector of alists handles the `:false` keyword. In Emacs 29+, `json-serialize` with `:false-object :false` does serialize `:false` as JSON `false`. Correct.

### 4. `emacs-mcp--tool-open-file` — selection range logic bug

- When both `start-line` and `end-line` are provided:
  1. `(goto-char (point-min))` then `(forward-line (1- start-line))` — positions point at start of `start-line`.
  2. `(push-mark (point) t t)` — sets mark at start of `start-line`.
  3. `(goto-char (point-min))` then `(forward-line end-line)` — positions point at start of line `end-line + 1` (since `forward-line N` moves N lines, landing at start of line N+1).
  4. The result: mark is at the START of `start-line`, point is at the START of line `end-line + 1`. The region covers lines `start-line` through `end-line` inclusive.
- But the mark and point are set inside `with-current-buffer buf`, which is NOT the selected buffer. `push-mark` in a non-selected buffer has undefined/unreliable behavior for the user-visible region. BLOCKING — the selection is set in a buffer that is not the current buffer for the user. Even `display-buffer` after this does not restore the selection correctly.
- `(display-buffer buf)` — this is correct for showing the buffer without switching to it (or it may switch, depending on `display-buffer-alist`). The buffer IS opened and returned. "FILE_OPENED" is always returned, even if the path authorization passes but the file does not exist — `find-file-noselect` will try to create or visit a nonexistent file. NOTE.

### 5. `emacs-mcp--tool-get-buffer-content` — range boundary behavior

- `(forward-line (1- start-line))` for `start-line = 1` gives `(forward-line 0)` — no movement, stays at `point-min`. Correct for 1-based line numbers.
- `(forward-line end-line)` — for `end-line = 2`, this moves 2 lines from `point-min`, landing at the start of line 3. The `buffer-substring-no-properties` from start-of-line-2 to start-of-line-3 gives line 2 content INCLUDING the trailing newline. This is reasonable behavior. Test `get-buffer-content-range` passes `endLine = 2` and expects `line2` present but `line1` absent — passes correctly. NOTE.
- Only requires BOTH `start-line` AND `end-line` to use range mode: `(if (and start-line end-line) ...)`. If only `start-line` is given without `end-line`, falls through to full content. This may be unexpected for callers who pass `startLine` alone expecting content from that line to EOF. The spec says "optional range" — whether partial range should be supported is unspecified. NOTE.
- The tool errors if the buffer is not already open (`get-file-buffer` returns nil). It does NOT auto-open the file. This is different from `open-file` and `imenu-symbols` which use `find-file-noselect`. The task spec says "Return buffer text" implying the buffer must already be visiting the file. This is consistent but may surprise callers. NOTE.

### 6. Enable defcustoms — completeness and correctness

- All 10 defcustoms are present: project-info, list-buffers, open-file, get-buffer-content, get-diagnostics, imenu-symbols, xref-find-references, xref-find-apropos, treesit-info, execute-elisp. CORRECT.
- All have `:type 'boolean`, `:safe #'booleanp`, `:group 'emacs-mcp`. CORRECT.
- 9 default to `t`, `execute-elisp` defaults to `nil`. CORRECT per task spec.
- Defcustom docstrings are minimal (single sentence). Pass `checkdoc` since they end with a period. CORRECT.

### 7. Tool registration — `emacs-mcp--register-builtin-tools`

- `ignore-errors` wraps `emacs-mcp-unregister-tool` — if the tool doesn't exist (first registration), `unregister-tool` signals an error that is suppressed. This is correct for idempotent re-registration.
- The `get-buffer-content` registration has params `startLine` and `endLine` without `:description` entries. All other params have at least `:name`, `:type`, `:required`. Missing `:description` is not required by the registration schema but is good practice. NOTE.
- The `open-file` param for "path" says `:description "Absolute path"` but the tool actually calls `expand-file-name` on whatever is passed — it does NOT require an absolute path. The description is misleading. NOTE.

### 8. Test macro — `emacs-mcp-test-with-builtin`

- `emacs-mcp--project-dir` binding in the macro — this variable name does not appear in `emacs-mcp-tools-builtin.el`. The macro sets `emacs-mcp--project-dir` but the actual code reads `emacs-mcp--current-session-id` and looks up the session. The session IS created with `emacs-mcp--session-create tmpdir`, and `emacs-mcp--current-session-id` is bound to `session-id`. The path authorization check calls `emacs-mcp--session-get emacs-mcp--current-session-id` to get the project-dir from the session. So the `emacs-mcp--project-dir` binding is UNUSED and misleading. WARNING — could confuse future test authors into thinking it's the mechanism for setting the project directory in tests.
- `(delete-directory tmpdir t)` in the cleanup — correct. The `t` argument enables recursive deletion. CORRECT.
- Timer cleanup: `maphash` iterates sessions and cancels timers. CORRECT.

### 9. Test coverage for Task 11 scope

- `emacs-mcp-test-builtin-path-auth-inside` — PRESENT.
- `emacs-mcp-test-builtin-path-auth-outside` — PRESENT.
- `emacs-mcp-test-builtin-register-all` — PRESENT. But only checks 4 of the tools; should also check the other 6 are registered (when enabled by default).
- `emacs-mcp-test-builtin-execute-elisp-disabled` — PRESENT (tests defcustom gate).
- `emacs-mcp-test-builtin-execute-elisp-enabled` — PRESENT (tests `:confirm` flag).
- `emacs-mcp-test-builtin-project-info` — PRESENT. Only checks `projectDir` field; does not check `fileCount` or `activeBuffer` presence. NOTE.
- `emacs-mcp-test-builtin-list-buffers` — PRESENT.
- `emacs-mcp-test-builtin-open-file` — PRESENT (happy path only).
- `emacs-mcp-test-builtin-open-file-outside` — PRESENT.
- `emacs-mcp-test-builtin-get-buffer-content` — PRESENT.
- `emacs-mcp-test-builtin-get-buffer-content-range` — PRESENT.
- Missing: test for `open-file` with `startLine`/`endLine` params.
- Missing: test for `get-buffer-content` with file that is not open (should error).
- Missing: test for `list-buffers` excluding non-project buffers.
- Missing: test for `project-info` `fileCount` field.
- Missing: test disabling any non-execute-elisp tool and checking it is absent from registry.
- Missing: test for `get-buffer-content` path authorization rejection (no `should-error` test for outside path).

### 10. Execute-elisp tests placement

- The `execute-elisp` tests are in the test file even though execute-elisp is a Task 12 tool. The tests (`emacs-mcp-test-builtin-execute-elisp-confirm-deny` and `emacs-mcp-test-builtin-execute-elisp-confirm-allow`) are present here because the file covers both tasks' shared test file. This is acceptable. NOTE.

List issues with severity: BLOCKING / WARNING / NOTE.
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
