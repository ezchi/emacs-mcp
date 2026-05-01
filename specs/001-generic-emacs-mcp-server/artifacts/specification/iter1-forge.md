# Specification: Generic Emacs MCP Server

**Spec ID**: 001-generic-emacs-mcp-server
**Date**: 2026-04-26
**Status**: Draft

## Overview

Both `claude-code-ide.el` and `gemini-cli-ide` implement nearly identical MCP (Model Context Protocol) server infrastructure inside Emacs. Each package duplicates:

- A WebSocket-based MCP server for IDE operations
- An HTTP-based MCP server for Emacs tool exposure
- JSON-RPC 2.0 message handling and dispatch
- Tool registration, schema generation, and argument validation
- Session management (per-project, with lockfile discovery)
- Emacs tools: xref, imenu, tree-sitter, project-info, diagnostics
- Deferred response patterns for async tools (ediff)

The only differences are client-specific coupling: symbol prefixes (`claude-code-ide-` vs `gemini-cli-ide-`), lockfile paths (`~/.claude/ide/` vs `~/.gemini/ide/`), environment variables, and terminal/CLI management.

**`emacs-mcp` extracts the shared MCP server and Emacs tool layer into a standalone package.** Users start one MCP server from Emacs; any MCP-capable LLM agent (Claude Code, Gemini CLI, Copilot, custom agents) connects to it. The client-specific packages (`claude-code-ide.el`, `gemini-cli-ide`) become thin wrappers that depend on `emacs-mcp` for MCP functionality and add only their own CLI/terminal management.

## User Stories

**US-1**: As an Emacs user, I want to start a single MCP server so that multiple LLM agents can access my Emacs environment simultaneously without requiring separate server instances per agent.

**US-2**: As an Emacs user, I want to expose Emacs capabilities (xref, imenu, tree-sitter, diagnostics, file operations) as MCP tools so that any MCP-compatible agent can use them.

**US-3**: As a package author integrating a new LLM CLI with Emacs, I want to depend on `emacs-mcp` for MCP server functionality so that I only need to implement CLI/terminal management, not the entire MCP stack.

**US-4**: As an Emacs user, I want to register custom MCP tools via Emacs Lisp so that I can extend what agents can do in my environment.

**US-5**: As an Emacs user, I want the MCP server to handle concurrent connections from multiple clients so that I can run Claude Code and Gemini CLI side by side against the same Emacs instance.

**US-6**: As an Emacs user, I want a clear approval mechanism for dangerous tool calls (code execution, file writes) so that agents cannot perform destructive actions without my consent.

## Functional Requirements

### FR-1: MCP Server Core

**FR-1.1**: The package SHALL implement an MCP server compliant with MCP protocol version `2024-11-05`.

**FR-1.2**: The server SHALL support the HTTP+SSE (Streamable HTTP) transport as the primary transport. The endpoint SHALL accept JSON-RPC 2.0 requests via HTTP POST on a configurable local port.

**FR-1.3**: The server SHALL support multiple concurrent client connections. Each client gets its own logical session. Sessions are identified by a server-generated session ID returned in response headers.

**FR-1.4**: The server SHALL implement the following MCP methods:
- `initialize` — Return server capabilities, protocol version, and server info
- `tools/list` — Return all registered tools with JSON schemas
- `tools/call` — Execute a tool by name with provided arguments
- `resources/list` — Return registered resources (initially empty, extensible)
- `prompts/list` — Return registered prompts (initially empty, extensible)
- `notifications/initialized` — Acknowledge client initialization

**FR-1.5**: The server SHALL bind to `127.0.0.1` only. No remote connections.

**FR-1.6**: The server port SHALL be configurable via `emacs-mcp-server-port`. If nil, auto-select an available port.

**FR-1.7**: The server SHALL create a lockfile at a configurable location (default: `~/.emacs-mcp/{PORT}.lock`) containing JSON metadata: `{ pid, port, workspaceFolders, serverName, transport }`. This enables client-side auto-discovery.

### FR-2: Tool Registration Framework

**FR-2.1**: The package SHALL provide a public macro `emacs-mcp-deftool` for registering MCP tools:
```elisp
(emacs-mcp-deftool tool-name
  "Description string."
  (:params ((:name "param1" :type string :description "..." :required t)
            (:name "param2" :type boolean :description "..." :required nil)))
  (lambda (params)
    ;; Tool implementation. Return string or alist.
    ))
```

**FR-2.2**: Tools registered via `emacs-mcp-deftool` SHALL be automatically included in `tools/list` responses and dispatchable via `tools/call`.

**FR-2.3**: The package SHALL provide `emacs-mcp-register-tool` as a programmatic alternative to the macro, accepting a plist: `:name`, `:description`, `:params`, `:handler`.

**FR-2.4**: The package SHALL provide `emacs-mcp-unregister-tool` to remove a tool at runtime.

**FR-2.5**: Tool handlers SHALL receive arguments as a parsed alist (from JSON). They SHALL return either a string (wrapped as `[{type: "text", text: "..."}]`) or a list of content objects for richer responses.

**FR-2.6**: Tool dispatch SHALL validate required arguments against the schema before calling the handler. Missing required arguments SHALL return a JSON-RPC error without invoking the handler.

### FR-3: Built-in Emacs Tools

The package SHALL ship with the following built-in tools, each independently toggleable via defcustom:

**FR-3.1** `emacs-mcp-tool-xref-find-references` — Find all references to a symbol using xref backends (LSP, etags, etc.). Parameters: `identifier` (string, required).

**FR-3.2** `emacs-mcp-tool-xref-find-apropos` — Search for symbols matching a pattern. Parameters: `pattern` (string, required).

**FR-3.3** `emacs-mcp-tool-project-info` — Return current project directory, active buffer path, and file count. No parameters.

**FR-3.4** `emacs-mcp-tool-imenu-symbols` — List symbols (functions, classes, variables) in a file with line numbers. Parameters: `file` (string, required).

**FR-3.5** `emacs-mcp-tool-treesit-info` — Return tree-sitter AST for a file or node at a position. Parameters: `file` (string, required), `line` (integer, optional), `column` (integer, optional).

**FR-3.6** `emacs-mcp-tool-get-diagnostics` — Return flycheck/flymake diagnostics for a file or all open buffers. Parameters: `file` (string, optional). Backend auto-detected.

**FR-3.7** `emacs-mcp-tool-open-file` — Open a file in Emacs, optionally selecting a line range or text. Parameters: `path` (string, required), `startLine` (integer, optional), `endLine` (integer, optional), `text` (string, optional).

**FR-3.8** `emacs-mcp-tool-get-buffer-content` — Return the contents of an open buffer. Parameters: `file` (string, required), `startLine` (integer, optional), `endLine` (integer, optional).

**FR-3.9** `emacs-mcp-tool-list-buffers` — Return a list of open buffers in the current project with file paths. No parameters.

**FR-3.10** `emacs-mcp-tool-execute-elisp` — Evaluate an Emacs Lisp expression and return the result. Parameters: `expression` (string, required). This tool SHALL be disabled by default and require explicit opt-in via `emacs-mcp-enable-execute-elisp`.

### FR-4: Session Management

**FR-4.1**: Each HTTP client connection SHALL be assigned a unique session ID on `initialize`. The session ID SHALL be returned via a custom response header (`Mcp-Session-Id`) and included in subsequent requests by the client.

**FR-4.2**: Sessions SHALL track: client identity (if provided), connected timestamp, project directory (from initialize params or default), and active deferred responses.

**FR-4.3**: The server SHALL support a deferred response pattern for tools that require user interaction (e.g., diff review). The tool handler returns a deferred marker; the actual response is sent later via SSE when the user completes the action.

**FR-4.4**: The package SHALL provide `emacs-mcp-complete-deferred` as a public API for completing deferred tool responses.

**FR-4.5**: Sessions SHALL be cleaned up when the client disconnects or after a configurable idle timeout (default: 30 minutes).

### FR-5: Server Lifecycle

**FR-5.1**: `emacs-mcp-start` SHALL start the MCP server. If already running, it SHALL return the existing server's port.

**FR-5.2**: `emacs-mcp-stop` SHALL gracefully shut down the server: close all client connections, cancel timers, remove lockfiles, and clean up session state.

**FR-5.3**: `emacs-mcp-restart` SHALL stop then start.

**FR-5.4**: A `kill-emacs-hook` SHALL ensure cleanup on Emacs exit.

**FR-5.5**: `emacs-mcp-mode` SHALL be a global minor mode that starts/stops the server when enabled/disabled.

### FR-6: Client Integration Support

**FR-6.1**: The package SHALL provide `emacs-mcp-connection-info` returning an alist with `:port`, `:host`, `:url`, and `:lockfile-path` — everything a client package needs to configure its CLI.

**FR-6.2**: The package SHALL support client-specific lockfile directories via `emacs-mcp-lockfile-directories`. This is a list of paths (e.g., `("~/.claude/ide" "~/.gemini/ide")`). When the server starts, it writes lockfiles to ALL configured directories so that multiple CLI tools can discover the server.

**FR-6.3**: The package SHALL provide hooks: `emacs-mcp-server-started-hook`, `emacs-mcp-server-stopped-hook`, `emacs-mcp-client-connected-hook`, `emacs-mcp-client-disconnected-hook`.

## Non-Functional Requirements

**NFR-1: Startup Performance** — `(require 'emacs-mcp)` SHALL complete in under 50ms. No network activity at load time (Constitution constraint).

**NFR-2: Dependencies** — The only required external dependency SHALL be `web-server` (for the HTTP transport). All other functionality uses built-in Emacs libraries (`json.el`, `url.el`, `xref.el`, `treesit.el`, `project.el`, `flymake.el`).

**NFR-3: Concurrency** — The server SHALL handle multiple simultaneous tool calls from different clients without blocking Emacs. Tool handlers run synchronously in Emacs's single thread, but the HTTP server SHALL queue and process requests without dropping connections.

**NFR-4: Security** — The server binds to localhost only. Tool calls that execute arbitrary code (`execute-elisp`) require explicit opt-in. No tool SHALL write to the filesystem or execute shell commands without being explicitly designed and documented to do so.

**NFR-5: Emacs Compatibility** — The package SHALL support GNU Emacs 29.1 and later. It SHALL NOT support XEmacs or Emacs versions before 29.

**NFR-6: Package Ecosystem** — The package SHALL be distributable via MELPA, NonGNU ELPA, or similar. It SHALL follow standard Emacs package conventions (headers, autoloads, `;;;###autoload`, version, URL, etc.).

**NFR-7: No Global State Pollution** — Per the constitution. The package SHALL not modify any global keymaps, hooks, or variables outside the `emacs-mcp-` namespace unless the user explicitly enables `emacs-mcp-mode`.

## Acceptance Criteria

**AC-1**: Running `M-x emacs-mcp-start` starts an HTTP MCP server on localhost. `curl -X POST http://127.0.0.1:PORT/mcp -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test"}}}'` returns a valid MCP initialize response.

**AC-2**: `tools/list` returns all registered built-in tools with correct JSON schemas.

**AC-3**: `tools/call` with `emacs-mcp-tool-project-info` returns the current project directory.

**AC-4**: A user-defined tool registered via `emacs-mcp-deftool` appears in `tools/list` and is callable via `tools/call`.

**AC-5**: Two concurrent `curl` sessions can both call tools independently without interference.

**AC-6**: `M-x emacs-mcp-stop` shuts down the server cleanly — port is released, lockfiles are removed, subsequent curl requests fail with connection refused.

**AC-7**: Lockfiles appear in all directories listed in `emacs-mcp-lockfile-directories`.

**AC-8**: The package byte-compiles with zero warnings. All public symbols pass `checkdoc`.

**AC-9**: ERT tests exist for: tool registration/unregistration, JSON-RPC message parsing, tool dispatch, argument validation, session creation/cleanup, and each built-in tool.

## Out of Scope

1. **Terminal/CLI management** — Starting, stopping, or managing LLM CLI processes (Claude, Gemini, etc.) is the responsibility of client packages, not `emacs-mcp`.

2. **Diff/ediff integration** — The deferred response infrastructure is in scope, but the specific ediff UI for reviewing diffs is a client-package concern. Client packages can register their own diff tools using `emacs-mcp-deftool`.

3. **Selection tracking and notifications** — Real-time cursor/selection change notifications pushed to clients. This is client-specific behavior that belongs in wrapper packages.

4. **WebSocket transport** — The initial version uses HTTP+SSE (Streamable HTTP) only. WebSocket support may be added later if needed for backward compatibility with existing CLIs, but it is not in scope for this spec.

5. **MCP client functionality** — This package is an MCP *server* only. It does not connect to external MCP servers.

6. **UI elements** — No transient menus, mode-line indicators, or interactive prompts beyond what Emacs's minor mode conventions provide.

## Open Questions

**[NEEDS CLARIFICATION] OQ-1**: Should the package also ship a WebSocket transport for backward compatibility with existing Claude Code and Gemini CLI versions that expect WebSocket? Or should those CLIs be updated to connect via HTTP?

**[NEEDS CLARIFICATION] OQ-2**: Should `emacs-mcp-lockfile-directories` default to including `~/.claude/ide` and `~/.gemini/ide`, or should client packages be responsible for adding their paths via their own setup functions?

**[NEEDS CLARIFICATION] OQ-3**: What is the desired relationship between `emacs-mcp` and the existing client packages? Options:
  - (a) `claude-code-ide.el` / `gemini-cli-ide` add `emacs-mcp` as a dependency and delegate all MCP to it
  - (b) `emacs-mcp` is fully standalone; client packages optionally detect and use it if present
  - (c) Both — `emacs-mcp` works standalone, but client packages can also depend on it to avoid duplication

**[NEEDS CLARIFICATION] OQ-4**: Should `emacs-mcp` provide a mechanism for per-client tool visibility (i.e., some tools only exposed to Claude, others only to Gemini)? Or are all tools visible to all connected clients?

**[NEEDS CLARIFICATION] OQ-5**: The `web-server` package is the only external dependency. Is this acceptable, or should the HTTP server be implemented using only built-in Emacs networking (`make-network-process` + manual HTTP parsing)?
