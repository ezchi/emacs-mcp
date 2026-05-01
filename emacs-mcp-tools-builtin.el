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
         (project-dir (or (and session
                               (emacs-mcp-session-project-dir
                                session))
                          (error "No active session")))
         (active-buf (let ((buf (window-buffer
                                 (selected-window))))
                       (when (buffer-file-name buf)
                         (buffer-file-name buf))))
         (file-count (length
                      (directory-files-recursively
                       project-dir "\\`[^.]"))))
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
         (project-dir (or (and session
                               (emacs-mcp-session-project-dir
                                session))
                          (error "No active session")))
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
        (progn
          (emacs-mcp--check-path-authorization file)
          (let ((buf (get-file-buffer file)))
            (when buf
              (setq diagnostics
                    (emacs-mcp--collect-diagnostics buf)))))
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
    (let ((xrefs (condition-case nil
                     (xref-backend-references
                      (xref-find-backend) identifier)
                   (error nil))))
      (if (null xrefs)
          "No references found."
        (mapconcat
         (lambda (xref)
           (let ((loc (xref-item-location xref)))
             (if (cl-typep loc 'xref-file-location)
                 (format "%s:%d: %s"
                         (xref-file-location-file loc)
                         (xref-file-location-line loc)
                         (xref-item-summary xref))
               (format "?: %s" (xref-item-summary xref)))))
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
  (unless (featurep 'treesit)
    (error "Tree-sitter not available in this Emacs build"))
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
  "Evaluate an Emacs Lisp expression from ARGS.
Confirmation is handled by the tool dispatch (:confirm t)."
  (let ((expr (cdr (assoc "expression" args))))
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
