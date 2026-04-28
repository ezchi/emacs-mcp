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
