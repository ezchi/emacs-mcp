# Code Review: Task 1 — Project Scaffolding & Core Definitions

You are a strict code reviewer. Review the implementation of Task 1.

## Task Requirements

Create directory structure, stub .el files with AGPL-3.0 headers, and `emacs-mcp.el` with:
- `defgroup emacs-mcp` (under `tools` and `comm`)
- 6 defcustoms: `emacs-mcp-server-port` (default 38840), `emacs-mcp-project-directory` (nil), `emacs-mcp-lockfile-directory` ("~/.emacs-mcp"), `emacs-mcp-extra-lockfile-directories` (nil), `emacs-mcp-session-timeout` (1800), `emacs-mcp-deferred-timeout` (300)
- 4 hook variables
- NO interactive commands, NO require of sub-modules

## Coding Standards (from Constitution)

- Public symbols: `emacs-mcp-` prefix. Internal: `emacs-mcp--` prefix.
- Every public function/variable/macro needs a docstring passing checkdoc.
- Must byte-compile cleanly with zero warnings.
- lexical-binding: t in all files.
- 80 columns soft limit.
- Package-Requires: only `((emacs "29.1"))`.

## Files to Review

Read ALL of the following files and review them:

1. `emacs-mcp.el` — Main file with defgroup/defcustoms/hooks
2. `emacs-mcp-jsonrpc.el` — Stub
3. `emacs-mcp-session.el` — Stub
4. `emacs-mcp-tools.el` — Stub
5. `emacs-mcp-confirm.el` — Stub
6. `emacs-mcp-lockfile.el` — Stub
7. `emacs-mcp-http.el` — Stub
8. `emacs-mcp-protocol.el` — Stub
9. `emacs-mcp-transport.el` — Stub
10. `emacs-mcp-tools-builtin.el` — Stub

## Review Checklist

1. **Correctness**: Are all 6 defcustoms present with correct types, defaults, and :safe predicates?
2. **Code quality**: Clean, readable, well-structured?
3. **Constitution compliance**: Naming, docstrings, lexical-binding, AGPL headers?
4. **Security**: No issues expected for stubs.
5. **Error handling**: N/A for stubs.
6. **Test coverage**: N/A (no testable logic).
7. **Performance**: N/A.
8. **No scope creep**: No interactive commands or sub-module requires?

List issues with severity: BLOCKING / WARNING / NOTE.
End with: `VERDICT: APPROVE` or `VERDICT: REVISE`
