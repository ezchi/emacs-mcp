# Clarifications: Per-Session Project Directory

**Spec ID:** 002-per-session-project-directory
**Date:** 2026-04-29

## CLR-1: Location of `projectDir` in Initialize Params [NO SPEC CHANGE]

The `projectDir` field is a top-level key in the `initialize` request's
`params` object, alongside the standard MCP fields (`protocolVersion`,
`capabilities`, `clientInfo`).

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": { "name": "my-agent", "version": "1.0" },
    "projectDir": "/home/user/my-project"
  }
}
```

This is a server-specific extension field. MCP clients that do not know
about `emacs-mcp` will simply not include it, which triggers the
existing fallback chain (FR-1). MCP does not prohibit additional fields
in `params`.

## CLR-2: Session State Requirement for `setProjectDir` [SPEC UPDATE]

**Implicit assumption made explicit:** The `emacs-mcp/setProjectDir`
method SHALL only succeed when the session is in the `ready` state
(i.e., after the client has sent `notifications/initialized`). If the
session is still in `initializing` state, the server SHALL return a
JSON-RPC error (code -32600, invalid request) with message "Session not
ready".

**Rationale:** During the `initializing` → `ready` transition, the
client hasn't confirmed it received the server's capabilities. Allowing
project changes before the handshake completes adds ambiguity about
which project context tools would use.

## CLR-3: Allowlist Paths Are Also Canonicalized [SPEC UPDATE]

**Implicit assumption made explicit:** When checking whether a
client-requested path is within `emacs-mcp-allowed-project-directories`
(FR-3, rule 4), the allowlist entries MUST also be canonicalized via
`expand-file-name` + `file-truename` before comparison.

**Rationale:** If a user sets the allowlist to `~/projects` (with a
tilde) or a symlink path, and the client sends the resolved real path,
the comparison would fail without canonicalization. Both sides must be
in canonical form for `file-in-directory-p` to produce correct results.

## CLR-4: Same-Directory Change Is Not a No-Op [NO SPEC CHANGE]

If `emacs-mcp/setProjectDir` is called with a directory that, after
canonicalization, equals the session's current `project-dir`, the
request still succeeds and returns the project directory. However,
`emacs-mcp-project-dir-changed-hook` SHALL NOT fire because no change
occurred.

**Rationale:** Simplifies client logic (no need to track current state
before calling). Suppressing the hook avoids spurious side effects for
what is effectively a no-op.

## CLR-5: Deferred Operations During Project Directory Change [SPEC UPDATE]

If a deferred tool operation is in-flight when `emacs-mcp/setProjectDir`
is called, the deferred operation continues under its original context.
The new project directory applies only to tool calls dispatched after
the change.

**Rationale:** Deferred operations were authorized and dispatched under
the old project directory's path authorization rules. Retroactively
changing their context would be both complex and semantically wrong —
the tool is already executing against the old project's files.

## CLR-6: Error Messages Shall Not Leak Allowlist [SPEC UPDATE]

When a client-requested `projectDir` is rejected because it is outside
`emacs-mcp-allowed-project-directories`, the error message SHALL say
"Project directory not in allowed list" (or similar) without enumerating
the allowed directories. This prevents information leakage about the
server's filesystem layout.

## CLR-7: JSON Field Naming Convention [NO SPEC CHANGE]

The `projectDir` field uses camelCase, consistent with the existing MCP
JSON convention (e.g., `clientInfo`, `protocolVersion`, `serverInfo`,
`listChanged`).

The Emacs Lisp side reads this via `(alist-get 'projectDir params)`
because the project's JSON-RPC parser (`emacs-mcp--jsonrpc-parse`) uses
`:object-type 'alist`, which produces symbol-keyed alists. Note: bare
`json-parse-string` defaults to hash-tables with string keys — the
symbol-key behavior comes from the project's explicit `:object-type`
option.

The custom method name `emacs-mcp/setProjectDir` also uses camelCase
after the namespace prefix, matching MCP's method naming pattern
(e.g., `tools/list`, `notifications/initialized`).
