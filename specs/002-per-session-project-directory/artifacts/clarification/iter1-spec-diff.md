# Spec Diff — Clarification Iteration 1

## FR-2: Added session state requirement

**Before:**
```
**Behavior:**
- Requires a valid `Mcp-Session-Id` header (existing session validation).
- The `projectDir` param MUST be a string containing an absolute
  directory path.
```

**After:**
```
**Behavior:**
- Requires a valid `Mcp-Session-Id` header (existing session validation).
- The session MUST be in `ready` state (after `notifications/initialized`).
  If still `initializing`, return JSON-RPC error (code -32600, invalid
  request) with message "Session not ready".
- The `projectDir` param MUST be a string containing an absolute
  directory path.
```

## FR-3 rule 4: Allowlist entries also canonicalized

**Before:**
```
4. If `emacs-mcp-allowed-project-directories` is non-nil (see FR-4),
   the path MUST be within one of the allowed directories
   (`file-in-directory-p`).
```

**After:**
```
4. If `emacs-mcp-allowed-project-directories` is non-nil (see FR-4),
   the path MUST be within one of the allowed directories
   (`file-in-directory-p`). The allowlist entries MUST also be
   canonicalized (`expand-file-name` + `file-truename`) before
   comparison.
```

## Added Changelog section at bottom of spec.md

New section appended with two entries documenting the above changes.
