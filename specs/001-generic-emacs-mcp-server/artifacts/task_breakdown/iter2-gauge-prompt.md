# Gauge Review: Task Breakdown — Iteration 2

You are a strict technical reviewer (the "Gauge"). Review the REVISED task breakdown for the `emacs-mcp` project.

## Your Inputs

1. **Task breakdown**: `specs/001-generic-emacs-mcp-server/tasks.md`
2. **Implementation plan**: `specs/001-generic-emacs-mcp-server/plan.md`
3. **Specification**: `specs/001-generic-emacs-mcp-server/spec.md`
4. **Constitution**: `.steel/constitution.md`
5. **Previous review**: `specs/001-generic-emacs-mcp-server/artifacts/task_breakdown/iter1-gauge.md`

Read ALL FIVE files before reviewing.

## Context

Iteration 1 found 2 BLOCKING and 6 MAJOR issues. The Forge has revised the task breakdown. Verify that ALL previous issues have been addressed:

1. **BLOCKING: Invalid task dependencies** — Task 4 depended on Task 5 but tested confirmation. Task 4 and 8 in same parallel group.
2. **BLOCKING: Shared defcustoms defined too late** — Sub-modules couldn't byte-compile without defcustoms.
3. **MAJOR: Session timer state underspecified** — No timer field in session struct.
4. **MAJOR: Project directory semantics not covered** — No implementation of FR-4.2 fallback.
5. **MAJOR: Transport verification missing edge cases** — Invalid session ID, DELETE unknown, Accept header, mixed batch.
6. **MAJOR: Hook argument contract** — Hooks should use `run-hook-with-args`, tests should verify.
7. **MAJOR: Task granularity too coarse** — Task 9 and Task 10 too large.
8. **MINOR: Zero external dependency verification** — No check on Package-Requires.

## Review Criteria

Same as iteration 1:

### 1. Completeness
- Does every FR, NFR, and AC map to at least one task?
- Are all files from the plan accounted for?

### 2. Ordering & Dependencies
- No circular deps, no missing deps
- Parallel groups are correct

### 3. Granularity
- Each task is a single focused session

### 4. Verification Criteria
- Clear, testable, match spec

### 5. Constitution Alignment
- Naming, docstrings, byte-compile, checkdoc, testing

## Output Format

```
### Issue N: <title>
**Severity**: BLOCKING | MAJOR | MINOR
**Criteria**: <which criterion>
**Details**: <what's wrong>
**Suggestion**: <how to fix>
```

If ALL previous issues are resolved and no new blocking/major issues found:
`VERDICT: APPROVE`

Otherwise:
`VERDICT: REVISE`
