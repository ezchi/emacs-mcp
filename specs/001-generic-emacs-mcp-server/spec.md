# Specification: Generic Emacs MCP Server

**Spec ID**: 001-generic-emacs-mcp-server
**Date**: 2026-04-26
**Status**: Draft (Iteration 5)

## Overview

Both `claude-code-ide.el` and `gemini-cli-ide` implement nearly identical MCP (Model Context Protocol) server infrastructure inside Emacs. Each package duplicates:

- An HTTP-based MCP server for tool exposure
- JSON-RPC 2.0 message handling and dispatch
- Tool registration, schema generation, and argument validation
- Session management (per-project, with lockfile discovery)
- Emacs tools: xref, imenu, tree-sitter, project-info, diagnostics
- Deferred response patterns for async tools

The only differences are client-specific coupling: symbol prefixes (`claude-code-ide-` vs `gemini-cli-ide-`), lockfile paths (`~/.claude/ide/` vs `~/.gemini/ide/`), environment variables, and terminal/CLI management.

**`emacs-mcp` extracts the shared MCP server and Emacs tool layer into a standalone package.** Users start one MCP server from Emacs; any MCP-capable LLM agent (Claude Code, Gemini CLI, Copilot, custom agents) connects to it. The client-specific packages become thin wrappers that depend on `emacs-mcp` for MCP functionality and add only their own CLI/terminal management.

### Relationship to Existing Packages

`emacs-mcp` is a standalone package. It works independently — users can start the MCP server and connect any MCP client. Client-specific packages (`claude-code-ide.el`, `gemini-cli-ide`) MAY depend on `emacs-mcp` to eliminate their duplicated MCP code, or MAY continue to use their own embedded implementations. This decision is left to each client package's maintainer. `emacs-mcp` does NOT depend on or reference any client package.

## User Stories

**US-1**: As an Emacs user, I want to start a single MCP server so that multiple LLM agents can access my Emacs environment simultaneously without requiring separate server instances per agent.

**US-2**: As an Emacs user, I want to expose Emacs capabilities (xref, imenu, tree-sitter, diagnostics, file operations) as MCP tools so that any MCP-compatible agent can use them.

**US-3**: As a package author integrating a new LLM CLI with Emacs, I want to depend on `emacs-mcp` for MCP server functionality so that I only need to implement CLI/terminal management, not the entire MCP stack.

**US-4**: As an Emacs user, I want to register custom MCP tools via Emacs Lisp so that I can extend what agents can do in my environment.

**US-5**: As an Emacs user, I want the MCP server to handle concurrent connections from multiple clients so that I can run Claude Code and Gemini CLI side by side against the same Emacs instance.

**US-6**: As an Emacs user, I want a confirmation prompt for dangerous tool calls so that agents cannot perform destructive actions without my explicit approval.

## Functional Requirements

### FR-1: MCP Server Core

**FR-1.1**: The package SHALL implement an MCP server compliant with MCP protocol version `2025-03-26`.

**FR-1.2**: The server SHALL implement the **Streamable HTTP** transport as defined in the MCP `2025-03-26` specification. Specifically:

- The server SHALL expose a single MCP endpoint (e.g., `http://127.0.0.1:PORT/mcp`) that accepts HTTP POST, GET, and DELETE methods.
- **POST**: Accepts a single JSON-RPC message OR a JSON-RPC batch array per the MCP `2025-03-26` base protocol (which requires implementations MUST support receiving batches). The `initialize` request MUST NOT appear in a batch (per MCP spec); if it does, the server SHALL return a JSON-RPC error with code `-32600`.
  - If the input consists solely of notifications and/or responses, the server SHALL return HTTP 202 Accepted with no body.
  - If the input contains one or more requests, the server SHALL return either `Content-Type: application/json` (single JSON response or JSON array of responses for batch) or `Content-Type: text/event-stream` (SSE stream). The server chooses SSE when any response may be deferred or when server-initiated messages are needed.
  - For batch requests: if NO request in the batch triggers a deferred response, the server SHALL return `Content-Type: application/json` with a JSON array of responses (one per request; notifications produce no response). If ANY request in the batch triggers a deferred response, the server SHALL return `Content-Type: text/event-stream` (SSE) and deliver each response as a separate SSE `data:` event — immediate responses are sent right away, deferred responses are sent when they complete. The stream closes after all responses have been delivered or timed out.
- The server SHALL NOT reject requests based on the `Accept` header. Per MCP, clients MUST send appropriate `Accept` headers, but the server is lenient: if the header is missing or unexpected, the server still responds with the appropriate content type for the operation.
- **GET**: Opens an SSE stream for server-to-client messages (notifications, requests). The server SHALL return `Content-Type: text/event-stream`. The GET request MUST include a valid `Mcp-Session-Id` header; requests with missing session ID receive HTTP 400, unknown/expired session ID receives HTTP 404. The server uses this stream for server-initiated messages and for redelivering deferred responses after client reconnection (FR-5.5).
- **DELETE**: Terminates the session identified by the `Mcp-Session-Id` header. Returns HTTP 200 on success, HTTP 404 if the session does not exist.

**FR-1.3**: The server SHALL support multiple concurrent client sessions. Each session is identified by a unique, cryptographically random session ID (UUID v4).

**FR-1.4**: The server SHALL implement the following MCP methods:
- `initialize` — Return server capabilities, protocol version, and server info. The response SHALL include `Mcp-Session-Id` header. Server capabilities SHALL declare `tools: { listChanged: false }`, `resources: {}`, and `prompts: {}`. **Version negotiation**: The server supports protocol version `2025-03-26`. If the client requests this version, the server responds with the same version. If the client requests a different version, the server responds with `2025-03-26` (the only version it supports). If the client cannot work with this version, it should disconnect per MCP spec.
- `notifications/initialized` — Handle as a JSON-RPC notification: transition session state from "initializing" to "ready." The server MUST NOT send a JSON-RPC response for this notification (per JSON-RPC 2.0 spec).
- `ping` — Respond with an empty result `{}`. Required by MCP: any party that receives a ping MUST respond.
- `tools/list` — Return all registered tools with JSON Schema `inputSchema` objects. In v1, all tools are returned in a single response with no `nextCursor` (pagination not needed for the expected tool count). The `cursor` parameter in the request is accepted but ignored.
- `tools/call` — Execute a tool by name with provided arguments. Return a `CallToolResult` object.
- `resources/list` — Return registered resources. In v1, returns `{"resources": []}` (empty array, no `nextCursor`). The `cursor` parameter is accepted but ignored.
- `prompts/list` — Return registered prompts. In v1, returns `{"prompts": []}` (empty array, no `nextCursor`). The `cursor` parameter is accepted but ignored.

**FR-1.5**: The server SHALL bind to `127.0.0.1` only. No remote connections.

**FR-1.6**: The server port SHALL be configurable via `emacs-mcp-server-port` (defcustom, default `38840`). Type: `(choice (const :tag "Auto-select" nil) (integer :tag "Fixed port"))`. `:safe` predicate: `(lambda (v) (or (null v) (and (integerp v) (<= 1 v 65535))))` (controls file-local variable safety). **Runtime validation**: `emacs-mcp-start` SHALL validate the port value before attempting to bind. If the value is non-nil and not an integer in range 1-65535, signal `user-error`: `"emacs-mcp: invalid port %S (must be nil or 1-65535)"`. If nil, auto-select an available port using port 0. If a valid fixed port is configured but cannot be bound (port in use, permission denied, etc.), `emacs-mcp-start` SHALL signal `user-error`: `"emacs-mcp: cannot bind to port %d: %s"` with the port number and the system error message.

**FR-1.7**: The server SHALL create a lockfile at `~/.emacs-mcp/{PORT}.lock` containing JSON metadata:
```json
{
  "pid": 12345,
  "port": 8080,
  "workspaceFolders": ["/path/to/project"],
  "serverName": "emacs-mcp",
  "transport": "streamable-http"
}
```
The lockfile directory is configurable via `emacs-mcp-lockfile-directory` (defcustom, default `"~/.emacs-mcp"`). On startup, before creating a new lockfile, `emacs-mcp-start` SHALL check for existing lockfiles in all lockfile directories. For each existing lockfile, read the PID and verify whether the process is still alive (via `process-attributes`). If the process is dead, remove the stale lockfile.

**FR-1.8**: The HTTP server SHALL be implemented using Emacs's built-in `make-network-process` with manual HTTP request/response handling. No external HTTP server dependency.

### FR-2: Tool Registration Framework

**FR-2.1**: The package SHALL provide a public macro `emacs-mcp-deftool` for declaring MCP tools:
```elisp
(emacs-mcp-deftool my-tool-name
  "Human-readable description of the tool."
  (( :name "param1"
     :type string
     :description "A required string parameter"
     :required t)
   ( :name "param2"
     :type boolean
     :description "An optional boolean parameter"
     :required nil))
  (lambda (args)
    ;; ARGS is an alist: (("param1" . "value") ("param2" . t))
    ;; Return a string or a list of content objects.
    (alist-get "param1" args nil nil #'string=)))

;; With :confirm — prompts user before execution:
(emacs-mcp-deftool dangerous-tool
  "A tool that requires user confirmation."
  (( :name "expression" :type string :description "..." :required t))
  (lambda (args) (eval (read (alist-get "expression" args nil nil #'string=))))
  :confirm t)
```

The macro SHALL:
- Define a function `emacs-mcp-tool-<name>--handler` as the handler.
- Register the tool in the global tool registry (`emacs-mcp--tools`).
- Generate the JSON Schema `inputSchema` from the parameter declarations.
- Accept an optional `:confirm t` keyword argument after the handler body to mark the tool as requiring confirmation (FR-7).

**FR-2.2**: Parameter type mapping to JSON Schema:
| Elisp keyword | JSON Schema type | Notes                           |
|---------------|------------------|---------------------------------|
| `string`      | `"string"`       |                                 |
| `integer`     | `"integer"`      |                                 |
| `number`      | `"number"`       | Includes floats                 |
| `boolean`     | `"boolean"`      |                                 |
| `array`       | `"array"`        | Items type via `:items` keyword |
| `object`      | `"object"`       |                                 |

The generated `inputSchema` SHALL be a valid JSON Schema object with `type: "object"`, `properties`, and `required` fields derived from the parameter list.

**FR-2.3**: Tools registered via `emacs-mcp-deftool` SHALL be automatically included in `tools/list` responses and dispatchable via `tools/call`.

**FR-2.4**: The package SHALL provide `emacs-mcp-register-tool` as a programmatic function alternative, accepting keyword arguments: `:name` (string), `:description` (string), `:params` (list of param plists), `:handler` (function), `:confirm` (boolean, optional, default nil — if t, the tool requires user confirmation before execution per FR-7).

**FR-2.5**: The package SHALL provide `emacs-mcp-unregister-tool` accepting a tool name (string) to remove a tool at runtime. If the tool does not exist, signal an error.

**FR-2.6**: Tool handler return values SHALL be wrapped into MCP `CallToolResult` format:
- If the handler returns a **string**: wrap as `{"content": [{"type": "text", "text": "..."}], "isError": false}`.
- If the handler returns a **list of alists** with `type` keys: use as-is for the `content` array, with `"isError": false`.
- If the handler signals an Emacs error (any `error` condition): catch it and return `{"content": [{"type": "text", "text": "<error message>"}], "isError": true}`. This is a **tool execution error**, not a protocol error.

**FR-2.7**: Tool dispatch SHALL validate inputs before calling the handler:
- If the JSON body is malformed: return a JSON-RPC **protocol error** with code `-32700` (Parse error).
- If the `tools/call` params are malformed (missing `name` or `arguments` fields): return a JSON-RPC **protocol error** with code `-32602` (Invalid params).
- If the tool name is unknown or disabled: return a JSON-RPC **protocol error** with code `-32602` ("Unknown tool: <name>").
- If a required argument is missing: return a JSON-RPC **protocol error** with code `-32602` ("Missing required argument: <name>").
- If an argument value does not match the declared type (e.g., string expected but integer received): return a JSON-RPC **protocol error** with code `-32602` ("Invalid type for argument '<name>': expected <type>, got <actual>"). Type validation SHALL check JSON types: string, integer/number, boolean, array, object. Null values for optional arguments are accepted.

### FR-3: Built-in Emacs Tools

The package SHALL ship with the following built-in tools. Each tool is enabled by default but can be individually disabled via a defcustom `emacs-mcp-enable-tool-<name>` (boolean, default t, except where noted).

**FR-3.1** `xref-find-references` — Find all references to a symbol using xref backends.
- Parameters: `identifier` (string, required), `file` (string, optional — sets buffer context for xref).
- If `file` is provided, it MUST be within the session's project directory (FR-4.3).
- Returns: Newline-separated list of `file:line: summary` entries, or "No references found."

**FR-3.2** `xref-find-apropos` — Search for symbols matching a pattern.
- Parameters: `pattern` (string, required).
- Returns: Newline-separated list of matching symbols with locations.
- Results are scoped to the session's project directory where possible (depends on xref backend).

**FR-3.3** `project-info` — Return project metadata.
- Parameters: none.
- Returns: JSON string with `projectDir`, `activeBuffer` (path of the buffer visible in the selected window, or null), and `fileCount`.
- Session context: uses the session's project directory (from FR-4.2).

**FR-3.4** `imenu-symbols` — List symbols in a file with line numbers.
- Parameters: `file` (string, required — absolute path).
- Returns: Newline-separated `category: name (line N)` entries.
- The file MUST be within the session's project directory. Reject paths outside with a tool execution error.

**FR-3.5** `treesit-info` — Return tree-sitter syntax information.
- Parameters: `file` (string, required), `line` (integer, optional), `column` (integer, optional).
- The file MUST be within the session's project directory (FR-4.3).
- If only `file`: return top-level node types. If `line`/`column` provided: return the node at that position with its ancestors and children.
- Requires tree-sitter support for the file's language. Returns a tool execution error if tree-sitter is not available for the file type.

**FR-3.6** `get-diagnostics` — Return flycheck/flymake diagnostics.
- Parameters: `file` (string, optional — absolute path; if omitted, return diagnostics for all open project buffers).
- Backend auto-detected: prefer flymake (built-in), fall back to flycheck if available, else return empty.
- Returns: JSON array of `{"file", "line", "column", "severity", "message", "source"}` objects. Severity values: `"error"`, `"warning"`, `"info"`, `"hint"`.
- flycheck is an **optional** soft dependency. The tool works with flymake alone.

**FR-3.7** `open-file` — Open a file in Emacs with optional selection.
- Parameters: `path` (string, required — absolute path), `startLine` (integer, optional), `endLine` (integer, optional), `text` (string, optional — text to search and select).
- The file MUST be within the session's project directory. Reject paths outside with a tool execution error.
- Returns: `"FILE_OPENED"` on success.

**FR-3.8** `get-buffer-content` — Return contents of an open buffer.
- Parameters: `file` (string, required — absolute path), `startLine` (integer, optional), `endLine` (integer, optional).
- Returns: The buffer text (or specified line range). Tool execution error if the buffer is not visiting a file within the session's project directory.

**FR-3.9** `list-buffers` — Return open project buffers.
- Parameters: none.
- Returns: JSON array of `{"path", "modified", "mode"}` objects for each buffer visiting a file within the session's project directory.

**FR-3.10** `execute-elisp` — Evaluate an Emacs Lisp expression.
- Parameters: `expression` (string, required).
- Returns: The printed representation (`prin1-to-string`) of the evaluation result.
- **Disabled by default**: `emacs-mcp-enable-tool-execute-elisp` defaults to `nil`.
- **Confirmation required**: Even when enabled, each invocation SHALL call `emacs-mcp-confirm-function` (see FR-7) before evaluation. If the user declines, return a tool execution error: "User denied execution."

### FR-4: Session Management

**FR-4.1**: On `initialize`, the server SHALL generate a UUID v4 session ID and return it in the `Mcp-Session-Id` response header. All subsequent requests from that client MUST include this header. Session ID validation:
- Requests missing the `Mcp-Session-Id` header (other than `initialize`) SHALL receive **HTTP 400 Bad Request**.
- Requests with a syntactically invalid `Mcp-Session-Id` SHALL receive **HTTP 400 Bad Request**.
- Requests with an unknown, expired, or terminated session ID SHALL receive **HTTP 404 Not Found**. Per MCP spec, this signals the client to start a new session.

**FR-4.2**: Each session SHALL track:
- `session-id` (string): The UUID.
- `client-info` (alist): The `clientInfo` object from the `initialize` request (name, version).
- `project-dir` (string): The server's project directory, set at server start time. Determined by: (1) the value of `emacs-mcp-project-directory` defcustom (string or nil, default nil) if non-nil, (2) otherwise `(project-root (project-current))` if a project is detected, (3) otherwise `default-directory`. All sessions share the same project directory. `emacs-mcp-project-directory` is a formal defcustom with `:type '(choice (const :tag "Auto-detect" nil) (directory :tag "Fixed directory"))`. (Note: MCP `2025-03-26` defines `roots/list` as the protocol mechanism for clients to communicate workspace roots. Supporting `roots/list` to allow per-session project directories is deferred to a future version.)
- `state` (symbol): One of `initializing`, `ready`, `closed`.
- `connected-at` (timestamp): When the session was created.
- `last-activity` (timestamp): Updated on every request.
- `deferred` (hash-table): Maps JSON-RPC request ID (string or number, per MCP `RequestId` type) to a pending deferred response context. Request IDs are preserved exactly as received from JSON (string or number). Null IDs are rejected per MCP spec.
- `sse-streams` (list): Active SSE connections for this session (for server-to-client messages and deferred responses).

**FR-4.3**: **Path authorization**: Built-in tools that accept `file` or `path` parameters SHALL verify that the resolved absolute path is within the session's `project-dir` (using `file-in-directory-p`). Paths outside the project directory SHALL be rejected with a tool execution error: "Path outside project directory: <path>".

**FR-4.4**: **Buffer context isolation**: Tools that reference "current project" or "active buffer" SHALL use the session's `project-dir` to scope their behavior, NOT global Emacs state. For example, `list-buffers` returns only buffers visiting files under the session's `project-dir`. `project-info` returns the session's `project-dir`, not whatever `project-current` returns globally.

**FR-4.5**: Sessions SHALL be cleaned up after a configurable idle timeout (`emacs-mcp-session-timeout`, defcustom, default 1800 seconds / 30 minutes). Idle = no requests received within the timeout period. Cleanup closes SSE streams and removes session state.

**FR-4.6**: Sessions SHALL be terminated when the client sends HTTP DELETE with the session's `Mcp-Session-Id`. The server SHALL return HTTP 200 and clean up all session state.

### FR-5: Deferred Responses

**FR-5.1**: Tool handlers that need user interaction before returning use the **deferred response** pattern. To support this, the server SHALL dynamically bind two variables during tool handler execution:

- `emacs-mcp--current-session-id` — the session ID (string) of the calling client.
- `emacs-mcp--current-request-id` — the JSON-RPC request ID (string or number, per MCP `RequestId` type) of the current `tools/call`.

These are internal (`--` prefix) but available to tool handlers. A deferred tool captures these values and uses them later with `emacs-mcp-complete-deferred`.

**FR-5.2**: The deferred response flow:

1. The tool handler captures `emacs-mcp--current-session-id` and `emacs-mcp--current-request-id`, initiates the async operation (e.g., opens an ediff buffer), and returns the symbol `deferred`.
2. The server stores the request ID in the session's `deferred` hash-table.
3. The server responds to the HTTP POST with `Content-Type: text/event-stream`, opening an SSE stream. The stream remains open until the deferred response is completed or times out.
4. When the deferred action completes (e.g., user accepts/rejects), the completing code calls `emacs-mcp-complete-deferred` with the captured session ID, request ID, and result.
5. The server writes the JSON-RPC response as an SSE `data:` event on the open stream, then closes the stream.

**FR-5.3**: `emacs-mcp-complete-deferred` is a public function:
```elisp
(emacs-mcp-complete-deferred SESSION-ID REQUEST-ID RESULT &optional IS-ERROR)
```
- `SESSION-ID`: String, the session's UUID.
- `REQUEST-ID`: String or number (MCP `RequestId` type), the JSON-RPC request ID. Must match the exact value received.
- `RESULT`: String or content list (same as normal tool return values).
- `IS-ERROR`: If non-nil, sets `isError: true` in the `CallToolResult`.

**FR-5.4**: Deferred responses SHALL time out after `emacs-mcp-deferred-timeout` seconds (defcustom, default 300 / 5 minutes). On timeout, the server SHALL send a tool execution error response ("Deferred operation timed out") on the SSE stream and close it.

**FR-5.5**: If the SSE stream disconnects before the deferred response completes, the deferred entry SHALL remain in the session for the duration of the timeout. If the client reconnects (e.g., via GET), the server MAY deliver the response on the new stream. If the timeout expires without delivery, the deferred entry is discarded.

### FR-6: Server Lifecycle

**FR-6.1**: `emacs-mcp-start` SHALL be an interactive command (`;;;###autoload`) that starts the MCP server. If already running, it SHALL return the existing server's port without starting a second server.

**FR-6.2**: `emacs-mcp-stop` SHALL be an interactive command (`;;;###autoload`) that gracefully shuts down the server: close all active SSE streams and network connections, cancel all timers, remove all lockfiles, and clean up all session state. After shutdown, the server process no longer exists — clients attempting to connect receive a TCP connection refused error.

**FR-6.3**: `emacs-mcp-restart` SHALL be an interactive command (`;;;###autoload`) that calls `emacs-mcp-stop` then `emacs-mcp-start`.

**FR-6.4**: `emacs-mcp-mode` SHALL be a global minor mode. Enabling it calls `emacs-mcp-start`; disabling it calls `emacs-mcp-stop`. The mode SHALL add a `kill-emacs-hook` to ensure cleanup. The hook SHALL be removed when the mode is disabled.

**FR-6.5**: `(require 'emacs-mcp)` SHALL NOT install hooks, start network processes, or modify variables outside the `emacs-mcp-` namespace. Initializing package-internal registries (e.g., `emacs-mcp--tools` for built-in tool definitions, defcustom declarations) at load time is permitted — these are within the package's namespace and do not constitute global state pollution per NFR-7. All network, process, and hook side effects are deferred to `emacs-mcp-start` or enabling `emacs-mcp-mode`.

### FR-7: Confirmation Policy

**FR-7.1**: The package SHALL provide `emacs-mcp-confirm-function` (defcustom, default `#'emacs-mcp-default-confirm`). This function is called before executing tools that are marked as requiring confirmation. It receives two arguments: `TOOL-NAME` (string) and `ARGS` (alist of arguments). It SHALL return non-nil to allow execution, nil to deny.

**FR-7.2**: The default confirmation function `emacs-mcp-default-confirm` SHALL display a `y-or-n-p` prompt showing the tool name and a summary of the arguments.

**FR-7.3**: Tools are marked as requiring confirmation via the `:confirm` keyword in `emacs-mcp-deftool` or `:confirm t` in `emacs-mcp-register-tool`. Of the built-in tools, only `execute-elisp` requires confirmation.

**FR-7.4**: The user MAY set `emacs-mcp-confirm-function` to `#'always` to skip all confirmations, or to a custom function implementing their own policy (e.g., allow-list, logging, etc.).

### FR-8: Client Integration Support

**FR-8.1**: The package SHALL provide `emacs-mcp-connection-info` returning an alist:
```elisp
((:port . 8080)
 (:host . "127.0.0.1")
 (:url . "http://127.0.0.1:8080/mcp")
 (:lockfile . "~/.emacs-mcp/8080.lock"))
```

**FR-8.2**: The package SHALL support writing lockfiles to additional directories via `emacs-mcp-extra-lockfile-directories` (defcustom, list of strings, default nil). When the server starts, it writes lockfiles to `emacs-mcp-lockfile-directory` AND all paths in `emacs-mcp-extra-lockfile-directories`. Client packages add their paths here (e.g., `(add-to-list 'emacs-mcp-extra-lockfile-directories "~/.claude/ide")`).

**FR-8.3**: The package SHALL provide hooks:
- `emacs-mcp-server-started-hook` — Run after the server starts. Functions receive the port number.
- `emacs-mcp-server-stopped-hook` — Run after the server stops.
- `emacs-mcp-client-connected-hook` — Run when a new session is initialized. Functions receive the session ID.
- `emacs-mcp-client-disconnected-hook` — Run when a session is terminated. Functions receive the session ID.

### FR-9: Tool Visibility

**FR-9.1**: All registered tools are visible to all connected clients. There is no per-client tool filtering in this version. If a user wants to restrict tools, they can disable specific tools via the `emacs-mcp-enable-tool-<name>` defcustoms.

## Non-Functional Requirements

**NFR-1: Startup Performance** — `(require 'emacs-mcp)` SHALL complete in under 50ms. No network activity, no hooks installed, no processes started at load time (Constitution constraint).

**NFR-2: Zero External Dependencies** — The package SHALL have NO required external package dependencies. The HTTP server uses `make-network-process` (built-in). JSON handling uses `json-parse-string` and `json-serialize` (built-in in Emacs 29+). Optional soft dependencies: flycheck (for `get-diagnostics` tool, auto-detected at runtime).

**NFR-3: Concurrency Model** — Emacs is single-threaded. Tool handlers execute synchronously and WILL block Emacs while running. The HTTP server queues incoming requests via Emacs's event loop (`accept-process-output`), so connections are not dropped while a handler runs, but responses are serialized. This is acceptable because:
- Most tools complete in under 10ms (buffer queries, imenu, diagnostics lookup).
- Tools that may take longer (xref across large projects) are inherently Emacs operations that would block regardless.
- Deferred tools (FR-5) return immediately and complete asynchronously.
Long-running tools SHOULD NOT be added to the built-in set without careful consideration.

**NFR-4: Security**
- The server binds to `127.0.0.1` only.
- The server SHALL validate the `Origin` header on all incoming requests to prevent DNS rebinding attacks. The validation predicate:
  - If the `Origin` header is **absent**: the request is **allowed** (non-browser clients typically do not send Origin).
  - If the `Origin` header is **present**: it MUST match one of: `http://127.0.0.1`, `http://127.0.0.1:<port>`, `http://localhost`, `http://localhost:<port>`, `http://[::1]`, `http://[::1]:<port>` (any port number). HTTPS variants of these are also accepted. Any other Origin value SHALL be rejected with **HTTP 403 Forbidden**.
  - Malformed Origin values (not parseable as a URL) SHALL be rejected with HTTP 403.
- Tools requiring user confirmation use the `emacs-mcp-confirm-function` mechanism.
- Path authorization (FR-4.3) prevents tools from accessing files outside the session's project directory.
- `execute-elisp` is disabled by default and requires confirmation when enabled.

**NFR-5: Emacs Compatibility** — GNU Emacs 29.1 and later. No support for XEmacs or earlier Emacs versions.

**NFR-6: Package Ecosystem** — The package SHALL be distributable via MELPA and NonGNU ELPA. It SHALL include standard package headers: `;;; emacs-mcp.el --- MCP server for Emacs`, `;; Version:`, `;; Package-Requires: ((emacs "29.1"))`, `;; License: AGPL-3.0-or-later`, `;; URL:`. All source files SHALL include the AGPL-3.0 license header.

**NFR-8: README Documentation** — The package SHALL include a `README.org` file with:
1. Installation instructions (MELPA, manual).
2. Quick start guide (`emacs-mcp-mode`, `M-x emacs-mcp-start`).
3. Configuration reference for all defcustoms.
4. Connecting LLM agents — concrete config examples for Claude Code (`.claude/settings.json`), Gemini CLI, Codex CLI, and a generic curl walkthrough showing the full initialize → tools/list → tools/call MCP flow.
5. Built-in tools reference table (name, description, parameters).
6. Adding custom tools guide with `emacs-mcp-deftool` examples (simple tool, tool with `:confirm`), `emacs-mcp-register-tool` programmatic API, `emacs-mcp-unregister-tool`, parameter type mapping, return value conventions (string, content list, error signaling, deferred pattern), and a complete worked example.
7. Lockfile discovery explanation.
8. Security model (Origin validation, path authorization, confirmation policy, execute-elisp).
9. License (AGPL-3.0-or-later).

**NFR-7: No Global State Pollution** — Per the constitution. The package SHALL not modify any global keymaps, hooks, or variables outside the `emacs-mcp-` namespace at load time (`require`). When `emacs-mcp-mode` is enabled or `emacs-mcp-start` is called, the package MAY add to `kill-emacs-hook` (for cleanup) — this is the only permitted global hook modification, and it SHALL be removed when the mode is disabled or the server stops.

## Acceptance Criteria

**AC-1**: `M-x emacs-mcp-start` starts an HTTP server on localhost. The following curl command returns a valid MCP `InitializeResult` with protocol version `2025-03-26` and an `Mcp-Session-Id` header:
```sh
curl -s -D - -X POST http://127.0.0.1:PORT/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

**AC-2**: `tools/list` returns all enabled built-in tools. Each tool has a `name`, `description`, and valid JSON Schema `inputSchema` with `type: "object"`, `properties`, and `required` fields.

**AC-3**: `tools/call` with `name: "project-info"` returns a `CallToolResult` with `isError: false` and content containing the project directory.

**AC-4**: A user-defined tool registered via `emacs-mcp-deftool` appears in `tools/list` and returns correct results via `tools/call`.

**AC-5**: Two concurrent curl sessions (different `Mcp-Session-Id` values) can call tools independently without interference.

**AC-6**: `M-x emacs-mcp-stop` shuts down cleanly — port released, lockfiles removed, subsequent requests fail with connection refused.

**AC-7**: Lockfiles appear in `emacs-mcp-lockfile-directory` AND all paths in `emacs-mcp-extra-lockfile-directories`.

**AC-8**: The package byte-compiles with zero warnings under `byte-compile-warnings` set to `t`. All public symbols pass `checkdoc`.

**AC-9**: ERT tests exist for:
- Tool registration and unregistration
- JSON-RPC request parsing and response generation
- Tool dispatch with valid and invalid arguments
- Argument validation (missing required args, unknown tool)
- Session creation, lookup, timeout, and cleanup
- Path authorization (accept paths inside project, reject outside)
- Each built-in tool's core functionality
- `CallToolResult` wrapping (string, content list, error conditions)
- HTTP request parsing (method, headers, body extraction)

**AC-10**: `Origin` header validation:
- Request with `Origin: http://evil.com` is rejected with HTTP 403.
- Request with no `Origin` header is accepted.
- Request with `Origin: http://127.0.0.1:8080` is accepted.
- Request with `Origin: http://localhost` is accepted.
- Request with `Origin: http://[::1]:8080` is accepted.
- Request with `Origin: https://localhost:443` is accepted.
- Request with malformed `Origin: not-a-url` is rejected with HTTP 403.

**AC-11**: `execute-elisp` with `emacs-mcp-enable-tool-execute-elisp` set to nil returns a protocol error (tool not found). With it set to t, the tool calls `emacs-mcp-confirm-function` before evaluation.

**AC-12**: A `tools/call` request with a string request ID (e.g., `"id": "abc-123"`) receives a response with the same string ID preserved exactly.

**AC-13**: After a session is terminated (via DELETE or timeout), subsequent requests with that session's `Mcp-Session-Id` receive HTTP 404 Not Found.

**AC-14**: A batch array containing two `tools/call` requests returns a JSON array with two corresponding responses.

**AC-15**: `README.org` exists at the project root, contains sections for installation, quick start, configuration, connecting LLM agents (with Claude Code, Gemini CLI, Codex examples), built-in tools, adding custom tools (with `emacs-mcp-deftool` and `emacs-mcp-register-tool` examples), and security.

## Out of Scope

1. **Terminal/CLI management** — Starting, stopping, or managing LLM CLI processes is a client-package concern.

2. **Diff/ediff integration** — The deferred response infrastructure (FR-5) is in scope. Specific diff UI is a client-package concern. Client packages can register their own diff tools via `emacs-mcp-deftool`.

3. **Selection tracking and notifications** — Real-time cursor/selection change notifications are client-specific.

4. **WebSocket transport** — Only Streamable HTTP (MCP `2025-03-26`) is in scope. Client packages needing WebSocket for backward compatibility with older CLI versions can implement their own transport layer.

5. **MCP client functionality** — This package is an MCP *server* only.

6. **UI elements** — No transient menus, mode-line indicators, or custom buffers. The only UI is the `y-or-n-p` confirmation prompt for dangerous tools.

7. **Per-client tool filtering** — All tools visible to all clients. Fine-grained access control deferred to a future version.

8. **SSE resumability** — The `Last-Event-ID` / event ID mechanism from the MCP spec is optional and deferred to a future version.

9. **JSON-RPC batch sending** — The server MUST support receiving batch arrays (per MCP spec). However, the server does NOT send batched responses proactively or optimize batch processing. Each message in a received batch is processed sequentially.

## Changelog

- [Clarification iter1] FR-1.6: Default port changed from nil (auto-select) to `38840` (fixed). Added port validation range (1-65535). Added `user-error` on bind failure.
- [Clarification iter1] FR-4.2: `emacs-mcp-project-directory` formally declared as defcustom with `:type` and default nil.
- [Clarification iter1] FR-6.1/FR-6.2/FR-6.3: Explicitly marked as interactive commands with `;;;###autoload`.
- [Clarification iter1] FR-1.2 GET: Resolved ambiguity — server supports GET SSE streams (not 405). Requires valid session ID.
- [Clarification iter2] FR-1.6: Added `:safe` predicate for port validation. Clarified nil is the only auto-select value (not 0).
- [Clarification iter2] FR-1.7: Added stale lockfile cleanup on startup (check PID, remove if dead).
- [Clarification iter2] C-6: Upgraded from [NO SPEC CHANGE] to [SPEC UPDATE].
- [Clarification iter3] FR-1.6: Added explicit runtime validation in `emacs-mcp-start` (separate from `:safe` which is file-local safety only). Invalid port signals `user-error` before bind attempt.
- [Clarification delta1] NFR-8: Added README.org requirement with installation, configuration, LLM agent examples (Claude Code, Gemini CLI, Codex), custom tool guide, and security docs. Added AC-15.
