# Gauge Review — Iteration 3

**Reviewer**: Codex (GPT-5.5)
**Date**: 2026-04-26

## BLOCKING Issues

1. **FR-1.1/FR-1.2/Out of Scope #9 still violates MCP 2025-03-26 batching requirements** — The spec claims MCP `2025-03-26` compliance and Streamable HTTP compliance, but FR-1.2 rejects every JSON-RPC batch array with `-32600`, and Out of Scope #9 says batching is not supported. That is not compliant. The MCP base protocol says implementations MAY support sending JSON-RPC batches, but MUST support receiving them; the Streamable HTTP transport also allows POST bodies to be batch arrays. Fix by supporting received batches for all non-`initialize` messages, while preserving the MCP rule that `initialize` MUST NOT be batched. Source: https://modelcontextprotocol.io/specification/2025-03-26/basic/index and https://modelcontextprotocol.io/specification/2025-03-26/basic/transports

2. **FR-4.1 uses the wrong HTTP status for expired or unknown session IDs** — FR-4.1 says requests "without a valid `Mcp-Session-Id`" receive HTTP 400. That conflates missing session IDs with invalid, expired, or terminated session IDs. MCP says missing required session IDs SHOULD be HTTP 400, but once a server terminates a session it MUST respond to requests containing that session ID with HTTP 404. FR-1.2 already says DELETE returns 404 if the session does not exist, so the spec is internally inconsistent and protocol-incomplete for ordinary POST/GET requests after timeout or deletion. Fix FR-4.1/FR-4.5/FR-4.6 to distinguish missing header = 400, syntactically invalid header = 400, unknown/expired/closed session = 404. Source: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports

3. **FR-5 restricts JSON-RPC request IDs to integers** — FR-4.2, FR-5.1, and FR-5.3 define deferred request IDs as integers. MCP request IDs are `string | number`, null is forbidden, and responses must use the same ID. A client using string IDs will break deferred responses or force non-compliant coercion. Fix all request-id requirements and APIs to accept the MCP `RequestId` type: string or integer/number as parsed from JSON, preserving exact value identity. Source: https://modelcontextprotocol.io/specification/2025-03-26/basic/index

4. **FR-2.4 conflicts with FR-7.3 for programmatic confirmation** — FR-2.4 defines `emacs-mcp-register-tool` with `:name`, `:description`, `:params`, and `:handler` only. FR-7.3 says tools can be marked with `:confirm t` in `emacs-mcp-register-tool`. This is a public API contradiction in the security boundary. Fix FR-2.4 to include optional `:confirm` and define the default as nil.

## WARNINGs

1. **FR-6.5 is overbroad and conflicts with tool registration wording** — FR-6.5 says loading the file shall not "modify any global state." FR-2.1 says `emacs-mcp-deftool` registers tools in global `emacs-mcp--tools`, and built-in tools have to become available somehow. NFR-7 is the usable rule: no global keymaps, hooks, or variables outside the `emacs-mcp-` namespace at load time. Rewrite FR-6.5 to match NFR-7 and explicitly allow initialization of package-internal registries without network/process/hook side effects.

2. **FR-1.2 omits required request-header behavior** — MCP Streamable HTTP clients MUST send `Accept: application/json, text/event-stream` on POST and `Accept: text/event-stream` on GET. The spec's acceptance criteria include the POST header, but FR-1.2 does not say whether the server validates or ignores missing/unsupported `Accept` headers. This is testable only if specified.

3. **Path authorization is global but unevenly stated per tool** — FR-4.3 covers built-in `file`/`path` parameters, but FR-3.1 `xref-find-references` and FR-3.5 `treesit-info` do not repeat the project-boundary rule while `imenu-symbols` and `open-file` do. This is implementable because FR-4.3 is clear, but the built-in tool sections should be normalized so no implementer misses `xref` and tree-sitter path checks.

4. **Pagination is named but not specified enough for tests** — `tools/list`, `resources/list`, and `prompts/list` mention cursor pagination, but there is no page-size rule, cursor encoding, empty-list response shape, or `nextCursor` behavior. If the intended implementation always returns all entries and omits `nextCursor`, say that explicitly.

5. **Origin validation pattern is underspecified** — NFR-4 allows `http://127.0.0.1:*` and `http://localhost:*`, but does not define treatment of absent `Origin`, HTTPS localhost, IPv6 loopback (`[::1]`), default ports, or malformed origins. DNS rebinding protections are security-sensitive; define the exact predicate and add AC coverage.

## NOTEs

1. The iteration 2 blockers for project root discovery, deferred context exposure, input type validation, and the previous internal batch contradiction were addressed structurally. The batch fix is still wrong because it chose internal consistency over MCP compliance.

2. `notifications/initialized`, `ping`, shutdown stream handling, `:confirm t` macro syntax, and the `kill-emacs-hook` exception are now adequately covered.

3. Consider adding AC tests for string request IDs and expired-session 404s; both are cheap and would prevent protocol regressions.

VERDICT: REVISE
