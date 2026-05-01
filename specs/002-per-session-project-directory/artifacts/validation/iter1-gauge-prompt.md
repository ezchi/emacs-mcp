# Gauge Verification: Validation Iteration 1

You are verifying a validation report for a feature implementation.
Your job is to independently check that the Forge's claims are correct.

## Files to Verify

1. **Validation report**: `specs/002-per-session-project-directory/validation.md`
2. **Spec**: `specs/002-per-session-project-directory/spec.md`
3. **Test output**: `specs/002-per-session-project-directory/artifacts/validation/iter1-test-output.txt`
4. **Source files**: `emacs-mcp.el`, `emacs-mcp-session.el`, `emacs-mcp-protocol.el`, `emacs-mcp-tools.el`
5. **Test files**: `test/emacs-mcp-test-session.el`, `test/emacs-mcp-test-protocol.el`

## Verification Tasks

1. **PASS claims**: For each PASS in the report, verify the cited test
   actually exists in the test file AND appears as "passed" in the test
   output. Read the test code to confirm it tests what the report claims.

2. **Coverage gaps**: Are there requirements from the spec that have no
   test coverage? The report claims 12 PASS — verify all 5 FRs, 7 ACs,
   and 4 NFRs are addressed.

3. **Test validity**: Do any tests pass trivially (always-true
   assertions, mocked-away logic)? Check for real assertions.

4. **Security claims**: Verify the path traversal, allowlist bypass,
   and information leakage claims by reading the actual validation code.

5. **Summary accuracy**: Does the "12 PASS, 0 FAIL, 0 DEFERRED"
   summary match the actual count of verdicts in the Results tables?

## Format

For each disputed claim:
```
### [SEVERITY] Title
- **Claim:** what the Forge report says
- **Reality:** what the code/tests actually show
- **Impact:** how this affects the verdict
```

End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
