# Validation Report

**Spec ID:** 002-per-session-project-directory
**Date:** 2026-04-29

## Summary

- PASS: 16 | FAIL: 0 | DEFERRED: 0

## Test Execution

| Suite | Command | Exit Code | Result |
|-------|---------|-----------|--------|
| All ERT suites | `emacs --batch ... -f ert-run-tests-batch-and-exit` | 0 | 150/150 pass |
| Byte-compile | `emacs --batch ... -f batch-byte-compile` | 0 | 0 warnings |

Full test output: `artifacts/validation/iter2-test-output.txt` (includes ERT, byte-compile, and checkdoc output)

## Results

### Functional Requirements

| Req | Verdict | Evidence |
|-----|---------|----------|
| FR-1 | PASS | `emacs-mcp--handle-initialize` extracts `projectDir` from params, validates via `emacs-mcp--validate-project-dir`, stores in session. Tests: `emacs-mcp-test-protocol-init-different-project-dirs`, `emacs-mcp-test-protocol-init-invalid-project-dir`, `emacs-mcp-test-protocol-init-no-project-dir`. |
| FR-2 | PASS | `emacs-mcp--handle-set-project-dir` registered as `emacs-mcp/setProjectDir`. Checks request-p, session ready, validates, updates slot. Tests: `emacs-mcp-test-protocol-set-project-dir`, `emacs-mcp-test-protocol-set-project-dir-not-ready`, `emacs-mcp-test-protocol-set-project-dir-invalid`, `emacs-mcp-test-protocol-set-project-dir-notification`. |
| FR-3 | PASS | `emacs-mcp--validate-project-dir` implements 5-step validation: string check → absolute → canonicalize → directory-exists → allowlist. Tests: `emacs-mcp-test-validate-project-dir-*` (8 tests). |
| FR-4 | PASS | `emacs-mcp-allowed-project-directories` defcustom exists with type `(choice (const nil) (repeat directory))`, default nil, safe predicate, group `emacs-mcp`. Tests: `emacs-mcp-test-validate-project-dir-allowlist-pass`, `emacs-mcp-test-validate-project-dir-allowlist-reject`. |
| FR-5 | PASS | `emacs-mcp-project-dir-changed-hook` defvar exists. Fired with (session-id, old-dir, new-dir) only when dir actually changes. Test: `emacs-mcp-test-protocol-set-project-dir-hook`. |

### Acceptance Criteria

| AC | Verdict | Evidence |
|----|---------|----------|
| AC-1 | PASS | Test `emacs-mcp-test-protocol-init-different-project-dirs`: two sessions with `/tmp` and `/var` have different `project-dir` values. |
| AC-2 | PASS | Test `emacs-mcp-test-protocol-set-project-dir`: confirms session slot changes after `setProjectDir`. Test `emacs-mcp-test-protocol-set-project-dir-path-auth`: verifies `file-in-directory-p` against session's updated project-dir (the same check `emacs-mcp--check-path-authorization` uses internally). Test `emacs-mcp-test-protocol-deferred-project-dir`: verifies `emacs-mcp--current-project-dir` is bound to dispatch-time project-dir during handler execution. |
| AC-3 | PASS | Test `emacs-mcp-test-protocol-init-invalid-project-dir`: non-existent dir returns -32602 error, no session created (session count unchanged). |
| AC-4 | PASS | Test `emacs-mcp-test-validate-project-dir-allowlist-reject`: path outside allowlist errors with "not in allowed list" message; message does NOT contain allowlist path. |
| AC-5 | PASS | Test `emacs-mcp-test-protocol-init-no-project-dir`: session gets global fallback `/test/project`. |
| AC-6 | PASS | Test `emacs-mcp-test-protocol-set-project-dir-hook`: hook fires on actual change; verifies all 3 args (session-id matches, old-dir contains `/tmp`, new-dir contains `/var`). Does NOT fire on same-directory call. |
| AC-7 | PASS | Byte-compile: 0 warnings. Checkdoc: all new symbols pass. |

### Non-Functional Requirements

| NFR | Verdict | Evidence |
|-----|---------|----------|
| NFR-1 | PASS | Test `emacs-mcp-test-protocol-init-no-project-dir` proves backward compatibility. Existing 101 tests (pre-feature) all pass. |
| NFR-2 | PASS | `defcustom` and `defvar` are pure declarations — no network calls or process creation. |
| NFR-3 | PASS | All public symbols: `emacs-mcp-allowed-project-directories`, `emacs-mcp-project-dir-changed-hook`. All internal: `emacs-mcp--validate-project-dir`, `emacs-mcp--handle-set-project-dir`, `emacs-mcp--current-project-dir`. Method: `emacs-mcp/setProjectDir`. |
| NFR-4 | PASS | Byte-compile and checkdoc verified (see AC-7). |

## Security Review

- **Path traversal**: `emacs-mcp--validate-project-dir` canonicalizes paths before comparison, preventing `..` traversal.
- **Allowlist bypass**: Both client path and allowlist entries are canonicalized via `file-truename` before `file-in-directory-p`.
- **Information leakage**: Allowlist rejection message is generic ("not in allowed list") — does not enumerate allowed paths. Test verifies this.
- **Notification mutation**: `emacs-mcp--handle-set-project-dir` guards against notification path with `emacs-mcp--jsonrpc-request-p` check. Test verifies notifications don't mutate state.

## Performance Review

- No loops over unbounded data. Allowlist iteration is bounded by user config.
- `file-truename` called once per validation (+ once per allowlist entry). Acceptable for localhost-only server.
- No new timers, no new processes, no new network calls.
