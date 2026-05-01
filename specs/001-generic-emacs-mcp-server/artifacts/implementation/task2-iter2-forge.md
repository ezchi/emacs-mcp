# Task 2: JSON-RPC 2.0 Layer — Forge Iteration 2

## Files Changed
- `emacs-mcp-jsonrpc.el` — modified (fixed array representation and predicates)
- `test/emacs-mcp-test-jsonrpc.el` — modified (updated for vectors, added edge cases)

## Key Implementation Decisions
- Switched from `:array-type 'list` to `:array-type 'array` — JSON arrays are now vectors throughout, fixing nested array serialization (e.g., MCP content arrays)
- `emacs-mcp--jsonrpc-batch-p` now uses `(vectorp parsed)` — trivially correct, handles all edge cases including `[{}]` and `[]`
- All type predicates now use `(assq 'key msg)` for key presence instead of `(alist-get 'key msg)` — avoids conflating absent keys with falsy values
- Serialize still supports list-of-alists convenience for callers that collect responses into a list

## Deviations from Plan
- None — follows the plan. Array representation choice was an implementation detail.

## Tests Added (7 new, 28 total)
- `parse-batch-single-element` — single-element batch `[{...}]`
- `parse-batch-empty-object` — batch with empty object `[{}]`
- `parse-nested-arrays` — MCP content arrays round-trip correctly
- `request-p-empty-method` — empty-string method still detected as request
- `batch-p-empty-vector` — empty JSON array `[]` is a batch
- `serialize-vector-batch` — vector batch serialization
- `serialize-nested-arrays` — nested array (MCP content) round-trip
