# Gauge Review — Iteration 2

**Reviewer**: Codex (GPT-5.5)
**Date**: 2026-04-26

## BLOCKING Issues

1. **Project root discovery not MCP-compliant** — FR-4.2 says project-dir comes from `rootUri`/`workspaceFolders` in initialize params, but MCP 2025-03-26 initialize params are only `protocolVersion`, `capabilities`, `clientInfo`. Roots come from `roots/list` (server-to-client request).

2. **Deferred response API boundary gap** — Tool handlers receive only `args`, but deferred completion requires SESSION-ID and REQUEST-ID. No way for custom deferred tools to access session/request context.

3. **Tool input validation incomplete** — Only checks missing required args. No type validation against inputSchema, no invalid value handling.

4. **Batch support contradictory** — FR-1.2 says POST accepts batch arrays, Out of Scope #9 says batching is MAY/not required. Pick one.

## WARNINGs

1. `ping` missing from supported methods.
2. `emacs-mcp-deftool` doesn't show `:confirm` keyword syntax.
3. Shutdown "send HTTP 404 to active sessions" impossible for SSE streams already open.
4. NFR-7 (no global hooks) vs FR-6.4 (add kill-emacs-hook when mode enabled) needs clarification.

## Previous Issues Resolution

Resolved: protocol version, initialized notification, AGPL header, flycheck optional, concurrency wording.
Not fully resolved: deferred responses, project/session semantics, tool input validation.

VERDICT: REVISE
