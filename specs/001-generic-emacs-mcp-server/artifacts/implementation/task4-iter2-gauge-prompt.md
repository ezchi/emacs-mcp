# Gauge Code Review — Task 4: Confirmation Policy (Iteration 2)

You are a strict code reviewer. This is iteration 2 after fixing issues from iteration 1.

## Previous Issues (Iteration 1)

1. BLOCKING: `emacs-mcp-confirm-function` defcustom was missing `:safe` declaration

## Fixes Applied

1. Added `:safe #'functionp` to `emacs-mcp-confirm-function` defcustom — allows file-local variable settings to be accepted safely when the value satisfies `functionp`

## Task Requirements

Implement `emacs-mcp-confirm.el`: Confirmation policy that gates destructive or sensitive tool calls.

**Required functions/variables**:
- `emacs-mcp-default-confirm` — Default confirmation function; prompts user with `y-or-n-p`; receives TOOL-NAME (string) and ARGS (alist)
- `emacs-mcp-confirm-function` — `defcustom` of type `function`; must include `:safe` declaration; defaults to `#'emacs-mcp-default-confirm`
- `emacs-mcp--maybe-confirm` — Helper that calls `emacs-mcp-confirm-function` when `confirm-p` is non-nil; returns t unconditionally when `confirm-p` is nil

## Coding Standards (from Constitution)

- Style: Follow Emacs Lisp conventions, `checkdoc` compliant
- Naming: Public symbols `emacs-mcp-`, internal `emacs-mcp--`
- Docstrings: Every public function/variable must have a docstring passing `checkdoc`
- Byte-compilation: Clean with no warnings
- Line length: 80 columns soft limit

## Full File: emacs-mcp-confirm.el

```elisp
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
```

## Full File: test/emacs-mcp-test-confirm.el

```elisp
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
```

## Review Focus

1. Verify the blocking issue from iteration 1 is resolved: `:safe #'functionp` is present on `emacs-mcp-confirm-function`
2. Verify `:safe` value is correct — `#'functionp` is the appropriate predicate for a `function`-type defcustom
3. Verify `:type 'function` and `:group 'emacs-mcp` are present and correct
4. Check `emacs-mcp-default-confirm` docstring and argument names are `checkdoc` compliant
5. Check `emacs-mcp--maybe-confirm` logic: returns `t` when `confirm-p` is nil (no confirmation needed), calls `emacs-mcp-confirm-function` otherwise
6. Test coverage: do the 5 tests cover all meaningful paths (allow, deny, no-confirm bypass, tool-name passed, args passed)?
7. Any remaining issues?

List issues with severity: BLOCKING / WARNING / NOTE. End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
