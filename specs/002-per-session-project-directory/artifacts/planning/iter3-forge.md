# Implementation Plan: Per-Session Project Directory

**Spec ID:** 002-per-session-project-directory
**Date:** 2026-04-29

## Summary

Add per-session project directory support to the emacs-mcp server.
Clients can specify a project directory at initialize time and change it
mid-session. Six files modified, no new files, no new dependencies.

## Implementation Order

Changes are ordered to satisfy dependency chains: defcustom/hook first
(no dependencies), then validation (depends on defcustom), then protocol
handlers (depend on validation), then tests (depend on everything).

### Step 1: Add `defcustom` and hook variable to `emacs-mcp.el`

**File:** `emacs-mcp.el`
**What:**
- Add `emacs-mcp-allowed-project-directories` defcustom (FR-4)
- Add `emacs-mcp-project-dir-changed-hook` hook variable (FR-5)
- Add forward declaration for `emacs-mcp--validate-project-dir`

**Where:** After existing defcustoms (after line ~116), and in the hook
variables section (after line ~133).

**Risk:** None — pure additions, no existing behavior changes.

### Step 2: Add `emacs-mcp--validate-project-dir` to `emacs-mcp-session.el`

**File:** `emacs-mcp-session.el`
**What:** New function implementing FR-3 validation rules in order:
1. Non-empty string check
2. Absolute path check (`file-name-absolute-p`)
3. Canonicalize (`expand-file-name` + `file-truename`)
4. Existing directory check (`file-directory-p`)
5. Allowlist check if `emacs-mcp-allowed-project-directories` is non-nil
   (canonicalize each entry, then `file-in-directory-p`)
6. Return canonical path on success, signal error on failure

**Where:** After `emacs-mcp--resolve-project-dir` (after line ~153).

**Risk:** Low. `file-truename` may be slow on network FS, but
constitution says Emacs 29+ / localhost only.

### Step 3: Modify `emacs-mcp--handle-initialize` in `emacs-mcp-protocol.el`

**File:** `emacs-mcp-protocol.el`
**What:** (FR-1)
- Extract `projectDir` from `params` via `(alist-get 'projectDir params)`
- If present: validate with `emacs-mcp--validate-project-dir`
  - On success: use validated path as session's project-dir
  - On failure: return JSON-RPC error -32602, do NOT create session
- If absent: use existing global fallback (no behavior change)

**Where:** Modify `emacs-mcp--handle-initialize` (lines 72-98).

**Key change:** Wrap session creation in a `condition-case`. If
validation fails, return error response instead of creating session.

**Risk:** Medium — this is the initialize handler, which is critical
path. Must preserve the `:session-id` metadata attachment for transport.

### Step 4: Add `emacs-mcp/setProjectDir` handler to `emacs-mcp-protocol.el`

**File:** `emacs-mcp-protocol.el`
**What:** (FR-2)
- New handler `emacs-mcp--handle-set-project-dir`
- Guard: if the message is a notification (no `id`), return nil without
  mutating state. Use `emacs-mcp--jsonrpc-request-p` to verify the
  message is a request before proceeding. This prevents the
  `emacs-mcp--protocol-dispatch` notification path from silently
  mutating session state.
- Check session state is `ready` (else error -32600)
- Extract `projectDir` from params, validate with
  `emacs-mcp--validate-project-dir`
- Compare canonical new path with current `project-dir`
- If different: update session slot, fire
  `emacs-mcp-project-dir-changed-hook` with (session-id, old, new)
- If same: return success without firing hook
- Return `{ "projectDir": "/canonical/path" }`
- Add entry to `emacs-mcp--method-dispatch-table`

**Where:** New function after `emacs-mcp--handle-prompts-list`.
Add `("emacs-mcp/setProjectDir" . emacs-mcp--handle-set-project-dir)`
to the dispatch table.

**Risk:** Low — new handler, no modification to existing handlers.

### Step 4a: Deferred context guarantee

**File:** `emacs-mcp-tools.el`
**What:** The spec requires that deferred operations retain the project
context captured at dispatch time. The current architecture partially
provides this: tool handlers run synchronously inside `let`-bound
`emacs-mcp--current-session-id`, and deferred completion
(`emacs-mcp-complete-deferred`) only wraps/delivers the result without
re-reading `project-dir`.

However, if a handler spawns an async process whose callback looks up
the session, it would see the post-change `project-dir`. To close this
gap:

- Add a new dynamic variable `emacs-mcp--current-project-dir`
- Add `declare-function` for `emacs-mcp--session-get` and
  `emacs-mcp-session-project-dir` (from `emacs-mcp-session`) to avoid
  adding a hard `require` — `emacs-mcp-tools.el` does not currently
  depend on `emacs-mcp-session.el` and adding a require would create a
  tighter coupling. The session module is always loaded before tool
  dispatch runs (loaded by `emacs-mcp-start`).
- In `emacs-mcp--dispatch-tool`, look up the session via
  `(emacs-mcp--session-get session-id)` and bind
  `emacs-mcp--current-project-dir` to
  `(emacs-mcp-session-project-dir session)` alongside the existing
  `emacs-mcp--current-session-id` binding (line 233).
- Deferred tool handlers that need project context should read
  `emacs-mcp--current-project-dir` (or capture it in a closure) rather
  than looking up the session's slot.

**Where:** `emacs-mcp-tools.el` lines 22-26 (add variable +
declare-functions), lines 233-234 (add session lookup + binding in
`emacs-mcp--dispatch-tool`).

**Risk:** Low — additive change; existing tools do not use the new
variable and remain correct. `declare-function` keeps the dependency
soft.

### Step 5: Write ERT tests

**File:** `test/emacs-mcp-test-session.el` (extend existing)
**New file:** None — extend existing test files.

**Tests for `emacs-mcp--validate-project-dir`** (in test-session.el):
- Valid absolute directory → returns canonical path
- Empty string → error
- Relative path → error
- Non-existent directory → error
- Path outside allowlist → error with generic message
- Path inside allowlist → success
- Allowlist with tilde/symlink → canonical comparison works

**Tests for `initialize` with `projectDir`** (in test-protocol.el):
- AC-1: Two sessions with different projectDir
- AC-3: Invalid projectDir → error, no session created
- AC-5: Missing projectDir → global fallback

**Tests for `emacs-mcp/setProjectDir`** (in test-protocol.el):
- AC-2 (scoping): setProjectDir changes session's project-dir; then
  call `project-info` tool and verify it returns the new directory
- AC-2 (path auth): after setProjectDir, verify
  `emacs-mcp--check-path-authorization` accepts a file inside the new
  project-dir and rejects a file inside the old one
- AC-6: Hook fires on actual change, not on same-dir
- Session not ready → error -32600
- Invalid path → error -32602, project-dir unchanged
- Notification guard: sending `emacs-mcp/setProjectDir` as a
  notification does not mutate session state
- Deferred context: verify `emacs-mcp--current-project-dir` is bound
  to the dispatch-time project-dir during handler execution

### Step 6: Byte-compile and checkdoc verification

**What:** Run `emacs --batch -f batch-byte-compile` on all modified
files. Run checkdoc on all modified files (including internal functions
like `emacs-mcp--validate-project-dir` and
`emacs-mcp--handle-set-project-dir`).

**AC-7 coverage.**

## Files Modified

| File | Change Type | Lines (est.) |
|------|-------------|-------------|
| `emacs-mcp.el` | Add defcustom + hook + forward decl | +20 |
| `emacs-mcp-session.el` | Add validation function | +35 |
| `emacs-mcp-protocol.el` | Modify initialize, add handler + dispatch | +55 |
| `emacs-mcp-tools.el` | Add project-dir dynamic variable + binding | +5 |
| `test/emacs-mcp-test-session.el` | Add validation tests | +60 |
| `test/emacs-mcp-test-protocol.el` | Add protocol tests | +90 |

**Total:** ~265 lines added, ~8 lines modified, 0 new files.

## Dependencies

No new external dependencies. All functions used (`file-name-absolute-p`,
`expand-file-name`, `file-truename`, `file-directory-p`,
`file-in-directory-p`) are built-in Emacs primitives.

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| `file-truename` slow on NFS | Localhost-only server; document in defcustom |
| Initialize error path breaks transport | Test that no session is created; transport handles nil session-id |
| Dispatch table ordering | New entry appended; order doesn't matter for alist lookup |
| `cl-every` used in defcustom `:safe` | Already used in existing code (`emacs-mcp-extra-lockfile-directories`) |

## Non-Goals

- No changes to `emacs-mcp-transport.el` (session validation already works)
- No changes to `emacs-mcp-tools-builtin.el` (tools already read from session struct)
- No changes to `emacs-mcp-http.el`
- No lockfile updates per session
- Minimal change to `emacs-mcp-tools.el` (add dynamic variable + binding only)
