# Gauge Code Review — Task 8: MCP Protocol Handlers (Iteration 1)

**Findings**

- BLOCKING: Known-method notifications incorrectly produce responses. `emacs-mcp--protocol-dispatch` blindly calls handlers, and handlers like `tools/list` build `((id . nil) ...)` responses for messages with no `id`. JSON-RPC notifications must not receive responses, and Task 8 says dispatch returns nil for notifications. See `emacs-mcp-protocol.el:42` and `emacs-mcp-protocol.el:103`.

- BLOCKING: `tools/call` can signal raw Lisp errors for malformed params before the `condition-case`. A request like `params: []` fails at `alist-get`, and `arguments: null` fails in `mapcar`, instead of returning JSON-RPC `-32602`. That violates "validate params" and "translate errors to JSON-RPC error responses." See `emacs-mcp-protocol.el:133` and `emacs-mcp-protocol.el:142`.

- BLOCKING: Null request IDs are rejected only for `tools/call`. `initialize`, `ping`, `tools/list`, `resources/list`, and `prompts/list` will accept `id: null` and return success responses, despite the spec saying MCP request IDs are string/number and null IDs are rejected. Centralize this in dispatch or every request handler. See `emacs-mcp-protocol.el:56` and `spec.md:218`.

- WARNING: Tests miss the paths that would catch the above: known-method notifications, malformed non-alist `params`, non-object/null `arguments`, null IDs outside `tools/call`, deferred `tools/call`, and `complete-deferred` error completion. Existing tests pass, but coverage is too thin around protocol error handling. See `test/emacs-mcp-test-protocol.el:207`.

- NOTE: Verified the empty-object concern from the checklist: with `json-parse-string :object-type 'alist`, `{}` parses as nil, not a hash-table. The current `{}` arguments case does not trigger the feared `mapcar` hash-table crash.

Verification run: protocol tests pass, all currently loaded ERT tests pass, `emacs-mcp-protocol.el` byte-compiles clean, and `checkdoc-current-buffer` produced no output.

VERDICT: REVISE
