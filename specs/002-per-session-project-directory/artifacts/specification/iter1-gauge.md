# Gauge Review: Specification Iteration 1

**Reviewer:** Claude (fallback — codex gauge produced no review output)
**Date:** 2026-04-29

## Findings

### [WARNING] FR-1: Missing error behavior for invalid projectDir at initialize

- **Location:** FR-1 (Client-Specified Project Directory at Initialize)
- **Issue:** The spec says the value MUST be a string containing an absolute
  directory path, and refers to FR-3 for validation. But it does not specify
  what happens when validation fails during `initialize`. Should the server
  reject the entire initialize request (no session created)? Or create the
  session with the global fallback? The error path is ambiguous.
- **Suggestion:** Explicitly state: "If `projectDir` is present but fails
  validation, the server SHALL return a JSON-RPC error response (error code
  -32602) and SHALL NOT create a session."

### [WARNING] FR-2: Method naming convention

- **Location:** FR-2 (Mid-Session Project Directory Change)
- **Issue:** The method name `emacs-mcp/setProjectDir` uses camelCase
  (`setProjectDir`), while the existing MCP methods use slash-separated
  lowercase (`tools/list`, `tools/call`). The MCP spec convention for
  vendor-specific extensions is not firmly established, but the mixed
  naming style may confuse clients.
- **Suggestion:** Consider using `emacs-mcp/set_project_dir` or keeping
  `emacs-mcp/setProjectDir` but documenting the rationale. Either way,
  clarify that this is a custom server extension method, not part of the
  MCP standard. (This is already implied by the `emacs-mcp/` prefix but
  worth being explicit.)

### [NOTE] FR-3: file-truename may be slow on network filesystems

- **Location:** FR-3 (Project Directory Validation)
- **Issue:** `file-truename` resolves symlinks, which can be slow or
  fail on network-mounted filesystems. For a localhost-only server this
  is likely fine, but worth noting.
- **Suggestion:** No change needed, but consider documenting that
  symlinks are resolved.

### [NOTE] FR-4: Default nil means no restriction

- **Location:** FR-4 (Allowed Project Directories)
- **Issue:** The default of nil (no restriction) is the right choice for
  backward compatibility, but the security implications should be noted.
  A client can request any readable directory on the filesystem.
- **Suggestion:** Add a sentence to the spec noting this is intentional
  for backward compatibility, and that users concerned about security
  should set this variable.

### [NOTE] AC-3: Error code consistency

- **Location:** AC-3
- **Issue:** AC-3 specifies error code -32602 (invalid params). FR-2 does
  not explicitly state the error code. Ensure consistency.
- **Suggestion:** Add the error code to FR-2's failure description.

### [NOTE] Missing: Initialize response should include projectDir

- **Location:** FR-1
- **Issue:** The spec doesn't say whether the `InitializeResult` should
  include the resolved `projectDir` so the client knows what directory
  was assigned. This would be useful for clients that don't send
  `projectDir` to discover the server's default.
- **Suggestion:** Consider adding `projectDir` to the `serverInfo` or
  as a custom field in the initialize response. Not blocking — the
  client can call `project-info` tool to discover this.

## Constitution Alignment

- Naming conventions: `emacs-mcp-` / `emacs-mcp--` prefix ✓
- Docstrings and byte-compilation requirement stated ✓
- No load-time side effects ✓
- Security: path validation and allowlist mechanism ✓
- Emacs 29+ assumption (native JSON) ✓
- AGPL-3.0 compatible ✓
- User control: `emacs-mcp-allowed-project-directories` defcustom ✓

## Summary

The spec is well-structured, complete, and implementable. All acceptance
criteria are testable. The two WARNING items are about clarifying error
behavior (not missing functionality) and naming convention (cosmetic).
No BLOCKING issues found.

VERDICT: APPROVE
