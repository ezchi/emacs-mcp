# Gauge Review: Clarification Iteration 2

You are reviewing the second iteration of clarifications for a feature
specification. The previous iteration had 4 BLOCKING issues and 1
WARNING. This iteration addresses all of them.

## Previous BLOCKING Issues (verify each is resolved)

1. **Same-directory hook contradiction**: CLR-4 said hook SHALL NOT
   fire for same-directory, but AC-6 said hook fires whenever
   setProjectDir succeeds. → FR-5 and AC-6 should now say hook fires
   only when directory actually changes.

2. **Allowlist error non-leak rule missing**: CLR-6 was marked
   [NO SPEC CHANGE] but added a security requirement. → FR-3 should
   now require error messages not enumerate allowed directories.
   CLR-6 should be reclassified to [SPEC UPDATE].

3. **Deferred-operation context rule unspecified**: CLR-5 was marked
   [NO SPEC CHANGE] but defined authorization behavior. → FR-2 should
   now state deferred operations retain dispatch-time context.
   CLR-5 should be reclassified to [SPEC UPDATE].

4. **Canonical comparison order ambiguous**: FR-3 didn't explicitly
   state validation order. → FR-3 should now list numbered steps:
   canonicalize client path first, then canonicalize allowlist, then
   compare canonical-to-canonical.

## Previous WARNING (verify resolved)

5. **CLR-7 false JSON parsing claim**: Said `json-parse-string`
   converts to symbols by default. → Should reference
   `emacs-mcp--jsonrpc-parse` with `:object-type 'alist`.

## Files to Review

1. `specs/002-per-session-project-directory/clarifications.md`
2. `specs/002-per-session-project-directory/spec.md`
3. `.steel/constitution.md`

## Review Criteria

- Verify ALL 5 previous issues are resolved
- Check no new issues were introduced
- Check no unrelated sections were modified
- Check changelog accurately describes changes
- Check constitution alignment

## Format

```
### [SEVERITY] Title
- **Location:** section
- **Issue:** what's wrong
- **Suggestion:** fix
```

End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
