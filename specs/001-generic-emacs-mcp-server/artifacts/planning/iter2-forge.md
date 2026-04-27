# Implementation Plan: 001-generic-emacs-mcp-server

## File Structure

```
emacs-mcp/
├── emacs-mcp.el                  # Main entry: defgroup, defcustoms, start/stop/restart, mode
├── emacs-mcp-http.el             # HTTP server: make-network-process, request parsing, response writing
├── emacs-mcp-jsonrpc.el          # JSON-RPC 2.0: parsing, response construction, error codes, batch
├── emacs-mcp-session.el          # Session management: create, lookup, timeout, cleanup, UUID
├── emacs-mcp-transport.el        # MCP Streamable HTTP transport: SSE, POST/GET/DELETE dispatch, session headers
├── emacs-mcp-protocol.el         # MCP protocol methods: initialize, tools/list, tools/call, ping, etc.
├── emacs-mcp-tools.el            # Tool registry: deftool macro, register/unregister, schema gen, validation
├── emacs-mcp-tools-builtin.el    # Built-in tools: xref, imenu, treesit, diagnostics, file ops
├── emacs-mcp-confirm.el          # Confirmation policy: confirm-function, default-confirm
├── emacs-mcp-lockfile.el         # Lockfile management: create, remove, stale cleanup
├── test/
│   ├── emacs-mcp-test-jsonrpc.el
│   ├── emacs-mcp-test-http.el
│   ├── emacs-mcp-test-session.el
│   ├── emacs-mcp-test-tools.el
│   ├── emacs-mcp-test-tools-builtin.el
│   ├── emacs-mcp-test-protocol.el
│   ├── emacs-mcp-test-transport.el
│   ├── emacs-mcp-test-lockfile.el
│   └── emacs-mcp-test-integration.el
├── README.org
├── LICENSE
└── .github/
    └── workflows/
        └── ci.yml
```

## Module Dependency Graph

```
emacs-mcp.el (entry point)
  ├── emacs-mcp-http.el        (no internal deps, uses make-network-process)
  ├── emacs-mcp-jsonrpc.el     (no internal deps, pure JSON-RPC logic)
  ├── emacs-mcp-session.el     (no internal deps, session struct + hash)
  ├── emacs-mcp-lockfile.el    (no internal deps, file I/O only)
  ├── emacs-mcp-confirm.el     (no internal deps, defcustom + y-or-n-p)
  ├── emacs-mcp-tools.el       (depends on: jsonrpc for schema gen)
  │   └── emacs-mcp-tools-builtin.el (depends on: tools for deftool)
  ├── emacs-mcp-protocol.el    (depends on: tools, session, jsonrpc)
  └── emacs-mcp-transport.el   (depends on: http, jsonrpc, session, protocol)
```

## Implementation Phases

### Phase 1: Foundation (no network, no MCP — pure data structures)

**P1.1** `emacs-mcp-jsonrpc.el` — JSON-RPC 2.0 layer
- `emacs-mcp--jsonrpc-parse-request` — Parse JSON string into request/notification/batch
- `emacs-mcp--jsonrpc-make-response` — Build response object with id, result
- `emacs-mcp--jsonrpc-make-error` — Build error response with code, message, data
- `emacs-mcp--jsonrpc-serialize` — Serialize response to JSON string
- `emacs-mcp--jsonrpc-batch-p` — Check if parsed JSON is a batch array
- `emacs-mcp--jsonrpc-request-p` / `notification-p` / `response-p` — Type predicates
- Constants for error codes: `-32700`, `-32600`, `-32601`, `-32602`, `-32603`
- ERT tests: `emacs-mcp-test-jsonrpc.el`

**P1.2** `emacs-mcp-session.el` — Session management
- `cl-defstruct emacs-mcp-session` — session-id, client-info, project-dir, state, timestamps, deferred hash, sse-streams
- `emacs-mcp--session-create` — Generate UUID v4, create session
- `emacs-mcp--session-get` / `emacs-mcp--session-remove` — Lookup/remove by ID
- `emacs-mcp--session-update-activity` — Touch last-activity timestamp
- `emacs-mcp--session-start-timeout-timer` — Idle timeout logic
- `emacs-mcp--sessions` — Global hash table of active sessions
- UUID v4 generation: use `(secure-hash 'sha256 (format "%s%s%s" (random) (emacs-pid) (current-time)))` to get 32 hex bytes, then format as UUID v4 with version nibble `4` at position 13 and variant bits `10xx` at position 17 per RFC 4122. This gives cryptographically strong randomness via SHA-256 seeded with system entropy. Format: `xxxxxxxx-xxxx-4xxx-Nxxx-xxxxxxxxxxxx` where N is `8`, `9`, `a`, or `b`
- ERT tests: `emacs-mcp-test-session.el`

**P1.3** `emacs-mcp-tools.el` — Tool registry (no handlers yet)
- `emacs-mcp--tools` — Global alist of registered tools
- `emacs-mcp-deftool` macro — Define tool, generate handler function, register
- `emacs-mcp-register-tool` — Programmatic registration
- `emacs-mcp-unregister-tool` — Remove tool by name
- `emacs-mcp--tool-input-schema` — Generate JSON Schema from param plists
- `emacs-mcp--validate-tool-args` — Validate required args + type checking
- `emacs-mcp--wrap-tool-result` — Wrap handler return into CallToolResult
- Parameter type mapping table (FR-2.2)
- ERT tests: `emacs-mcp-test-tools.el`

**P1.4** `emacs-mcp-confirm.el` — Confirmation policy
- `emacs-mcp-confirm-function` defcustom
- `emacs-mcp-default-confirm` — `y-or-n-p` prompt
- `emacs-mcp--maybe-confirm` — Check if tool needs confirmation, call function
- ERT tests: part of `emacs-mcp-test-tools.el`

**P1.5** `emacs-mcp-lockfile.el` — Lockfile management
- `emacs-mcp--lockfile-create` — Write lockfile JSON
- `emacs-mcp--lockfile-remove` — Delete lockfile
- `emacs-mcp--lockfile-remove-all` — Delete from all directories
- `emacs-mcp--lockfile-cleanup-stale` — Check PID, remove dead lockfiles
- `emacs-mcp--lockfile-path` — Compute path from port and directory
- ERT tests: `emacs-mcp-test-lockfile.el`

### Phase 2: HTTP Server (network layer, no MCP yet)

**P2.1** `emacs-mcp-http.el` — Minimal HTTP server
- `emacs-mcp--http-start` — Create TCP server with `make-network-process`
- `emacs-mcp--http-stop` — Close server and all client connections
- `emacs-mcp--http-parse-request` — Parse HTTP request line, headers, body
- `emacs-mcp--http-send-response` — Write HTTP response (status, headers, body)
- `emacs-mcp--http-send-sse-event` — Write SSE `data:` event
- `emacs-mcp--http-close-connection` — Close a client connection
- Connection accumulator: buffer incoming data until full request received (Content-Length)
- `emacs-mcp--http-validate-origin` — Origin header validation per NFR-4. Exact predicate:
  - Absent Origin → allow
  - Parse Origin as URL. If parse fails → reject HTTP 403
  - Host must be `127.0.0.1`, `localhost`, or `[::1]`. Scheme must be `http` or `https`. Any port allowed. All other Origins → reject HTTP 403
  - Called before any handler dispatch. Rejection short-circuits request processing.
- Bind address: `make-network-process :host "127.0.0.1"` (NFR-4 localhost only)
- Method routing: POST, GET, DELETE → handler functions. Other methods → HTTP 405.
- Port binding with error handling (FR-1.6)
- ERT tests: `emacs-mcp-test-http.el` (test parsing, response generation; network tests in integration)

### Phase 3: MCP Transport & Protocol

**P3.1** `emacs-mcp-transport.el` — Streamable HTTP transport
- `emacs-mcp--transport-handle-post` — Route POST per MCP Streamable HTTP spec:
  1. Parse body: single JSON-RPC message or batch array
  2. Reject `initialize` inside batch → JSON-RPC error `-32600`
  3. If body contains ONLY notifications/responses → HTTP 202 Accepted, no body
  4. If body contains requests → dispatch to protocol, return JSON or SSE
  5. Accept header is NOT validated (server is lenient per FR-1.2)
- `emacs-mcp--transport-handle-get` — Open SSE stream. Require valid `Mcp-Session-Id`: missing → HTTP 400, unknown/expired → HTTP 404. Register stream in session's `sse-streams`.
- `emacs-mcp--transport-handle-delete` — Terminate session. Require `Mcp-Session-Id`: present+valid → HTTP 200 + cleanup, missing → HTTP 400, unknown → HTTP 404.
- `emacs-mcp--transport-send-json-response` — Send `Content-Type: application/json`
- `emacs-mcp--transport-send-sse-response` — Send response as SSE `data:` event
- Session ID header management: extract `Mcp-Session-Id` from request headers, include in initialize response
- Batch request handling: detect batch array, process each message sequentially, collect responses. If ANY request triggers deferred, switch entire batch to SSE mode (immediate responses sent as events right away, deferred responses sent later).
- Deferred detection: tool handler returns symbol `deferred` → store in session's `deferred` hash, open SSE stream, start deferred timeout timer
- Deferred timeout: `run-at-time` with `emacs-mcp-deferred-timeout` seconds. On expiry, send tool execution error on SSE stream, close stream, remove deferred entry.
- Deferred reconnection: when client opens GET SSE stream, check session's `deferred` hash for completed-but-undelivered responses, deliver them on the new stream.
- ERT tests: `emacs-mcp-test-transport.el`

**P3.2** `emacs-mcp-protocol.el` — MCP method handlers
- `emacs-mcp--handle-initialize` — Version negotiation, create session, return capabilities
- `emacs-mcp--handle-initialized` — Transition session state
- `emacs-mcp--handle-ping` — Return `{}`
- `emacs-mcp--handle-tools-list` — Return all registered tools with schemas
- `emacs-mcp--handle-tools-call` — Validate, dispatch, bind dynamic vars, handle deferred
- `emacs-mcp--handle-resources-list` — Return `{"resources": []}`
- `emacs-mcp--handle-prompts-list` — Return `{"prompts": []}`
- `emacs-mcp-complete-deferred` — Public API for completing deferred responses
- Method dispatch table: method string → handler function
- ERT tests: `emacs-mcp-test-protocol.el`

### Phase 4: Built-in Tools

**P4.1** `emacs-mcp-tools-builtin.el` — All 10 built-in tools
- Each tool uses `emacs-mcp-deftool` from Phase 1
- Implementation order (by complexity, simplest first):
  1. `project-info` — Simplest: no file args, just return project-dir + active buffer
  2. `list-buffers` — Filter buffers by project-dir
  3. `open-file` — `find-file-noselect` + goto-line
  4. `get-buffer-content` — Read buffer text with optional line range
  5. `get-diagnostics` — Flymake/flycheck backend detection + diagnostic collection
  6. `imenu-symbols` — Parse imenu index, format output
  7. `xref-find-references` — xref backend call, format results
  8. `xref-find-apropos` — xref apropos search
  9. `treesit-info` — Tree-sitter node inspection
  10. `execute-elisp` — `eval` + `prin1-to-string`. **Disabled by default**: `emacs-mcp-enable-tool-execute-elisp` defaults to nil. When disabled, the tool is NOT registered in `emacs-mcp--tools`, so `tools/call` returns protocol error "Unknown tool: execute-elisp". When enabled, each invocation calls `emacs-mcp-confirm-function` before eval; if denied, returns tool execution error "User denied execution."
- Path authorization via `emacs-mcp--check-path-authorization` helper (calls `file-in-directory-p`)
- Defcustoms: `emacs-mcp-enable-tool-<name>` for each tool
- ERT tests: `emacs-mcp-test-tools-builtin.el`

### Phase 5: Integration & Entry Point

**P5.1** `emacs-mcp.el` — Main entry point
- `defgroup emacs-mcp` — Customization group
- All defcustoms: `emacs-mcp-server-port`, `emacs-mcp-project-directory`, `emacs-mcp-lockfile-directory`, `emacs-mcp-extra-lockfile-directories`, `emacs-mcp-session-timeout`, `emacs-mcp-deferred-timeout`
- `emacs-mcp-start` — Interactive command: validate port, clean stale lockfiles, start HTTP server, create lockfiles, run hooks
- `emacs-mcp-stop` — Interactive command: shut down everything, remove lockfiles, run hooks
- `emacs-mcp-restart` — Stop + start
- `emacs-mcp-mode` — Global minor mode wrapping start/stop
- `emacs-mcp-connection-info` — Return connection alist
- Hooks: `emacs-mcp-server-started-hook`, `emacs-mcp-server-stopped-hook`, `emacs-mcp-client-connected-hook`, `emacs-mcp-client-disconnected-hook`
- `kill-emacs-hook` management (add on start, remove on stop)
- Package headers, autoloads, `provide`
- **All source files** (emacs-mcp*.el) SHALL include AGPL-3.0-or-later license header per NFR-6. The main file (`emacs-mcp.el`) includes full package headers (Version, Package-Requires, URL, etc.). Library files include abbreviated license headers.
- ERT tests: `emacs-mcp-test-integration.el` — end-to-end tests covering all acceptance criteria:
  - `test-ac-01-initialize` — Start server, POST initialize, verify InitializeResult + Mcp-Session-Id header
  - `test-ac-02-tools-list` — Verify all enabled tools returned with valid inputSchema
  - `test-ac-03-project-info` — Call project-info, verify project directory in result
  - `test-ac-04-custom-tool` — Register via deftool, verify in tools/list and callable
  - `test-ac-05-concurrent-sessions` — Two sessions call tools independently
  - `test-ac-06-stop-cleanup` — Stop server, verify port released + lockfiles gone
  - `test-ac-07-lockfiles` — Verify lockfiles in all configured directories
  - `test-ac-08-byte-compile` — Run byte-compile-file on all .el files, assert no warnings
  - `test-ac-10-origin-validation` — 7 test cases: evil.com rejected, absent allowed, 127.0.0.1 allowed, localhost allowed, [::1] allowed, https localhost allowed, malformed rejected
  - `test-ac-11-execute-elisp-disabled` — With enable=nil, verify "Unknown tool" protocol error. With enable=t, verify confirm-function is called
  - `test-ac-12-string-request-id` — Send tools/call with `"id": "abc-123"`, verify exact string preserved in response
  - `test-ac-13-expired-session-404` — DELETE session, then POST with old session ID → HTTP 404
  - `test-ac-14-batch-responses` — POST batch of 2 tools/call → JSON array of 2 responses
  - `test-ac-15-readme-exists` — Assert README.org exists with required sections (string search)

### Phase 6: Documentation & CI

**P6.1** `README.org` — Per NFR-8 / AC-15
- All 9 sections from the spec
- Concrete config examples for Claude Code, Gemini CLI, Codex
- Complete `emacs-mcp-deftool` worked example

**P6.2** `.github/workflows/ci.yml`
- Emacs 29.1+ matrix
- Byte-compile check
- Checkdoc
- ERT test run

## Key Architectural Decisions

**D-1: Separate HTTP from MCP** — The HTTP layer (`emacs-mcp-http.el`) knows nothing about MCP. It accepts connections, parses HTTP, and calls handler functions. The transport layer (`emacs-mcp-transport.el`) bridges HTTP to MCP. This separation makes testing easier and allows potential future transport swaps.

**D-2: Tool registry is a global alist** — `emacs-mcp--tools` is populated at load time by `emacs-mcp-deftool` calls in `emacs-mcp-tools-builtin.el`. This is safe per FR-6.5 because it's within the package namespace. No network or hook side effects at load time.

**D-3: Session struct via cl-defstruct** — Clean, typed, efficient. Accessor functions auto-generated. Constitution allows `cl-lib` where it genuinely improves clarity.

**D-4: HTTP request accumulation** — `make-network-process` delivers data in chunks. The HTTP layer accumulates data in a process-local buffer until the full request (headers + Content-Length body) is received, then dispatches.

**D-5: SSE via raw process output** — SSE events are written directly to the network process output. No special library needed — SSE is just `data: <json>\n\n` written to the connection. The connection stays open until the stream is closed.

**D-6: Dynamic binding for deferred context** — `emacs-mcp--current-session-id` and `emacs-mcp--current-request-id` are `let`-bound during tool handler execution. This is the idiomatic Emacs Lisp approach (like `default-directory`).

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| HTTP parsing edge cases (chunked encoding, keep-alive) | Medium | High | Only support `Content-Length`, close connection after response. No keep-alive in v1. |
| Concurrent request handling (Emacs single-threaded) | Low | Medium | Requests queue naturally via event loop. Document blocking behavior in NFR-3. |
| SSE stream management (connection drops, buffering) | Medium | Medium | Sentinel functions detect disconnection. Deferred timeout as safety net. |
| UUID collision | Very Low | Low | UUID v4 with crypto-quality random. Practically impossible. |
| Port 38840 conflict with other software | Low | Low | User can change port. Clear error message on bind failure. |
| Tree-sitter not available for file type | Low | Low | Tool returns execution error, not crash. |
| Flycheck not installed | Low | Low | Flymake preferred (built-in). Flycheck is soft optional dependency. |

## Implementation Order Summary

```
Phase 1: Foundation (no network)
  P1.1 jsonrpc → P1.2 session → P1.3 tools → P1.4 confirm → P1.5 lockfile

Phase 2: HTTP Server
  P2.1 http (depends on nothing from Phase 1)

Phase 3: MCP Protocol + Transport
  P3.2 protocol (depends on: tools, session, jsonrpc) — implement FIRST
  P3.1 transport (depends on: http, jsonrpc, session, protocol) — implement SECOND

Phase 4: Built-in Tools
  P4.1 tools-builtin (depends on: tools from Phase 1)

Phase 5: Integration
  P5.1 emacs-mcp.el (depends on: everything)

Phase 6: Docs & CI
  P6.1 README.org
  P6.2 ci.yml
```

Phases 1 and 2 can be developed in parallel. Phase 3 requires both. Phase 4 only requires Phase 1. Phase 5 wires everything together. Phase 6 is independent.
