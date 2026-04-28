# Gauge Code Review — Task 4: Confirmation Policy (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Implement `emacs-mcp-confirm.el`: The confirmation mechanism for dangerous tools. Small module — defcustom, default confirm function, and a helper that checks whether a tool needs confirmation.

**Functions to implement**:
- `emacs-mcp-confirm-function` — defcustom, default `#'emacs-mcp-default-confirm`
- `emacs-mcp-default-confirm` — `y-or-n-p` prompt with tool name and args summary
- `emacs-mcp--maybe-confirm` — If tool has `:confirm`, call `emacs-mcp-confirm-function`; return t to proceed, nil to deny

**Verification criteria**:
- Default confirm function prompts with tool name
- Setting `emacs-mcp-confirm-function` to `#'always` bypasses prompts
- Setting to `#'ignore` denies all
- `emacs-mcp--maybe-confirm` returns t for non-confirm tools without calling function
- File byte-compiles clean; all tests pass

## Coding Standards (from Constitution)

- Style: Follow Emacs Lisp conventions, `checkdoc` compliant
- Naming: Public symbols `emacs-mcp-`, internal `emacs-mcp--`
- Docstrings: Every public function/variable must have a docstring passing `checkdoc`
- Byte-compilation: Clean with no warnings
- Line length: 80 columns soft limit
- Custom variables: Use `defcustom` with appropriate `:type`, `:group`, and `:safe` declarations

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

## Test Results

All 5 tests pass. Byte-compilation clean (no warnings).

## Review Checklist

1. **Correctness**: Does the code implement all required functions? Does `emacs-mcp-default-confirm` correctly format the prompt? Does `emacs-mcp--maybe-confirm` correctly gate on `confirm-p`?
2. **Code quality**: Clean, readable, well-structured? Appropriate module size for the scope?
3. **Constitution compliance**: Naming conventions (`emacs-mcp-` for public, `emacs-mcp--` for internal), docstrings, byte-compile clean, 80-col soft limit?
4. **Security**: Is the confirmation gate robust? Can it be bypassed accidentally? Does the defcustom allow arbitrary function injection (intentional — user control principle)?
5. **Error handling**: What happens if `emacs-mcp-confirm-function` signals an error? What if ARGS is nil? What if TOOL-NAME is nil?
6. **Test coverage**: All key paths covered? `always` bypass, `ignore` deny, non-confirm passthrough, tool-name forwarding, args forwarding? Missing: error propagation from confirm function, nil args edge case, default confirm function behavior (y-or-n-p is hard to test non-interactively)?
7. **Performance**: Any concerns? (Module is trivial, unlikely)
8. **Scope creep**: Does the code stay within task requirements? No premature tool registry integration?

List issues with severity: BLOCKING / WARNING / NOTE
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
