# Gauge Review — Task 5 Iteration 1

**Reviewer**: Codex
**Date**: 2026-04-29

BLOCKING: `emacs-mcp--wrap-tool-result` does not implement the required content-list return convention. FR-2.6 and the task both say a handler may return a list of content alists and that list must be used as the `content` array. The implementation only recognizes a vector whose first element has a `type` key, so a valid handler return like `(((type . "text") (text . "ok")))` is converted into a single text item containing the printed Elisp list. This breaks the documented public tool API. Fix [emacs-mcp-tools.el](/Users/ezchi/Projects/emacs-mcp/emacs-mcp-tools.el:171) and add a test that passes a list of content alists, not only a vector.

BLOCKING: Required arguments set to JSON `null` pass validation. FR-2.7 only permits null values for optional arguments; required arguments must still satisfy their declared JSON type. Current validation skips type checking for every `:null` value once the key is present, so `(("x" . :null))` passes for `(:name "x" :type string :required t)`. That lets invalid calls reach handlers. Fix [emacs-mcp-tools.el](/Users/ezchi/Projects/emacs-mcp/emacs-mcp-tools.el:133) so `:null` is accepted only when the parameter is not required, and add a required-null rejection test.

BLOCKING: Array item schemas from `:items` are ignored. FR-2.2 explicitly states that array item type is declared via the `:items` keyword, but `emacs-mcp--tool-input-schema` emits only `((type . "array"))`. Clients consuming `tools/list` lose the item contract. Fix [emacs-mcp-tools.el](/Users/ezchi/Projects/emacs-mcp/emacs-mcp-tools.el:97) to emit an `items` schema when `:type array` has `:items`, and test at least one array parameter with item type.

Verified: the existing 20 ERT tests pass. `emacs-mcp-tools.el` byte-compiles cleanly. Focused probes confirmed the first two blockers: required `:null` is accepted, and content-list returns are stringified instead of passed through.

VERDICT: REVISE
