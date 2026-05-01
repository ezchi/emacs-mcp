# Tasks: 001-generic-emacs-mcp-server

## Task 1: Project Scaffolding & Core Definitions

**Description**: Create the directory structure, verify LICENSE exists (AGPL-3.0), and create stub `.el` files with correct package headers and `provide` forms. Critically, `emacs-mcp.el` must include the `defgroup`, ALL defcustoms, and ALL hook variable definitions — even though the interactive commands come later. This ensures sub-modules can reference these variables and byte-compile cleanly.

**Files to create**:
- `emacs-mcp.el` — Full package headers, `defgroup emacs-mcp`, ALL defcustoms (`emacs-mcp-server-port`, `emacs-mcp-project-directory`, `emacs-mcp-lockfile-directory`, `emacs-mcp-extra-lockfile-directories`, `emacs-mcp-session-timeout`, `emacs-mcp-deferred-timeout`), ALL hook variables (`emacs-mcp-server-started-hook`, `emacs-mcp-server-stopped-hook`, `emacs-mcp-client-connected-hook`, `emacs-mcp-client-disconnected-hook`), `emacs-mcp-connection-info` stub, and `provide`. NO interactive commands yet (those come in Task 12).
- `emacs-mcp-jsonrpc.el` (header stub, `provide`)
- `emacs-mcp-session.el` (header stub, `provide`)
- `emacs-mcp-tools.el` (header stub, `provide`)
- `emacs-mcp-confirm.el` (header stub, `provide`)
- `emacs-mcp-lockfile.el` (header stub, `provide`)
- `emacs-mcp-http.el` (header stub, `provide`)
- `emacs-mcp-protocol.el` (header stub, `provide`)
- `emacs-mcp-transport.el` (header stub, `provide`)
- `emacs-mcp-tools-builtin.el` (header stub, `provide`)
- `test/` directory

**Dependencies**: None

**Verification**:
- All `.el` files have AGPL-3.0 license headers per NFR-6
- `emacs-mcp.el` has full package headers (Version, Package-Requires, URL)
- `emacs-mcp.el` defines defgroup, all 6 defcustoms, all 4 hook variables
- `Package-Requires` contains only `((emacs "29.1"))` — no external deps (NFR-2)
- All files byte-compile without warnings (stubs should compile clean)
- `(require 'emacs-mcp)` loads without error and without side effects (FR-6.5) — no network calls, no hooks installed, no global state modified

---

## Task 2: JSON-RPC 2.0 Layer (`emacs-mcp-jsonrpc.el`)

**Description**: Implement the JSON-RPC 2.0 message parsing, response construction, and error handling. This is the lowest-level protocol layer — pure data transformation, no network, no MCP knowledge.

**Files to create/modify**:
- `emacs-mcp-jsonrpc.el` — Full implementation
- `test/emacs-mcp-test-jsonrpc.el` — ERT tests

**Functions to implement**:
- `emacs-mcp--jsonrpc-parse` — Parse JSON string into alist(s); detect single vs batch
- `emacs-mcp--jsonrpc-batch-p` — Predicate: is parsed JSON a batch array?
- `emacs-mcp--jsonrpc-request-p` — Predicate: has `method` and `id`
- `emacs-mcp--jsonrpc-notification-p` — Predicate: has `method`, no `id`
- `emacs-mcp--jsonrpc-response-p` — Predicate: has `result` or `error`, and `id`
- `emacs-mcp--jsonrpc-make-response` — Build `{jsonrpc: "2.0", id: ..., result: ...}`
- `emacs-mcp--jsonrpc-make-error` — Build `{jsonrpc: "2.0", id: ..., error: {code, message, data}}`
- `emacs-mcp--jsonrpc-serialize` — Serialize alist to JSON string
- Error code constants: `-32700`, `-32600`, `-32601`, `-32602`, `-32603`

**Dependencies**: Task 1

**Verification**:
- Parse valid single request, notification, response
- Parse valid batch array
- Reject malformed JSON with parse error
- `make-response` produces correct structure with exact `id` preservation (string or number)
- `make-error` produces correct error object with code, message, data
- Batch predicate correctly identifies arrays vs single objects
- Null `id` in requests can be detected (for later rejection at protocol layer)
- All tests pass via `ert-run-tests-batch`
- File byte-compiles clean

---

## Task 3: Session Management (`emacs-mcp-session.el`)

**Description**: Implement session lifecycle: creation with UUID v4, lookup, activity tracking, idle timeout, and cleanup. Sessions are the core state container for connected clients.

**Files to create/modify**:
- `emacs-mcp-session.el` — Full implementation
- `test/emacs-mcp-test-session.el` — ERT tests

**Functions/structures to implement**:
- `cl-defstruct emacs-mcp-session` — Fields: session-id, client-info, project-dir, state, connected-at, last-activity, deferred (hash-table), sse-streams, **timer** (the idle timeout timer handle — needed for cancellation on activity reset and session removal)
- `emacs-mcp--sessions` — Global hash-table of active sessions
- `emacs-mcp--generate-uuid` — UUID v4 from `/dev/urandom` per RFC 4122
- `emacs-mcp--session-create` — Create session, store in `emacs-mcp--sessions`, start idle timer
- `emacs-mcp--session-get` — Lookup by ID
- `emacs-mcp--session-remove` — Remove by ID, **cancel idle timer**, close SSE streams, run `emacs-mcp-client-disconnected-hook` with `run-hook-with-args` passing session ID
- `emacs-mcp--session-update-activity` — Touch `last-activity` timestamp, **cancel and restart idle timer**
- `emacs-mcp--session-start-timeout-timer` — Create idle timer via `run-at-time` using `emacs-mcp-session-timeout`; store handle in session's `timer` field
- `emacs-mcp--session-cleanup-all` — Remove all sessions (cancel all timers, close all SSE streams)
- `emacs-mcp--resolve-project-dir` — Implement FR-4.2 fallback: (1) `emacs-mcp-project-directory` if non-nil, (2) `(project-root (project-current))` if available, (3) `default-directory`. Called at server start, result passed into all new sessions.

**Dependencies**: Task 1

**Verification**:
- UUID v4 format is correct (version nibble = 4, variant bits = 10xx)
- Session create/get/remove lifecycle works
- Activity update cancels old timer and starts new one
- Timer handle stored in session struct, cancelled on removal
- Timeout fires after configured seconds of inactivity, removes session
- `session-cleanup-all` cancels all timers and removes all sessions
- `emacs-mcp-client-disconnected-hook` called via `run-hook-with-args` with session ID on removal
- `emacs-mcp--resolve-project-dir` tested with all 3 fallback cases:
  - Returns defcustom value when non-nil
  - Returns `project-root` when defcustom is nil and project detected
  - Returns `default-directory` when both are nil/unavailable
- No `/dev/urandom` on non-Unix signals `user-error`
- All tests pass; file byte-compiles clean

---

## Task 4: Confirmation Policy (`emacs-mcp-confirm.el`)

**Description**: Implement the confirmation mechanism for dangerous tools. Small module — defcustom, default confirm function, and a helper that checks whether a tool needs confirmation.

**Files to create/modify**:
- `emacs-mcp-confirm.el` — Full implementation
- `test/emacs-mcp-test-confirm.el` — ERT tests

**Functions to implement**:
- `emacs-mcp-confirm-function` — defcustom, default `#'emacs-mcp-default-confirm`
- `emacs-mcp-default-confirm` — `y-or-n-p` prompt with tool name and args summary
- `emacs-mcp--maybe-confirm` — If tool has `:confirm`, call `emacs-mcp-confirm-function`; return t to proceed, nil to deny

**Dependencies**: Task 1

**Verification**:
- Default confirm function prompts with tool name
- Setting `emacs-mcp-confirm-function` to `#'always` bypasses prompts
- Setting to `#'ignore` denies all
- `emacs-mcp--maybe-confirm` returns t for non-confirm tools without calling function
- File byte-compiles clean; all tests pass

---

## Task 5: Tool Registry Framework (`emacs-mcp-tools.el`)

**Description**: Implement the tool registration system: the `emacs-mcp-deftool` macro, programmatic `register/unregister` functions, JSON Schema generation from parameter declarations, argument validation, result wrapping, and tool dispatch with confirmation integration.

**Files to create/modify**:
- `emacs-mcp-tools.el` — Full implementation
- `test/emacs-mcp-test-tools.el` — ERT tests

**Functions/macros to implement**:
- `emacs-mcp--tools` — Global alist: `((name . tool-entry) ...)`
- `emacs-mcp-deftool` — Macro: define handler function, register tool
- `emacs-mcp-register-tool` — Programmatic registration with `:name`, `:description`, `:params`, `:handler`, `:confirm`
- `emacs-mcp-unregister-tool` — Remove tool by name, error if not found
- `emacs-mcp--tool-input-schema` — Generate JSON Schema object from param plists (FR-2.2 type mapping)
- `emacs-mcp--validate-tool-args` — Validate required args present + type checking (FR-2.7)
- `emacs-mcp--wrap-tool-result` — Wrap handler return into `CallToolResult` (string -> text content, list -> as-is, error -> isError) (FR-2.6)
- `emacs-mcp--dispatch-tool` — Find tool, validate args, check confirmation (calls `emacs-mcp--maybe-confirm` from Task 4), call handler, wrap result. Bind `emacs-mcp--current-session-id` and `emacs-mcp--current-request-id` during execution (FR-5.1)
- `emacs-mcp--current-session-id` / `emacs-mcp--current-request-id` — Dynamic variables for deferred context

**Dependencies**: Tasks 1, 2 (jsonrpc for schema serialization context), 4 (confirm for `emacs-mcp--maybe-confirm`)

**Verification**:
- `deftool` registers a tool callable by name
- `register-tool` programmatic API equivalent to `deftool`
- `unregister-tool` removes; error on unknown tool
- JSON Schema generation: all 6 types (string, integer, number, boolean, array, object)
- Schema has `type: "object"`, `properties`, `required` fields
- Arg validation: missing required -> error `-32602`, wrong type -> error `-32602`, unknown tool -> error `-32602`
- Null values accepted for optional arguments
- Result wrapping: string return, list return, error signal
- Confirmation integration: tool with `:confirm t` calls `emacs-mcp-confirm-function`; denied returns tool execution error "User denied execution."
- `deferred` symbol return detected (not wrapped)
- Dynamic variables bound during handler execution
- All tests pass; file byte-compiles clean

---

## Task 6: Lockfile Management (`emacs-mcp-lockfile.el`)

**Description**: Implement lockfile creation, removal, and stale lockfile cleanup. Lockfiles are JSON files that let MCP clients discover running servers.

**Files to create/modify**:
- `emacs-mcp-lockfile.el` — Full implementation
- `test/emacs-mcp-test-lockfile.el` — ERT tests

**Functions to implement**:
- `emacs-mcp--lockfile-path` — Compute `<dir>/<port>.lock` path
- `emacs-mcp--lockfile-create` — Write JSON lockfile (pid, port, workspaceFolders, serverName, transport) to one directory
- `emacs-mcp--lockfile-create-all` — Write to `emacs-mcp-lockfile-directory` + all `emacs-mcp-extra-lockfile-directories`
- `emacs-mcp--lockfile-remove` — Delete lockfile from one directory
- `emacs-mcp--lockfile-remove-all` — Delete from primary + all extra directories
- `emacs-mcp--lockfile-cleanup-stale` — Scan all lockfile directories, read PID from each `.lock` file, remove if process dead (via `process-attributes`)

**Dependencies**: Task 1

**Verification**:
- Lockfile contains valid JSON with correct fields (pid, port, workspaceFolders, serverName, transport)
- Create writes to correct path; remove deletes it
- `create-all` writes to multiple directories
- `remove-all` deletes from all directories
- Stale cleanup removes lockfiles for dead PIDs, leaves alive PIDs
- Missing lockfile directory is created automatically
- All tests pass; file byte-compiles clean

---

## Task 7: HTTP Server (`emacs-mcp-http.el`)

**Description**: Implement the low-level HTTP/1.1 server using `make-network-process`. Handles TCP connection accept, request accumulation (chunked data from `make-network-process`), HTTP parsing, response writing, SSE streaming, and Origin validation. Knows nothing about MCP — just HTTP.

**Files to create/modify**:
- `emacs-mcp-http.el` — Full implementation
- `test/emacs-mcp-test-http.el` — ERT tests

**Functions to implement**:
- `emacs-mcp--http-start` — Create TCP server on `127.0.0.1:<port>`, return server process. Accept `:handler` callback for dispatching parsed requests.
- `emacs-mcp--http-stop` — Close server process and all client connections
- `emacs-mcp--http-filter` — Process filter: accumulate data in process-local buffer, detect complete request (headers + Content-Length body), dispatch
- `emacs-mcp--http-parse-request` — Parse accumulated bytes into `(method path http-version headers body)`
- `emacs-mcp--http-send-response` — Write HTTP response: status line, headers, body
- `emacs-mcp--http-send-sse-headers` — Write SSE response headers (`Content-Type: text/event-stream`, keep connection open)
- `emacs-mcp--http-send-sse-event` — Write `data: <payload>\n\n`
- `emacs-mcp--http-close-connection` — Close client connection process
- `emacs-mcp--http-validate-origin` — Origin header validation per NFR-4
- Connection sentinel for detecting client disconnects

**Dependencies**: Task 1

**Verification**:
- Server starts on configured port, accepts TCP connections
- Request accumulation works with fragmented data (multiple filter calls)
- Parse correctly extracts method, path, headers, body
- Response writing produces valid HTTP/1.1
- SSE events are correctly formatted (`data: ...\n\n`)
- Origin validation: absent -> allow, `http://127.0.0.1:PORT` -> allow, `http://localhost` -> allow, `http://[::1]:PORT` -> allow, `https://localhost:443` -> allow, `http://evil.com` -> 403, malformed -> 403
- Unsupported HTTP methods -> 405
- Path not `/mcp` -> 404
- All tests pass; file byte-compiles clean

---

## Task 8: MCP Protocol Handlers (`emacs-mcp-protocol.el`)

**Description**: Implement the MCP method dispatch and handlers. Each handler receives a parsed JSON-RPC request and returns a JSON-RPC response (or nil for notifications). The protocol layer knows MCP semantics but NOT HTTP — it works with parsed data structures.

**Files to create/modify**:
- `emacs-mcp-protocol.el` — Full implementation
- `test/emacs-mcp-test-protocol.el` — ERT tests

**Functions to implement**:
- `emacs-mcp--protocol-dispatch` — Look up method in dispatch table, call handler. Unknown method -> error `-32601`.
- `emacs-mcp--handle-initialize` — Create session, return `InitializeResult` with capabilities (FR-1.4). Version negotiation: always respond with `2025-03-26`. Run `emacs-mcp-client-connected-hook` via `run-hook-with-args` with session ID.
- `emacs-mcp--handle-initialized` — Transition session to `ready` state. Return nil (notification).
- `emacs-mcp--handle-ping` — Return `{}`
- `emacs-mcp--handle-tools-list` — Return all registered (enabled) tools with inputSchema
- `emacs-mcp--handle-tools-call` — Validate tool name/args, bind dynamic vars, dispatch, detect deferred. Reject null request IDs.
- `emacs-mcp--handle-resources-list` — Return `{"resources": []}`
- `emacs-mcp--handle-prompts-list` — Return `{"prompts": []}`
- `emacs-mcp-complete-deferred` — Public function: complete a deferred response (FR-5.3)
- `emacs-mcp--method-dispatch-table` — Alist: method string -> handler function

**Dependencies**: Tasks 2, 3, 4, 5

**Verification**:
- `initialize` returns correct capabilities, protocol version, server info
- `initialize` runs `emacs-mcp-client-connected-hook` via `run-hook-with-args` with session ID
- `initialized` transitions session state to `ready`
- `ping` returns `{}`
- `tools/list` returns all registered tools with valid schemas
- `tools/call` dispatches correctly, returns `CallToolResult`
- `tools/call` with unknown tool -> error `-32602`
- `tools/call` with missing required arg -> error `-32602`
- `tools/call` with null request ID -> error `-32600`
- `tools/call` preserves string and number request IDs exactly
- Unknown method -> error `-32601`
- `resources/list` and `prompts/list` return empty arrays
- `complete-deferred` resolves pending deferred response
- All tests pass; file byte-compiles clean

---

## Task 9: Streamable HTTP Transport (`emacs-mcp-transport.el`)

**Description**: Bridge the HTTP server (Task 7) to the MCP protocol handlers (Task 8). Implements MCP Streamable HTTP transport: POST/GET/DELETE routing, session ID header management, batch handling, SSE stream lifecycle, and deferred response delivery.

**Files to create/modify**:
- `emacs-mcp-transport.el` — Full implementation
- `test/emacs-mcp-test-transport.el` — ERT tests

**Functions to implement**:
- `emacs-mcp--transport-handle-request` — Top-level handler called by HTTP server; routes by HTTP method to POST/GET/DELETE handlers
- `emacs-mcp--transport-validate-session` — Extract and validate `Mcp-Session-Id` header (missing -> 400, syntactically invalid -> 400, unknown/expired/terminated -> 404)
- `emacs-mcp--transport-handle-post` — Parse body, handle single/batch, route initialize specially (no session required), handle notifications-only (-> 202), dispatch requests, choose JSON vs SSE response mode
- `emacs-mcp--transport-handle-get` — Validate session, open SSE stream, register in session's `sse-streams`, deliver pending deferred responses
- `emacs-mcp--transport-handle-delete` — Validate session, clean up, return 200
- `emacs-mcp--transport-send-json` — Send single JSON response with `Mcp-Session-Id` header
- `emacs-mcp--transport-send-json-batch` — Send JSON array of responses
- `emacs-mcp--transport-open-sse-stream` — Send SSE headers, keep connection open
- `emacs-mcp--transport-send-sse-event` — Send JSON-RPC response as SSE `data:` event
- `emacs-mcp--transport-handle-deferred` — Store deferred entry, start timeout timer via `run-at-time` using `emacs-mcp-deferred-timeout`
- Batch handling: initialize in batch -> error `-32600`; mixed deferred/immediate -> SSE mode

**Dependencies**: Tasks 2, 3, 7, 8

**Verification**:
- POST with `initialize` creates session, returns `Mcp-Session-Id` header
- POST with valid session calls protocol dispatch
- POST without session header (non-initialize) -> 400
- POST with syntactically invalid `Mcp-Session-Id` -> 400
- POST with unknown/expired session -> 404
- POST with notifications-only -> 202 Accepted, no body
- POST with batch of 2 requests -> JSON array of 2 responses
- POST with `initialize` inside batch -> error `-32600`
- POST with missing/unexpected `Accept` header still processes correctly (server is lenient, FR-1.2)
- POST with batch containing mixed immediate + deferred -> SSE mode, immediate responses sent first, deferred sent when completed, stream closes after all delivered
- GET opens SSE stream for valid session
- GET without session -> 400
- GET with unknown session -> 404
- DELETE terminates session -> 200, subsequent POST -> 404
- DELETE with unknown session -> 404
- Deferred tool: POST returns SSE, completion delivers response, stream closes
- Deferred timeout: sends error after configured seconds
- All tests pass; file byte-compiles clean

---

## Task 10: Built-in Tools — Buffer & File Operations (`emacs-mcp-tools-builtin.el`, part 1)

**Description**: Implement the shared path-authorization helper, tool enable/disable defcustoms, and the simpler built-in tools that deal with buffers and files.

**Files to create/modify**:
- `emacs-mcp-tools-builtin.el` — Partial implementation (tools 1-4)
- `test/emacs-mcp-test-tools-builtin.el` — ERT tests for tools 1-4 + shared helpers

**Shared helpers to implement**:
- `emacs-mcp--check-path-authorization` — Verify path is within session's project-dir via `file-in-directory-p`. Reads project-dir from session via `emacs-mcp--current-session-id`. Signals error "Path outside project directory: <path>" on failure.
- `emacs-mcp-enable-tool-<name>` — Defcustoms for ALL 10 tools (all default `t` except `execute-elisp` which defaults to `nil`)

**Tools to implement**:
1. `project-info` — Return project-dir, active buffer, file count (FR-3.3). Uses session's project-dir, NOT global `project-current`.
2. `list-buffers` — Return project buffers as JSON array (FR-3.9). Filters by session's project-dir (FR-4.4).
3. `open-file` — Open file with optional line/selection (FR-3.7). Path authorization check.
4. `get-buffer-content` — Return buffer text with optional range (FR-3.8). Path authorization check.

**Dependencies**: Tasks 3, 4, 5

**Verification**:
- Path authorization rejects paths outside project-dir with tool execution error
- Path authorization accepts paths inside project-dir
- `project-info` returns valid JSON with projectDir matching session's project-dir
- `list-buffers` returns only buffers in session's project-dir
- `open-file` opens file and returns "FILE_OPENED"; rejects outside paths
- `get-buffer-content` returns correct text/range; rejects outside paths
- All 10 enable defcustoms exist with correct defaults
- Disabled tool not in registry (when checked via tools/list)
- All tests pass; file byte-compiles clean

---

## Task 11: Built-in Tools — Introspection, Diagnostics & Execute (`emacs-mcp-tools-builtin.el`, part 2)

**Description**: Implement the remaining 6 built-in tools: introspection (imenu, xref, treesit), diagnostics, and execute-elisp.

**Files to create/modify**:
- `emacs-mcp-tools-builtin.el` — Complete implementation (tools 5-10)
- `test/emacs-mcp-test-tools-builtin.el` — ERT tests for tools 5-10

**Tools to implement**:
5. `get-diagnostics` — Flymake/flycheck diagnostics as JSON array (FR-3.6). Auto-detect backend: prefer flymake, fall back to flycheck (soft dependency via `(require 'flycheck nil t)`), else empty. Flycheck is optional — guard with runtime detection.
6. `imenu-symbols` — Parse imenu index for file (FR-3.4). Path authorization check. Format: `category: name (line N)`.
7. `xref-find-references` — Find references via xref backend (FR-3.1). Optional file param for buffer context. Path authorization check.
8. `xref-find-apropos` — Search symbols matching pattern (FR-3.2). Results scoped to project-dir where possible.
9. `treesit-info` — Tree-sitter node inspection (FR-3.5). Path authorization check. Error if no tree-sitter for file type.
10. `execute-elisp` — Eval expression with confirmation (FR-3.10). **Disabled by default** (`emacs-mcp-enable-tool-execute-elisp` = nil). When disabled, not registered — `tools/call` returns "Unknown tool". When enabled, calls `emacs-mcp-confirm-function` before eval; denied returns "User denied execution."

**Dependencies**: Tasks 3, 4, 5, 10

**Verification**:
- `get-diagnostics` with flymake returns diagnostics in correct JSON format (file, line, column, severity, message, source)
- `get-diagnostics` without flymake/flycheck returns empty array
- `imenu-symbols` returns `category: name (line N)` format; rejects outside paths
- `xref-find-references` returns `file:line: summary` entries or "No references found."
- `xref-find-apropos` returns matching symbols with locations
- `treesit-info` with tree-sitter file returns node info; without returns error
- `execute-elisp` disabled: not in tools registry, tools/call returns "Unknown tool"
- `execute-elisp` enabled + confirm allowed: evaluates and returns `prin1-to-string` result
- `execute-elisp` enabled + confirm denied: returns "User denied execution."
- All tests pass; file byte-compiles clean

---

## Task 12: Main Entry Point & Integration (`emacs-mcp.el`)

**Description**: Add interactive commands (`start`/`stop`/`restart`), `emacs-mcp-mode` global minor mode, and `emacs-mcp-connection-info` to `emacs-mcp.el` (which already has defgroup/defcustoms/hooks from Task 1). Wire all modules together. Write integration tests covering all acceptance criteria.

**Files to create/modify**:
- `emacs-mcp.el` — Add interactive commands, minor mode, require statements for all sub-modules
- `test/emacs-mcp-test-integration.el` — End-to-end ERT tests

**Commands to implement**:
- `emacs-mcp-start` — Interactive, `;;;###autoload`. Validate port (FR-1.6 runtime validation), resolve project-dir via `emacs-mcp--resolve-project-dir`, clean stale lockfiles, start HTTP with transport handler, create lockfiles, run `emacs-mcp-server-started-hook` via `run-hook-with-args` with port. Idempotent (FR-6.1).
- `emacs-mcp-stop` — Interactive, `;;;###autoload`. Stop HTTP, cleanup all sessions (cancels all timers), remove all lockfiles, run `emacs-mcp-server-stopped-hook` via `run-hooks`. Remove `kill-emacs-hook`.
- `emacs-mcp-restart` — Interactive, `;;;###autoload`. Stop + start.
- `emacs-mcp-mode` — Global minor mode. Enable -> start, disable -> stop. Add/remove `kill-emacs-hook`.
- `emacs-mcp-connection-info` — Return alist with `:port`, `:host`, `:url`, `:lockfile`.

**Integration tests** (AC-1 through AC-15):
- AC-1: POST initialize -> valid InitializeResult + Mcp-Session-Id header
- AC-2: tools/list returns all enabled tools with valid inputSchema
- AC-3: tools/call project-info returns project directory
- AC-4: Custom tool via deftool appears in tools/list and callable
- AC-5: Two concurrent sessions work independently
- AC-6: Stop cleans up port + lockfiles
- AC-7: Lockfiles in all configured directories
- AC-8: Byte-compile all .el files with zero warnings
- AC-10: Origin validation (7 test cases per spec)
- AC-11: execute-elisp enabled/disabled behavior
- AC-12: String request ID preserved exactly
- AC-13: Terminated session -> 404
- AC-14: Batch of 2 tools/call -> JSON array of 2 responses
- AC-15: README.org exists with required sections (deferred to Task 13)
- Hook argument tests: `emacs-mcp-server-started-hook` receives port, `emacs-mcp-client-connected-hook` receives session ID, `emacs-mcp-client-disconnected-hook` receives session ID

**Dependencies**: Tasks 2, 3, 4, 5, 6, 7, 8, 9, 10, 11

**Verification**:
- `M-x emacs-mcp-start` starts server, `M-x emacs-mcp-stop` stops it
- `emacs-mcp-mode` toggles server
- `emacs-mcp-connection-info` returns correct alist
- All hooks fire at correct times WITH correct arguments (not just correct times)
- `kill-emacs-hook` added on start, removed on stop
- `(require 'emacs-mcp)` has no side effects (NFR-7)
- All AC-1 through AC-14 integration tests pass
- File byte-compiles clean

---

## Task 13: README.org Documentation

**Description**: Write comprehensive README.org per NFR-8. Org-mode format, consistent with Emacs ecosystem conventions.

**Files to create**:
- `README.org`

**Sections** (per spec):
1. Installation (MELPA, manual)
2. Quick Start (`emacs-mcp-mode`, `M-x emacs-mcp-start`)
3. Configuration (all defcustoms reference)
4. Connecting LLM Agents (Claude Code `.claude/settings.json`, Gemini CLI, Codex CLI, generic curl walkthrough showing full initialize -> tools/list -> tools/call MCP flow)
5. Built-in Tools (table: name, description, parameters)
6. Adding Custom Tools (`emacs-mcp-deftool` examples, `emacs-mcp-register-tool`, `emacs-mcp-unregister-tool`, type mapping, return conventions, complete worked example)
7. Lockfile Discovery
8. Security (Origin validation, path authorization, confirmation, execute-elisp)
9. License (AGPL-3.0-or-later)

**Dependencies**: Task 12 (needs final API surface for accurate docs)

**Verification**:
- README.org exists at project root
- Contains all 9 required sections
- Claude Code config example is valid JSON
- `emacs-mcp-deftool` example is syntactically correct Elisp
- AC-15 integration test passes (search for required section headings)

---

## Task 14: CI Configuration

**Description**: Create GitHub Actions CI workflow for automated testing on push/PR.

**Files to create**:
- `.github/workflows/ci.yml`

**CI steps**:
- Matrix: Emacs 29.1, 29.4, 30.1 (latest stable versions)
- Install Emacs via `purcell/setup-emacs` action
- Byte-compile all `.el` files with warnings enabled
- Run checkdoc on all public symbols
- Run ERT test suite

**Dependencies**: Task 12

**Verification**:
- Workflow YAML is valid
- Matrix covers Emacs 29.1+
- All three checks (byte-compile, checkdoc, ERT) are present
- AC-8 alignment: byte-compile with zero warnings

---

## Task 15: Final Validation & Polish

**Description**: Run the complete validation suite. Fix any byte-compile warnings, checkdoc issues, and failing tests. Ensure all acceptance criteria pass end-to-end.

**Files to modify**: Any files with issues

**Checks**:
- Byte-compile all `.el` files with `byte-compile-warnings` set to `t` — zero warnings
- Run `checkdoc` on all public symbols — zero issues
- Run full ERT test suite — all tests pass
- Verify `(require 'emacs-mcp)` completes in <50ms (NFR-1)
- Verify no global state pollution (NFR-7)
- Review all defcustoms have `:type`, `:group`, `:safe` where required
- Verify `Package-Requires` contains only `((emacs "29.1"))` — no external deps (NFR-2)
- Verify optional flycheck dependency is guarded with `(require 'flycheck nil t)` or `(featurep 'flycheck)` runtime detection only

**Dependencies**: Tasks 1-14

**Verification**:
- AC-8: Zero byte-compile warnings, all public symbols pass checkdoc
- AC-9: All unit test categories exist and pass
- All AC-1 through AC-15 pass
- Package is ready for MELPA submission

---

## Dependency Graph

```
Task 1 (scaffolding + core definitions)
├── Task 2 (jsonrpc)             — no other deps
├── Task 3 (session)             — no other deps
├── Task 4 (confirm)             — no other deps
├── Task 6 (lockfile)            — no other deps
└── Task 7 (http)                — no other deps

Task 5 (tools) ← Tasks 2, 4
Task 8 (protocol) ← Tasks 2, 3, 4, 5
Task 9 (transport) ← Tasks 2, 3, 7, 8
Task 10 (builtin tools part 1) ← Tasks 3, 4, 5
Task 11 (builtin tools part 2) ← Tasks 3, 4, 5, 10
Task 12 (entry point + integration) ← Tasks 2-11
Task 13 (README) ← Task 12
Task 14 (CI) ← Task 12
Task 15 (validation) ← Tasks 1-14
```

## Parallel Execution Opportunities

- **Parallel group A** (after Task 1): Tasks 2, 3, 4, 6, 7 — all independent leaf modules
- **Parallel group B** (after group A completes): Task 5 (needs 2, 4), Task 8 (needs 2, 3, 4, 5 — so starts once 5 is done)
- **Parallel group C** (after group B): Tasks 9 (needs 7, 8), 10 (needs 3, 4, 5)
- **Sequential**: Task 11 after Task 10, Task 12 after all, Tasks 13+14 in parallel after 12, Task 15 last
