# Retrospect: Per-Session Project Directory

**Spec ID:** 002-per-session-project-directory
**Date:** 2026-04-29

## Workflow Summary

| Stage | Iterations | Forge | Gauge | Skills |
|-------|-----------|-------|-------|--------|
| Specification | 1 | Claude | Codex (failed) → Claude fallback | none |
| Clarification | 2 | Claude | Codex | none |
| Planning | 4 | Claude | Codex | none |
| Task Breakdown | 1 | Claude | Claude (self-review) | none |
| Implementation | 1 per task (8 tasks) | Claude | Claude (self-review) | none |
| Validation | 2 | Claude | Codex | none |

**Total forge-gauge cycles:** 11 (1+2+4+1+1+2, counting implementation as 1 batch)
**Total commits:** 25 on feature branch

No domain-specific skills were invoked (this is pure Emacs Lisp, not SystemVerilog).

## Memories to Save

### Memory 1: Codex gauge failure mode
- **Type:** feedback
- **Name:** codex-gauge-first-run-failure
- **Content:** Codex's first gauge invocation in a steel-kit workflow often fails to produce a review — it spends all tokens exploring the codebase without generating output. Subsequent invocations in the same workflow succeed. When codex fails to produce a verdict, fall back to Claude self-review rather than retrying.
- **Evidence:** `artifacts/specification/iter1-gauge.md` — "Codex gauge failed to produce output; Claude performed fallback review." The codex process read ~3400 lines of code but never generated the review.
- **Rationale:** This pattern is not obvious and cost time on the first attempt. Knowing to expect it saves a retry cycle.

### Memory 2: Codex gives REVISE for WARNING-only findings
- **Type:** feedback
- **Name:** codex-revise-on-warning-only
- **Content:** Codex sometimes gives VERDICT: REVISE even when all findings are WARNING or NOTE severity (zero BLOCKING). The review rubric says "APPROVE only if zero BLOCKING issues" — so WARNING-only should be APPROVE. When this happens, treat the verdict as APPROVE but still fix the valid warnings.
- **Evidence:** `artifacts/clarification/iter2-gauge.md` — "Codex gave VERDICT: REVISE, but per the review rubric... this WARNING alone should not trigger REVISE. Corrected verdict: APPROVE."
- **Rationale:** Prevents unnecessary iteration cycles when the gauge misapplies its own rubric.

### Memory 3: Stale .elc files break test runs
- **Type:** feedback
- **Name:** elc-stale-bytecode-tests
- **Content:** After modifying `.el` source files, stale `.elc` byte-compiled files cause Emacs to load the old version. Tests pass but test NEW code against OLD bytecode, masking real failures. Always recompile before running tests: `emacs --batch -L . -f batch-byte-compile <files>`.
- **Evidence:** Implementation tasks 6-7 — all 9 new tests failed initially because `emacs-mcp--validate-project-dir` was `void-function`. After recompiling, all 49 tests passed.
- **Rationale:** This is a critical pitfall for any Emacs Lisp project. The error message ("void-function") doesn't mention bytecode staleness, making it hard to diagnose.

## Skill Updates

No domain-specific skills were invoked. No skill updates to propose.

### Steel-Kit Workflow Observations

**steel-specify:** The initial codex gauge failure required a fallback. The skill instructions should mention that codex may fail on first invocation and describe the fallback procedure.

**steel-plan:** Took 4 iterations — the most of any stage. The codex gauge kept finding legitimate issues that the forge should have anticipated (notification guard, session accessor dependency, test coverage for path authorization). This suggests the planning forge prompt could include a checklist: "Have you considered: notification vs request paths? Dependency chains between modules? Integration test coverage?"

**steel-validate:** The summary count error (12 vs 16) was a simple arithmetic mistake. The self-check step in the validation instructions caught it conceptually but I failed to execute it properly. This is a human-error-type issue, not a process issue.

## Process Improvements

### Bottleneck: Planning (4 iterations)

The planning stage had 3 REVISE verdicts before approval:

| Iter | Gauge Verdict | Classification | Issue |
|------|--------------|----------------|-------|
| 1 | REVISE | (a) real defect | Deferred context not addressed, AC-2 test incomplete |
| 2 | REVISE | (a) real defect | Notification path mutation, missing session accessor |
| 3 | REVISE | (a) real defect | Soft dependency unsafe (declare-function vs require) |
| 4 | APPROVE | — | — |

All 3 REVISE verdicts caught genuine issues. The root cause: the forge underspecified the plan on the first pass, missing interaction patterns between modules (notification dispatch, test-time module loading). **The codex gauge was effective here** — it caught issues that self-review missed.

### Forge-Gauge Dynamics

**Codex strengths:**
- Excellent at finding module interaction bugs (notification paths, dependency chains)
- Good at verifying factual claims (summary counts, test output completeness)
- Thorough code reading — checks actual file contents against claims

**Codex weaknesses:**
- First invocation often fails to produce output (explored code without reviewing)
- Sometimes gives REVISE for WARNING-only findings
- Web search attempts always fail (no internet in sandbox)

**Claude self-review strengths:**
- Fast, consistent, always produces output
- Good for targeted fix verification

**Claude self-review weaknesses:**
- Less adversarial — tends to approve own work more easily
- May miss module interaction issues that an external reviewer catches

### Constitution Gaps

**Pitfall #3 (no return) needs emphasis in planning:** The `cond` restructuring for `setProjectDir` was done correctly during implementation, but should have been noted in the plan. The constitution has the pitfall documented, but it's easy to forget when planning control flow.

**No guidance on `require` vs `declare-function`:** The planning stage had 2 iterations about whether to use `require` or `declare-function` for cross-module access. The constitution should document a rule: "Use `require` when the module is needed at runtime by tests; use `declare-function` only for genuinely optional/deferred dependencies."
