# Gauge Review: Task 11 — Built-in Tools: Buffer & File Operations (Iteration 1)

## Summary

The implementation has the defcustoms correct and the basic tools structurally present, but contains multiple BLOCKING issues: nil-session crashes, a broken open-file selection, incomplete tests, and a missing registration call that would make the tools invisible in production.

---

## BLOCKING Issues

### 1. `emacs-mcp--register-builtin-tools` Never Called in Production

`emacs-mcp--register-builtin-tools` is defined but never called from any non-test code. `emacs-mcp-tools-builtin.el` is not required by the entry point. In production, `tools/list` will never include the built-in tools — they are invisible to any MCP client. The function must be called from `emacs-mcp-start` or wired into the server startup path in `emacs-mcp.el`.

### 2. `project-info` Crashes on Missing Session

```elisp
(let* ((session (emacs-mcp--session-get emacs-mcp--current-session-id))
       (project-dir (emacs-mcp-session-project-dir session))  ; crashes if session is nil
```

If the session has expired or `emacs-mcp--current-session-id` is stale, `session` is nil and `(emacs-mcp-session-project-dir nil)` signals `wrong-type-argument`. There is no nil guard. The tool should signal a clean tool execution error ("No active session") instead of crashing.

### 3. `list-buffers` Crashes on Missing Session

Same nil-session pattern as `project-info`. `(emacs-mcp-session-project-dir session)` is called unconditionally on the session returned by `emacs-mcp--session-get`. BLOCKING for the same reasons.

### 4. `open-file` Selection Logic Bug and Missing `text` Parameter

FR-3.7 requires `text` (string, optional) as a parameter for text search/selection. The schema and handler omit `text` entirely.

Additionally, the region selection is set inside `with-current-buffer buf` which is NOT the selected buffer. `push-mark` in a non-selected buffer has undefined behavior for the user-visible region. Setting point and mark in `with-current-buffer` does not make the region visible in the displayed window.

### 5. Test Coverage Does Not Satisfy Verification Criteria

The test file fails to cover:
- `tools/list` integration (all 10 default-enabled tools registered)
- Disabling any non-execute-elisp tool and verifying it is absent from registry
- `list-buffers` excluding non-project buffers (only presence is tested, not exclusion)
- `get-buffer-content` path authorization rejection (no `should-error` test for outside path)
- `project-info` `fileCount` and `activeBuffer` fields
- `open-file` with `startLine`/`endLine` params

---

## WARNING Issues

### 6. `emacs-mcp--check-path-authorization` — Nil Path Crashes

`(expand-file-name path)` is called before any nil check. If any tool passes `nil` as the path (e.g., optional arg not provided by caller), this signals `wrong-type-argument: stringp, nil` instead of the expected authorization error. Callers must guard before calling this function, but the function itself should also validate.

### 7. `project-info` File Count Uses `follow-symlinks`

`(directory-files-recursively project-dir "." nil nil t)` has `follow-symlinks` = `t` (the fifth argument). A symlink cycle or a symlink pointing outside the project can make the file count escape the project boundary or hang. Should use `nil` for symlink following.

### 8. `get-diagnostics` Does Not Authorize Its `file` Parameter

`get-diagnostics` accepts a `file` parameter (Task 12 scope) but does not call `emacs-mcp--check-path-authorization`. FR-4.3 requires every built-in `file`/`path` parameter to be checked. An already-open outside-project buffer can leak its diagnostics to any session.

### 9. Unused `emacs-mcp--project-dir` Binding in Test Macro

The test macro binds `emacs-mcp--project-dir` but this variable does not exist in `emacs-mcp-tools-builtin.el`. The binding is misleading — the project-dir is set via the session, not this variable. Future test authors may be confused about the actual mechanism.

---

## NOTE Issues

### 10. `project-info` — `activeBuffer` May Leak Out-of-Project Path

`(window-buffer (selected-window))` returns whatever buffer is currently selected. If that buffer is visiting a file outside the session's project directory, the path is returned as `activeBuffer`. No project-dir check is applied to the active buffer. The spec says "path of the buffer visible in the selected window, or null" without restriction — but this can leak out-of-project paths.

### 11. `register-all` Test Only Checks 4 of 10 Tools

`emacs-mcp-test-builtin-register-all` verifies registration for `project-info`, `list-buffers`, `open-file`, `get-buffer-content` only. The other 6 default-enabled tools (get-diagnostics, imenu-symbols, xref-find-references, xref-find-apropos, treesit-info) are not checked.

---

## Required Changes

1. Wire `emacs-mcp--register-builtin-tools` into server startup from `emacs-mcp.el`
2. Add nil guard for `session` in `project-info` and `list-buffers`
3. Fix `open-file`: add `text` parameter to schema, fix region selection for the displayed window
4. Add `emacs-mcp--check-path-authorization` for the `file` param in `get-diagnostics`
5. Add nil check in `emacs-mcp--check-path-authorization` before calling `expand-file-name`
6. Disable symlink following in `directory-files-recursively` (use `nil` not `t`)
7. Expand test coverage to meet all Task 11 verification criteria

---

VERDICT: REVISE
