# Gauge Review: Specification Iteration 4

You are the Gauge — an independent reviewer. This is iteration 4. All previous BLOCKING issues have been addressed.

## Context

**Project**: `emacs-mcp` — Generic Emacs MCP server package (standalone, client-agnostic).
**MCP version**: 2025-03-26 with Streamable HTTP transport.
**Constitution**: Emacs-native, MCP-compliant, zero external deps, AGPL-3.0, user control.

## Changes Since Iteration 3

BLOCKING fixes:
1. Batch support: Server now MUST receive batch arrays per MCP spec. Only `initialize` cannot be batched.
2. Session ID HTTP status: Missing header = 400, unknown/expired session = 404.
3. Request ID type: Now string|number (MCP RequestId), not just integer. All APIs updated.
4. FR-2.4: Now includes `:confirm` keyword.

WARNING fixes:
1. FR-6.5 rewritten: allows package-internal registries at load time.
2. Accept header: server is lenient, does not reject based on Accept.
3. Path authorization consistently stated for all file-accepting tools (xref, treesit).
4. Pagination: v1 returns all tools in one response, cursor ignored.
5. Origin validation: exact predicate defined for absent/present/malformed cases, including IPv6 loopback and HTTPS variants.

New acceptance criteria: AC-12 (string request IDs), AC-13 (expired session 404), AC-14 (batch responses).

## Specification to Review

Read the file at: /Users/ezchi/Projects/emacs-mcp/specs/001-generic-emacs-mcp-server/spec.md

## Review Criteria

1. Completeness, clarity, testability, consistency, feasibility, constitution alignment.
2. Are ALL previous BLOCKING issues (iterations 1-3) fully resolved?
3. Any new issues introduced by the iteration 4 changes?

## Output Format

- **BLOCKING** / **WARNING** / **NOTE**

End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
