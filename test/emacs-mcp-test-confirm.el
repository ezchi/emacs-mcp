;;; emacs-mcp-test-confirm.el --- Tests for emacs-mcp-confirm -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the confirmation policy.

;;; Code:

(require 'ert)
(require 'emacs-mcp-confirm)

(ert-deftest emacs-mcp-test-confirm-always-allows ()
  "Setting confirm-function to `always' bypasses all prompts."
  (let ((emacs-mcp-confirm-function #'always))
    (should (emacs-mcp--maybe-confirm "test-tool" '(("a" . 1)) t))))

(ert-deftest emacs-mcp-test-confirm-ignore-denies ()
  "Setting confirm-function to `ignore' denies all."
  (let ((emacs-mcp-confirm-function #'ignore))
    (should-not (emacs-mcp--maybe-confirm "test-tool" '(("a" . 1)) t))))

(ert-deftest emacs-mcp-test-confirm-non-confirm-tool ()
  "Non-confirm tools proceed without calling confirm-function."
  (let ((called nil)
        (emacs-mcp-confirm-function
         (lambda (_name _args) (setq called t) nil)))
    (should (emacs-mcp--maybe-confirm "safe-tool" nil nil))
    (should-not called)))

(ert-deftest emacs-mcp-test-confirm-receives-tool-name ()
  "Confirm function receives the tool name."
  (let* ((received-name nil)
         (emacs-mcp-confirm-function
          (lambda (name _args)
            (setq received-name name)
            t)))
    (emacs-mcp--maybe-confirm "my-tool" '(("x" . 1)) t)
    (should (equal received-name "my-tool"))))

(ert-deftest emacs-mcp-test-confirm-receives-args ()
  "Confirm function receives the arguments."
  (let* ((received-args nil)
         (emacs-mcp-confirm-function
          (lambda (_name args)
            (setq received-args args)
            t)))
    (emacs-mcp--maybe-confirm "tool" '(("key" . "val")) t)
    (should (equal received-args '(("key" . "val"))))))

(provide 'emacs-mcp-test-confirm)
;;; emacs-mcp-test-confirm.el ends here
