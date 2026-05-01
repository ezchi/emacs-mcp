# Task 5: Tool Registry Framework — Forge Iteration 1

## Files Changed
- `emacs-mcp-tools.el` — modified (full implementation)
- `test/emacs-mcp-test-tools.el` — created (20 ERT tests)

## Key Implementation Decisions
- `emacs-mcp-deftool` macro generates a named handler function `emacs-mcp-tool-<name>--handler`
- Tool registry is a global alist with replace-on-register semantics (re-registering replaces)
- `dispatch-tool` catches handler errors and wraps them as tool execution errors (isError=true)
- Confirmation denied returns tool error, not protocol error
- Dynamic variables `emacs-mcp--current-session-id` and `emacs-mcp--current-request-id` bound during dispatch

## Tests Added
- `test/emacs-mcp-test-tools.el` — 20 tests: registration, unregistration, deftool macro, deftool callable, deftool confirm, schema generation (basic + all 6 types), arg validation (missing required, wrong type, null optional, correct), result wrapping (string, content vector, deferred, error), dispatch (unknown, handler error, dynamic vars, deferred)
