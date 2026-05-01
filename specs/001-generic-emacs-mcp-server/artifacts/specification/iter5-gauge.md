# Gauge Review — Iteration 5

**Reviewer**: Codex (GPT-5.5)
**Date**: 2026-04-26

## BLOCKING Issues

None.

The Iteration 4 blocking issue is resolved. FR-1.2 now defines deterministic behavior for mixed immediate/deferred batch requests: non-deferred batches return a JSON array, and any batch containing a deferred request uses SSE with one response event per request.

## WARNINGs

1. **Acceptance coverage for deferred batch behavior is still thin** — AC-14 covers a normal two-request batch, but it does not cover the exact edge case that caused the Iteration 4 blocker: a batch with one immediate request and one deferred request. The requirement text is clear enough to approve, but implementation tasks should add an explicit ERT/integration test for this.

2. **`xref-find-apropos` project isolation is weakly worded** — FR-3.2 says results are scoped to the session project "where possible." That is acceptable for an xref backend abstraction, but the implementation should still filter any returned file-backed locations through `file-in-directory-p` before returning them. Otherwise the security statement in NFR-4 overpromises.

3. **Constitution artifact has a stale protocol line** — `.steel/constitution.md` still says "MCP over JSON-RPC/stdio", while this spec correctly targets MCP 2025-03-26 Streamable HTTP. The gauge prompt itself identifies Streamable HTTP as the target, so this is not a spec blocker, but the constitution artifact should be reconciled before later workflow stages.

## Evaluation

The specification is complete enough for implementation. It defines the MCP Streamable HTTP endpoint, POST/GET/DELETE behavior, session handling, lifecycle, version negotiation, tool registration, argument validation, deferred responses, lockfiles, lifecycle APIs, confirmation policy, and acceptance criteria.

The spec is MCP-compliant in the areas reviewed against the 2025-03-26 transport and lifecycle rules: single endpoint, batch receiving, 202 for notification/response-only posts, JSON or SSE responses for requests, GET SSE or 405, Origin validation, session IDs via `Mcp-Session-Id`, 400 for missing required session ID, 404 for terminated/unknown sessions, and version negotiation behavior.

The spec aligns with the stated constitution constraints: Emacs-native implementation, Emacs 29+, zero required external dependencies, no load-time network/process side effects, AGPL packaging requirements, user-configurable behavior, localhost binding, path authorization, and explicit confirmation for `execute-elisp`.

VERDICT: APPROVE
