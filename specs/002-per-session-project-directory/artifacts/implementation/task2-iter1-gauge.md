# Gauge: Task 2 — Implement project directory validation

**Reviewer:** Claude (self-review as Gauge)

## Review

1. **Correctness:** Validation order matches FR-3 exactly: non-empty string → absolute → canonicalize → directory-exists → allowlist check. Returns canonical path. Error messages: "not in allowed list" (generic, no leak). ✓
2. **Security:** Allowlist error does not enumerate allowed dirs. Both sides canonicalized before comparison. ✓
3. **Constitution compliance:** `emacs-mcp--` prefix ✓, docstring present ✓, uses `dolist` not `cl-some` ✓, no `return` usage ✓
4. **Edge cases:** Empty string caught. Nil caught (not stringp). Relative path caught. Non-existent dir caught after canonicalization.

### [NOTE] `file-truename` on non-existent path
- **Location:** emacs-mcp-session.el, validate-project-dir
- **Issue:** `file-truename` is called before `file-directory-p`. If the path doesn't exist, `file-truename` may return the path unchanged or behave unpredictably.
- **Assessment:** In practice, `file-truename` on a non-existent path returns the expanded path (it resolves what it can). The subsequent `file-directory-p` check catches the non-existence. Not a bug.

VERDICT: APPROVE
