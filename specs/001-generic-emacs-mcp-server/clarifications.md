# Clarifications: 001-generic-emacs-mcp-server

## C-1: Port configuration, default value, and error handling [SPEC UPDATE]

**Ambiguity**: FR-1.6 says the port is configurable via `emacs-mcp-server-port` with nil meaning auto-select. But:
- Auto-selecting a random port forces users to re-discover the port each time Emacs restarts, making MCP client configuration brittle.
- There is no specified behavior when a user-configured port is already in use or otherwise not bindable.

**Resolution**: Change the default to a well-known fixed port (`38840`) so users can configure their MCP clients once. If the configured port cannot be bound (already in use, permission denied, etc.), `emacs-mcp-start` SHALL signal a `user-error` with a clear message: `"emacs-mcp: cannot bind to port %d: %s"`. The user can set the port to `nil` for auto-select if they prefer dynamic ports. Auto-select is the escape hatch, not the default.

**Rationale**: The constitution says "User control — the user must be able to configure, override, or disable any behavior. No opaque defaults." A random port on every restart is an opaque default — the user cannot predict what port will be used. A fixed default port is transparent and predictable.

## C-2: `emacs-mcp-project-directory` defcustom not formally declared [SPEC UPDATE]

**Ambiguity**: FR-4.2 references `emacs-mcp-project-directory` defcustom as the first choice for determining the session's project directory, but this variable is never formally listed in its own defcustom declaration alongside `emacs-mcp-server-port`, `emacs-mcp-session-timeout`, etc.

**Resolution**: Add `emacs-mcp-project-directory` as a formal defcustom (string or nil, default nil) to FR-4.2. When nil, fall back to `(project-root (project-current))` then `default-directory`.

## C-3: MCP tool names — wire format vs Emacs naming [NO SPEC CHANGE]

**Clarification**: The tool names in FR-3.x (e.g., `xref-find-references`, `project-info`, `open-file`) are the MCP tool names sent over the wire in `tools/list` and `tools/call`. They use kebab-case, consistent with Emacs Lisp naming conventions. The corresponding Emacs handler functions use the pattern `emacs-mcp-tool-<name>--handler` (e.g., `emacs-mcp-tool-xref-find-references--handler`), but clients interact with the plain tool name string.

## C-4: `emacs-mcp-start` and `emacs-mcp-stop` are interactive commands [SPEC UPDATE]

**Ambiguity**: AC-1 and AC-6 reference `M-x emacs-mcp-start` and `M-x emacs-mcp-stop`, implying they are interactive commands, but FR-6.1/FR-6.2/FR-6.3 do not explicitly state they are interactive or have `;;;###autoload` cookies.

**Resolution**: FR-6.1, FR-6.2, and FR-6.3 SHALL specify that `emacs-mcp-start`, `emacs-mcp-stop`, and `emacs-mcp-restart` are interactive commands with `;;;###autoload` cookies, per the constitution's coding standards on autoloads.

## C-5: GET SSE stream — supported or 405? [SPEC UPDATE]

**Ambiguity**: FR-1.2 says the GET method returns either `text/event-stream` (SSE) or HTTP 405. The spec never decides which. FR-5.5 says "if the client reconnects (e.g., via GET), the server MAY deliver the response on the new stream" — implying GET SSE is supported.

**Resolution**: The server SHALL support GET SSE streams. GET to the MCP endpoint with a valid `Mcp-Session-Id` opens an SSE stream for that session. The server uses this stream for server-to-client notifications and for redelivering deferred responses after reconnection. GET without a valid session ID returns HTTP 400 (missing) or HTTP 404 (unknown).

## C-6: Lockfile cleanup on stale processes [SPEC UPDATE]

**Ambiguity**: FR-1.7 creates lockfiles with the Emacs PID. If Emacs crashes without running `kill-emacs-hook`, stale lockfiles remain. The spec does not define what happens on the next startup.

**Resolution**: Add to FR-1.7: On startup, before creating a new lockfile, `emacs-mcp-start` SHALL check for existing lockfiles in all lockfile directories. For each existing lockfile, read the PID and verify whether the process is still alive (via `process-attributes`). If the process is dead, remove the stale lockfile. If the process is alive and owns the target port, this is a port conflict — handled by the bind-failure error in FR-1.6.

## C-7: Implicit assumption — `emacs-mcp-server-port` validation range [SPEC UPDATE]

**Ambiguity**: FR-1.6 says the port is "integer or nil" but doesn't specify valid range. Users could set port 80 (requires root), 0 (auto-select), or 99999 (invalid).

**Resolution**: The defcustom SHALL validate that the port is either nil (auto-select) or an integer in the range 1-65535. The `:type` declaration should use `(choice (const :tag "Auto-select" nil) (integer :tag "Fixed port"))` with a `:safe` predicate that checks the range.

## C-8: README with usage instructions and client configuration examples [SPEC UPDATE]

**User feedback**: "please create README file with details instruction about how to use this MCP with examples for claude code, gemini cli and codex. It has needs to have detail information about how to add new tools to the MCP server"

**Resolution**: Add a new non-functional requirement (NFR-8) requiring a `README.org` file (Org format, consistent with Emacs ecosystem conventions) that includes:

1. **Installation** — How to install the package (MELPA, manual).
2. **Quick Start** — Minimal setup: `(emacs-mcp-mode 1)` or `M-x emacs-mcp-start`.
3. **Configuration** — All defcustoms: `emacs-mcp-server-port`, `emacs-mcp-project-directory`, `emacs-mcp-lockfile-directory`, `emacs-mcp-extra-lockfile-directories`, `emacs-mcp-session-timeout`, `emacs-mcp-deferred-timeout`, `emacs-mcp-confirm-function`, `emacs-mcp-enable-tool-*`.
4. **Connecting LLM Agents** — Concrete configuration examples for:
   - **Claude Code**: `.claude/settings.json` MCP server config pointing to `http://127.0.0.1:38840/mcp`
   - **Gemini CLI**: `.gemini/settings.json` or equivalent MCP server config
   - **Codex**: MCP server config for OpenAI Codex CLI
   - **Generic MCP client**: curl-based example showing the full initialize → tools/list → tools/call flow
5. **Built-in Tools** — Table of all built-in tools with name, description, and parameters.
6. **Adding Custom Tools** — Detailed guide with examples:
   - `emacs-mcp-deftool` macro usage (simple tool, tool with confirmation)
   - `emacs-mcp-register-tool` programmatic API
   - `emacs-mcp-unregister-tool` for runtime removal
   - Parameter types and JSON Schema mapping
   - Return value conventions (string, content list, error signaling, deferred)
   - A complete worked example of a custom tool from definition to use
7. **Lockfile Discovery** — How lockfiles work, where they are, how to add extra directories.
8. **Security** — Origin validation, path authorization, confirmation policy, execute-elisp.
9. **License** — AGPL-3.0-or-later.

**Rationale**: The constitution says "User control" — users need clear documentation to configure and extend the package. A README is standard for MELPA packages and essential for adoption.
