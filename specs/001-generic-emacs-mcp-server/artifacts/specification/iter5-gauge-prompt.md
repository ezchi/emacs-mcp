# Gauge Review: Specification Iteration 5 (Final)

You are the Gauge — an independent reviewer. This is the FINAL iteration (5 of 5). All previous BLOCKING issues have been addressed.

## Context

**Project**: `emacs-mcp` — Generic Emacs MCP server package.
**MCP version**: 2025-03-26, Streamable HTTP transport.
**Constitution**: Emacs-native, MCP-compliant, zero external deps, AGPL-3.0, user control, Emacs 29+.

## Changes Since Iteration 4

BLOCKING fix:
- Batch + deferred: If any request in a batch triggers a deferred response, the entire batch response uses SSE (each response as a separate event). If no deferred, returns JSON array.

WARNING fixes:
- FR-6.2: Stopped server = connection refused (not HTTP 404)
- resources/list returns `{"resources": []}`, prompts/list returns `{"prompts": []}` — exact shape defined
- Version negotiation: server always responds with `2025-03-26`, client disconnects if incompatible
- AC-10 expanded to 7 concrete Origin test cases (absent, present, IPv6, HTTPS, malformed)

## Specification to Review

Read: /Users/ezchi/Projects/emacs-mcp/specs/001-generic-emacs-mcp-server/spec.md

## Review

Evaluate for completeness, clarity, testability, consistency, feasibility, MCP compliance, and constitution alignment.

End with: `VERDICT: APPROVE` or `VERDICT: REVISE`
