# Task 2: JSON-RPC 2.0 Layer — Forge Iteration 1

## Files Changed
- `emacs-mcp-jsonrpc.el` — modified (full implementation replacing stub)
- `test/emacs-mcp-test-jsonrpc.el` — created (21 ERT tests)

## Key Implementation Decisions
- Used `json-parse-string` with `:object-type 'alist` for idiomatic Emacs Lisp handling of JSON objects
- Used `:null-object :null` and `:false-object :false` to distinguish JSON null/false from Emacs nil
- Batch detection via `emacs-mcp--jsonrpc-batch-p` checks for list-of-alists structure (first element is a list whose car is a cons)
- Batch serialization converts list-of-alists to vector via `vconcat` before calling `json-serialize` (which requires vectors for JSON arrays)
- Removed `(require 'emacs-mcp)` dependency — this module is pure data transformation with no dependency on the main package

## Deviations from Plan
- None — implementation follows the plan exactly.

## Tests Added
- `test/emacs-mcp-test-jsonrpc.el` — 21 tests covering:
  - Parse: single request, notification, response, batch, malformed, string ID, null ID
  - Type predicates: request-p, notification-p, response-p, batch-p (single, empty)
  - Response construction: make-response (numeric/string ID), make-error (basic, with data, null ID)
  - Serialization: response, error, batch (round-trip)
  - Error code constants: all 5 codes verified
