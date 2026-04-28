# Gauge Review — Task 7 Iteration 1

**Reviewer**: Codex
**Date**: 2026-04-29

BLOCKING: `emacs-mcp--http-filter` at line 93 can error before dispatch. `(process-get process :server)` is not documented for accepted clients; accepted clients inherit the server plist directly. If `:server` is nil, `(process-get nil :handler)` throws, so the fallback is unreachable.

BLOCKING: `emacs-mcp--http-filter` at line 99 dispatches valid methods on non-`/mcp` paths to the handler. The task requires path not `/mcp` -> 404. A GET/POST/DELETE to `/other` is passed to the handler instead of rejected with 404.

BLOCKING: The required function names `emacs-mcp--http-parse-request` and `emacs-mcp--http-validate-origin` are not implemented. The implementation provides `emacs-mcp--http-try-parse-request` and `emacs-mcp--http-valid-origin-p` instead. The tests were written against the renamed helpers, so they do not catch the API contract violation. Other modules (transport layer) expecting the spec-mandated names will fail to compile.

BLOCKING: `emacs-mcp--http-try-parse-request` at line 133 only matches a fixed allowlist of HTTP methods. Unsupported methods like `TRACE /mcp HTTP/1.1` never parse, so the filter never gets a request object and never returns 405. The 405 path is dead code for any unlisted method.

WARNING: `emacs-mcp--http-filter` at line 76 handles one complete request then clears the entire buffer. Extra bytes (pipelining, trailing data) are discarded and the response does not declare `Connection: close`. This silently drops data in pipeline scenarios.

WARNING: `test/emacs-mcp-test-http.el` covers only parsing and origin predicate cases. It does not test filter dispatch, fragmented filter calls, 404/405 routing, response formatting, SSE header/event formatting, `http-stop` behavior, `http-close-connection`, or sentinel disconnect cleanup.

NOTE: All 13 existing ERT tests pass and byte-compilation was clean. A live `make-network-process` accept test could not run in the sandbox (socket bind rejected with `Operation not permitted`).

VERDICT: REVISE
