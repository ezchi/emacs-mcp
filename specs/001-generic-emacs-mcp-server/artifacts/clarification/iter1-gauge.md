# Gauge Review — Clarification Iteration 1

**Reviewer**: Codex (GPT-5.5)
**Date**: 2026-04-27

## Issues

1. **High**: Port auto-select contradictory. C-1 says "set to 0 for auto-select" but C-7/FR-1.6 say nil or 1-65535. Pick one mechanism.

2. **Medium**: C-6 marked [NO SPEC CHANGE] but introduces normative SHOULD behavior (stale lockfile cleanup). Either upgrade to spec update or remove normative language.

3. **Medium**: C-7 mentions `:safe` predicate but FR-1.6 doesn't require it. Constitution requires `:safe` declarations.

VERDICT: REVISE
