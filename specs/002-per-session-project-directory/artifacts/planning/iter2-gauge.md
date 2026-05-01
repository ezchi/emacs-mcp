# Gauge Review: Planning Iteration 2

**Reviewer:** Codex (gpt-5.5)
**Date:** 2026-04-29

## Prior Issues: All 4 resolved.

## New Findings

### [BLOCKING] Notification Path Can Mutate State
- **Location:** Step 4 / FR-2
- **Issue:** `emacs-mcp/setProjectDir` is a request, but
  `emacs-mcp--protocol-dispatch` calls handlers for notifications too.
  Handler must check message is a request before mutating state.
- **Suggestion:** Add explicit request check and test notification
  does not change session.

### [BLOCKING] Step 4a Missing Dispatch Data Source
- **Location:** Step 4a
- **Issue:** `emacs-mcp--dispatch-tool` receives `session-id` but
  `emacs-mcp-tools.el` doesn't require `emacs-mcp-session`. Plan
  doesn't specify how to get session's project-dir for binding.
- **Suggestion:** Add `declare-function` for session accessors or
  pass project-dir from protocol layer.

### [WARNING] AC-2 Test Still Misses Authorization
- **Location:** Step 5
- **Issue:** Calling `project-info` proves scoping but not path
  authorization. Should also test that path authorization uses new dir.
- **Suggestion:** Add post-change test that exercises path auth.

VERDICT: REVISE
