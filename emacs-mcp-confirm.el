;;; emacs-mcp-confirm.el --- Confirmation policy for emacs-mcp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; License: AGPL-3.0-or-later
;; See the file LICENSE for the full license text.

;;; Commentary:

;; This library implements the confirmation policy that gates
;; destructive or sensitive tool calls in the emacs-mcp package.

;;; Code:

(require 'emacs-mcp)

;;;; Confirmation function

(defun emacs-mcp-default-confirm (tool-name args)
  "Prompt the user to confirm execution of TOOL-NAME with ARGS.
TOOL-NAME is a string.  ARGS is an alist of argument names to
values.  Returns non-nil if the user approves."
  (let ((summary (mapconcat
                  (lambda (pair)
                    (format "%s=%S" (car pair) (cdr pair)))
                  args ", ")))
    (y-or-n-p (format "MCP: execute %s (%s)? " tool-name summary))))

(defcustom emacs-mcp-confirm-function #'emacs-mcp-default-confirm
  "Function called before executing tools that require confirmation.
Receives TOOL-NAME (string) and ARGS (alist).  Returns non-nil
to allow execution, nil to deny."
  :type 'function
  :safe #'functionp
  :group 'emacs-mcp)

;;;; Confirmation helper

(defun emacs-mcp--maybe-confirm (tool-name args confirm-p)
  "Check whether TOOL-NAME with ARGS needs confirmation.
If CONFIRM-P is non-nil, call `emacs-mcp-confirm-function'.
Returns non-nil to proceed, nil to deny."
  (if confirm-p
      (funcall emacs-mcp-confirm-function tool-name args)
    t))

(provide 'emacs-mcp-confirm)
;;; emacs-mcp-confirm.el ends here
