# Task 11: Built-in Tools — Buffer & File — Forge Iteration 1

## Files Changed
- `emacs-mcp-tools-builtin.el` — modified (full implementation, all 10 tools)
- `test/emacs-mcp-test-tools-builtin.el` — created (15 ERT tests)

## Tests Added
- 15 tests: path auth (inside/outside), registration (all, disabled execute-elisp, enabled with confirm), project-info, list-buffers, open-file (success/outside), get-buffer-content (full/range), execute-elisp (deny/allow), defcustoms existence, execute-elisp default nil
