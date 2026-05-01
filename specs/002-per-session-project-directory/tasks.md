# Tasks: Per-Session Project Directory

**Spec ID:** 002-per-session-project-directory

## Task 1: Add defcustom and hook variable

**Description:** Add `emacs-mcp-allowed-project-directories` defcustom
and `emacs-mcp-project-dir-changed-hook` hook variable to `emacs-mcp.el`.
Add forward declaration for `emacs-mcp--validate-project-dir`.

**Files:** `emacs-mcp.el`

**Dependencies:** None

**Verification:**
- `emacs-mcp-allowed-project-directories` exists as a defcustom with
  type `(choice (const nil) (repeat directory))`, default nil,
  group `emacs-mcp`
- `emacs-mcp-project-dir-changed-hook` exists as a defvar with docstring
- Forward declaration for `emacs-mcp--validate-project-dir` present
- File byte-compiles cleanly

## Task 2: Implement project directory validation

**Description:** Add `emacs-mcp--validate-project-dir` to
`emacs-mcp-session.el`. Implements FR-3: validates non-empty string,
absolute path, canonicalizes, checks directory exists, checks allowlist.
Returns canonical path or signals error.

**Files:** `emacs-mcp-session.el`

**Dependencies:** Task 1 (needs `emacs-mcp-allowed-project-directories`)

**Verification:**
- Function exists and accepts a single string argument
- Returns canonical path for valid directories
- Signals error for: empty string, relative path, non-existent dir,
  path outside allowlist
- Allowlist error message does not enumerate allowed directories
- File byte-compiles cleanly

## Task 3: Modify initialize handler for per-session projectDir

**Description:** Modify `emacs-mcp--handle-initialize` in
`emacs-mcp-protocol.el` to extract optional `projectDir` from params.
If present, validate and use as session project-dir. If validation fails,
return JSON-RPC error -32602 without creating a session. If absent, use
existing global fallback.

**Files:** `emacs-mcp-protocol.el`

**Dependencies:** Task 2 (needs `emacs-mcp--validate-project-dir`)

**Verification:**
- Initialize with `projectDir` creates session with that directory
- Initialize with invalid `projectDir` returns error, no session created
- Initialize without `projectDir` uses global fallback (unchanged)
- File byte-compiles cleanly

## Task 4: Add setProjectDir handler

**Description:** Add `emacs-mcp--handle-set-project-dir` handler and
register `emacs-mcp/setProjectDir` in the method dispatch table. Handler
must: guard against notification path (check `emacs-mcp--jsonrpc-request-p`),
check session is `ready`, validate path, update session slot, fire
`emacs-mcp-project-dir-changed-hook` only when directory actually changes.

**Files:** `emacs-mcp-protocol.el`

**Dependencies:** Task 1 (needs hook), Task 2 (needs validation),
Task 3 (initialize must work first for testing)

**Verification:**
- `emacs-mcp/setProjectDir` appears in dispatch table
- Valid request changes session's project-dir and returns new path
- Same-directory request succeeds but hook does not fire
- Different-directory request fires hook with correct args
- Notification does not mutate state
- Session not ready → error -32600
- Invalid path → error -32602, project-dir unchanged
- File byte-compiles cleanly

## Task 5: Add deferred context variable

**Description:** Add `emacs-mcp--current-project-dir` dynamic variable
to `emacs-mcp-tools.el`. Add `(require 'emacs-mcp-session)`. Bind the
variable in `emacs-mcp--dispatch-tool` by looking up the session and
reading its project-dir at dispatch time.

**Files:** `emacs-mcp-tools.el`

**Dependencies:** Task 2 (needs session accessors available)

**Verification:**
- `emacs-mcp--current-project-dir` is non-nil during tool handler execution
- Value matches the session's project-dir at dispatch time
- Existing tool tests still pass
- File byte-compiles cleanly

## Task 6: Write validation tests

**Description:** Add ERT tests for `emacs-mcp--validate-project-dir` to
`test/emacs-mcp-test-session.el`.

**Files:** `test/emacs-mcp-test-session.el`

**Dependencies:** Task 2

**Tests:**
- Valid absolute directory → returns canonical path
- Empty string → error
- Relative path → error
- Non-existent directory → error
- Path outside allowlist → error with generic message (not leaking paths)
- Path inside allowlist → success
- Allowlist with tilde → canonical comparison works

## Task 7: Write protocol tests

**Description:** Add ERT tests for initialize-with-projectDir and
`emacs-mcp/setProjectDir` to `test/emacs-mcp-test-protocol.el`.

**Files:** `test/emacs-mcp-test-protocol.el`

**Dependencies:** Task 3, Task 4, Task 5

**Tests:**
- AC-1: Two sessions with different projectDir values
- AC-2 (scoping): setProjectDir then project-info returns new dir
- AC-2 (path auth): path authorization uses new project-dir
- AC-3: Invalid projectDir at initialize → error, no session
- AC-5: Missing projectDir → global fallback
- AC-6: Hook fires on actual change, not on same-dir
- Session not ready → error -32600
- Invalid path → error -32602, unchanged
- Notification guard: notification does not mutate state
- Deferred context: `emacs-mcp--current-project-dir` bound correctly

## Task 8: Byte-compile and checkdoc verification

**Description:** Run byte-compilation and checkdoc on all modified files.
Fix any warnings or errors.

**Files:** All modified files

**Dependencies:** Tasks 1-7

**Verification:**
- All modified `.el` files byte-compile with zero warnings
- All new functions/variables/defcustoms pass checkdoc
- AC-7 satisfied
