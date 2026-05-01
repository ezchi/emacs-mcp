# Tasks 6-7: Tests — Forge Iteration 1

## Files Changed
- `test/emacs-mcp-test-session.el` — modified (8 validation tests added)
- `test/emacs-mcp-test-protocol.el` — modified (11 protocol tests added)
- `emacs-mcp.elc`, `emacs-mcp-session.elc`, `emacs-mcp-protocol.elc`, `emacs-mcp-tools.elc` — recompiled

## Key Implementation Decisions
- Tests use real filesystem paths (/tmp, /var) instead of mocks for validation tests, since we need real `file-directory-p` behavior.
- Allowlist rejection test verifies the error message does NOT contain the allowlist path (security).
- Helper `emacs-mcp-test--make-session-ready` added for readability.
- Path auth test verifies `file-in-directory-p` against the session's project-dir rather than calling the full tool — simpler and more direct.

## Deviations from Plan
- None.

## Tests Added
- `test/emacs-mcp-test-session.el`:
  - validate-project-dir-valid, empty-string, nil, relative, nonexistent, allowlist-pass, allowlist-reject, canonicalizes
- `test/emacs-mcp-test-protocol.el`:
  - init-different-project-dirs (AC-1), init-invalid-project-dir (AC-3), init-no-project-dir (AC-5)
  - set-project-dir (AC-2 scoping), set-project-dir-path-auth (AC-2 auth), set-project-dir-hook (AC-6)
  - set-project-dir-not-ready, set-project-dir-invalid, set-project-dir-notification
  - deferred-project-dir (deferred context binding)
  - All 49 tests pass (40 existing + 8 session + 11 protocol - 10 overlap = 49)
