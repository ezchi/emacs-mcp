# Gauge Review: Planning Iteration 3

Review the revised plan against 3 previous findings.

## Previous Issues (verify resolved)

1. **BLOCKING: Notification path mutation** → Step 4 should now include
   a notification guard using `emacs-mcp--jsonrpc-request-p`.

2. **BLOCKING: Missing dispatch data source** → Step 4a should specify
   `declare-function` for session accessors and session lookup in
   `emacs-mcp--dispatch-tool`.

3. **WARNING: AC-2 test misses authorization** → Tests should now
   include path authorization verification after `setProjectDir`.

## Files

1. `specs/002-per-session-project-directory/plan.md`
2. `emacs-mcp-tools.el` (verify `declare-function` approach is sound)
3. `emacs-mcp-protocol.el` (verify `emacs-mcp--jsonrpc-request-p` is available)

## Format

```
### [SEVERITY] Title
- **Location:** section
- **Issue:** what's wrong
- **Suggestion:** fix
```

End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
