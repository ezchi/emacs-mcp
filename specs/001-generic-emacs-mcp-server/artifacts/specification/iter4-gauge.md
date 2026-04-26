# Gauge Review — Iteration 4

**Reviewer**: Codex (GPT-5.5)
**Date**: 2026-04-26

## BLOCKING Issues

1. **Batch + deferred behavior contradictory** — FR-1.2 says use SSE when any response may be deferred, but also says batch requests return a JSON array. A batch containing one deferred tools/call and one normal request has no well-defined behavior. Define one rule.

## WARNINGs

1. FR-6.2 says old session IDs receive 404 after stop, but AC-6 says connection refused. Stopped server can't return 404.
2. resources/list and prompts/list lack response shape and pagination details (tools/list was fixed, others not).
3. Version negotiation behavior underdefined.
4. AC-10 only tests non-localhost rejection — needs absent, malformed, IPv6, HTTPS cases.

## Previous Issues

All iteration 1-3 BLOCKINGs resolved. New BLOCKING from combining batch + deferred.

VERDICT: REVISE
