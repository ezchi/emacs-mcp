# Gauge Review: Planning Iteration 3

**Reviewer:** Codex (gpt-5.5)
**Date:** 2026-04-29

## Prior Issues: All 3 resolved.

## New Findings

### [BLOCKING] Soft Session Dependency Is Not Safe
- **Location:** Step 4a
- **Issue:** `declare-function` only suppresses byte-compiler warnings;
  it does not load `emacs-mcp-session`. `emacs-mcp-tools.el` is used
  independently by `test/emacs-mcp-test-tools.el`, which requires only
  `emacs-mcp-tools` and calls `emacs-mcp--dispatch-tool`. A literal
  Step 4a implementation can hit an undefined `emacs-mcp--session-get`.
- **Suggestion:** Add `(require 'emacs-mcp-session)` in
  `emacs-mcp-tools.el`, or pass `project-dir` into dispatch from the
  protocol layer.

VERDICT: REVISE
