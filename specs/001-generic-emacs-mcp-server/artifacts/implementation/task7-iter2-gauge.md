# Gauge Review — Task 7 Iteration 2

**Reviewer**: Codex
**Date**: 2026-04-29

BLOCKING: `emacs-mcp--http-validate-origin` at line 230 uses `^...$` anchors with `string-match`. In Emacs Lisp, `^` and `$` match start/end of lines, not the full string. An origin string containing an embedded newline such as `"x\nhttp://localhost"` returns non-nil, bypassing the 403 rejection. Repro confirmed: `(emacs-mcp--http-validate-origin "x\nhttp://localhost")` returns `2`. Fix: use `\`...\`` anchors (`\\`\\([...\\)\\``) or explicitly reject strings containing control characters before the regex match.

WARNING: `emacs-mcp--http-sentinel` at line 58 calls `(process-contact process :server)` to retrieve the server process for handler propagation. The Emacs documentation does not document `:server` as a valid key for `process-contact` on accepted client processes (it documents that accepted client plists are initialized from the server plist, which means `:handler` is already inherited automatically without needing the sentinel's explicit `process-put`). Runtime verification was blocked (socket bind rejected with `Operation not permitted` in sandbox). If `process-contact process :server` returns nil, the `(processp server)` guard prevents a throw, but the handler propagation silently does nothing — relying on the already-inherited plist copy. This path is probably safe in practice but relies on undocumented behavior.

WARNING: `test/emacs-mcp-test-http.el` still has no regression tests for the dispatch fixes introduced in iteration 2: path `/other` → 404, `TRACE /mcp` → 405, invalid Origin short-circuits before path and method checks, valid `GET /mcp` dispatches to handler. These are the exact paths fixed in iteration 2 and none are tested.

NOTE: All 4 iteration-1 BLOCKING issues are otherwise fixed: the filter reads `(process-get process :handler)` directly, path check precedes method check, functions are named `emacs-mcp--http-parse-request` and `emacs-mcp--http-validate-origin`, and the request-line regex is `[A-Z]+` accepting any method. All 13 existing ERT tests pass. Byte-compilation is clean. Dispatch behavior verified by functional probe: `/other` → 404, `TRACE /mcp` → 405, invalid origin → 403, `GET /mcp` → handler all confirmed correct at runtime.

VERDICT: REVISE
