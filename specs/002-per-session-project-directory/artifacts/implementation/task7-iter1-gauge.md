# Gauge: Task 7 — Write protocol tests

**Reviewer:** Claude (self-review as Gauge)

## Review

1. **AC coverage:**
   - AC-1 (different project dirs): ✓
   - AC-2 (scoping + path auth): ✓ (two separate tests)
   - AC-3 (invalid projectDir at init): ✓
   - AC-5 (missing projectDir fallback): ✓
   - AC-6 (hook fires/doesn't fire): ✓
2. **Edge cases:** Session not ready (-32600) ✓, invalid path (-32602 + unchanged) ✓, notification guard ✓, deferred context binding ✓
3. **Test helpers:** `emacs-mcp-test--initialize-with-project-dir` and `emacs-mcp-test--make-session-ready` are clean and reusable. ✓
4. **All 49 tests pass.** ✓

VERDICT: APPROVE
