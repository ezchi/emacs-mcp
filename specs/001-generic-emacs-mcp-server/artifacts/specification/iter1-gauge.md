# Gauge Review — Iteration 1

**Reviewer**: Codex (GPT-5.5)
**Date**: 2026-04-26

## BLOCKING Issues

1. **FR-1.1/FR-1.2 protocol version conflict** — Spec claims MCP `2024-11-05` but describes Streamable HTTP behavior (single `/mcp` endpoint, session headers) which is from `2025-03-26`. Choose one protocol revision.

2. **FR-4 deferred responses underspecified** — No definition of request ID retention, timeout, cancellation, user abort handling, or whether original HTTP request stays open vs SSE message carries the response later.

3. **US-6 approval mechanism missing** — Only disabling `execute-elisp` by default is not an approval mechanism for individual dangerous calls. Conflicts with "no UI beyond minor mode" in Out of Scope.

4. **NFR-3 concurrency claim technically false** — "Without blocking Emacs" contradicts "tool handlers run synchronously in Emacs's single thread." Rewrite.

5. **Project/session semantics missing** — Built-in tools rely on "current project" and "active buffer" but no definition of how project roots are per-client, path authorization, or concurrent client buffer interference.

6. **Tool registration/schema semantics imprecise** — No type grammar, JSON Schema generation rules, content object shape, handler exception mapping, or `isError` behavior defined. AC-2 untestable.

7. **Open questions contain core architecture decisions** — WebSocket compat, lockfile defaults, client relationship, per-client visibility, HTTP dependency all affect scope and public APIs. Cannot implement with these unresolved.

## WARNINGs

8. `notifications/initialized` should not get a response (it's a JSON-RPC notification).

9. `kill-emacs-hook` may violate no-global-state if installed at load time. Should only be added when server starts.

10. AGPL-3.0 compliance absent from functional/non-functional requirements and acceptance criteria.

## NOTEs

11. `flycheck` is external but NFR-2 claims only `web-server` is required. Mark flycheck optional.

VERDICT: REVISE
