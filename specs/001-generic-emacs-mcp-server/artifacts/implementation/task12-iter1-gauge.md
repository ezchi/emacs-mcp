# Gauge Review: Task 12 — Built-in Tools: Introspection, Diagnostics & Execute (Iteration 1)

## Summary

The implementation has serious correctness gaps across most of the six Task 12 tools. There are 8 BLOCKING issues spanning missing authorization, wrong xref API, broken flycheck soft-loading, treesit availability guard missing, double-confirmation in execute-elisp, and near-total test coverage absence.

---

## BLOCKING Issues

### 1. `get-diagnostics` Does Not Authorize Its `file` Parameter

```elisp
(defun emacs-mcp--tool-get-diagnostics (args)
  (let ((file (cdr (assoc "file" args))) ...)
    (if file
        (let ((buf (get-file-buffer file)))  ; no authorization check
```

FR-4.3 requires every built-in `file`/`path` parameter to be verified against the session's `project-dir`. `get-diagnostics` accepts `file` but never calls `emacs-mcp--check-path-authorization`. An already-open outside-project buffer can leak its diagnostics through this tool.

### 2. Flycheck Not Soft-Loaded

The task spec explicitly requires: `(require 'flycheck nil t)` to soft-load flycheck. The implementation only checks `(featurep 'flycheck)` — which is false if flycheck is installed but not yet loaded. A user with flycheck installed who has not loaded it yet gets no diagnostics from flycheck even though it is available. The guard must attempt `(require 'flycheck nil t)` before checking `(featurep 'flycheck)`.

### 3. `xref-find-references` Does Not Use the xref Backend

FR-3.1 says: "Find all references to a symbol using xref backends." The implementation uses `xref-matches-in-files`, which is a literal text search — not an xref backend call. For LSP-backed projects, `xref-matches-in-files` finds textual occurrences of the identifier string, missing semantic references and returning false positives. The correct implementation calls `xref-backend-references` on the active backend (with the file buffer context, if provided), not `xref-matches-in-files`.

### 4. `xref-find-references` Uses Global `project-current` Instead of Session Project-Dir

```elisp
(project-files (project-current t))
```

FR-4.4 requires tools to use the session's `project-dir` for scoping, NOT global Emacs state. `(project-current t)` uses whatever project Emacs detects globally, which may differ from the session's project-dir and errors if no project is detected. Must use the session's project-dir from `emacs-mcp--current-session-id`.

### 5. `xref-find-apropos` Not Scoped to Session Project

`(xref-find-backend)` returns the current global xref backend, and `xref-backend-apropos` returns results from that backend without filtering by the session's `project-dir`. Results can include symbols from outside the session project. FR-3.2 says "results are scoped to the session's project directory where possible."

### 6. `treesit-info` Does Not Guard Against Missing Tree-Sitter Support

```elisp
(defun emacs-mcp--tool-treesit-info (args)
  ...
  (unless (treesit-parser-list)
    (error "No tree-sitter parser for %s" ...))
```

`treesit-parser-list` is called without first checking `(featurep 'treesit)` or `treesit-available-p`. On an Emacs build compiled without tree-sitter support, calling `treesit-parser-list` may signal `treesit-error` or signal `void-function` — neither is the clean tool execution error the spec requires. Must check `(featurep 'treesit)` before calling any treesit function.

### 7. `execute-elisp` Confirms Twice

```elisp
;; In emacs-mcp-tools.el dispatch (~line 230):
;;   (:confirm t) triggers emacs-mcp--maybe-confirm before calling handler

;; Then inside the handler:
(unless (emacs-mcp--maybe-confirm "execute-elisp" args t)
  (error "User denied execution."))
```

The tool is registered with `:confirm t`, which causes `emacs-mcp--dispatch-tool` in `emacs-mcp-tools.el` to call `emacs-mcp--maybe-confirm` before invoking the handler. The handler then calls `emacs-mcp--maybe-confirm` again. The user is prompted twice for the same execution. The handler must NOT duplicate the confirmation — confirmation is the caller's responsibility when `:confirm t` is set.

### 8. Task 12 Test Coverage Is Absent

The test file contains zero tests for:
- `emacs-mcp--tool-get-diagnostics` (flymake path, no-backend empty array)
- `emacs-mcp--tool-imenu-symbols` (format verification, path rejection)
- `emacs-mcp--tool-xref-find-references` (results or "No references found.")
- `emacs-mcp--tool-xref-find-apropos`
- `emacs-mcp--tool-treesit-info` (error when no treesit)
- `execute-elisp` at dispatch level (disabled → "Unknown tool", denied via dispatch)

All Task 12 verification criteria from `tasks.md` are uncovered.

---

## WARNING Issues

### 9. `xref-find-apropos` Assumes `xref-file-location` Type

```elisp
(format "%s:%d: %s"
        (xref-file-location-file loc)
        (xref-file-location-line loc) ...)
```

`xref-item-location` can return location types other than `xref-file-location` (e.g., `xref-bogus-location` from some backends). Calling `xref-file-location-file` on a non-file-location will signal an error. Should wrap in `condition-case` or check location type before formatting.

### 10. `register-all` Test Does Not Check Task 12 Tools

`emacs-mcp-test-builtin-register-all` only asserts registration of 4 tools. The five default-enabled Task 12 tools (get-diagnostics, imenu-symbols, xref-find-references, xref-find-apropos, treesit-info) are not checked.

---

## Correct Elements

- `emacs-mcp--collect-diagnostics` flymake path: `flymake-diagnostics`, `flymake-diagnostic-beg`, severity mapping — structurally correct.
- `emacs-mcp--flymake-severity` pcase mapping covers `:error`, `:warning`, `:note`, and a default. Correct.
- `emacs-mcp--flatten-imenu` subcategory vs leaf discrimination logic is sound.
- `execute-elisp` — `(eval (read expr) t)` with lexical binding is correct. `prin1-to-string` of the result is correct. The `:confirm t` registration flag itself is correct; only the duplicate handler confirmation is wrong.
- All 10 defcustoms exist with correct defaults.

---

## Required Changes

1. Add `emacs-mcp--check-path-authorization` call for `file` param in `get-diagnostics`
2. Add `(require 'flycheck nil t)` before the `(featurep 'flycheck)` check
3. Replace `xref-matches-in-files` + `project-current` with proper xref backend call using session project-dir in `xref-find-references`
4. Scope `xref-find-apropos` results to session project-dir
5. Add `(featurep 'treesit)` guard before any treesit function call in `treesit-info`
6. Remove the duplicate `emacs-mcp--maybe-confirm` call from `execute-elisp` handler (let dispatch handle it via `:confirm t`)
7. Add comprehensive tests for all 6 Task 12 tools meeting verification criteria

---

VERDICT: REVISE
