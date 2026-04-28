# Gauge Review: Specification Iteration 1

You are reviewing a feature specification for an Emacs MCP (Model Context Protocol) server package. Your role is the Gauge — a strict, independent reviewer.

## Task

Review the specification at `specs/002-per-session-project-directory/spec.md` for:

1. **Completeness** — Are all necessary details specified? Are there gaps?
2. **Clarity** — Is the spec unambiguous? Could an implementer follow it without guessing?
3. **Testability** — Are acceptance criteria concrete and verifiable?
4. **Consistency** — Do requirements contradict each other?
5. **Feasibility** — Can this be implemented within the existing codebase?
6. **Constitution alignment** — Does it follow the project constitution at `.steel/constitution.md`?

## Context

The project is `emacs-mcp`, an Emacs Lisp package that exposes an MCP server from a running Emacs instance. The relevant source files are:

- `emacs-mcp.el` — Main module, server start/stop, global state
- `emacs-mcp-session.el` — Session management (create, lookup, timeout)
- `emacs-mcp-protocol.el` — MCP method handlers (initialize, tools/list, etc.)
- `emacs-mcp-transport.el` — HTTP transport, session validation, routing
- `emacs-mcp-tools-builtin.el` — Built-in tool implementations

The current architecture: a single HTTP server, multiple sessions (each with a UUID), but all sessions share the same global `project-dir`. The session struct already has a `project-dir` field — it's just always set to the same global value.

## Review Format

For each issue found, use this format:

```
### [SEVERITY] Title
- **Location:** Which section/requirement
- **Issue:** What's wrong
- **Suggestion:** How to fix it
```

Severity levels:
- **BLOCKING** — Must be fixed before the spec can be approved
- **WARNING** — Should be fixed but not a showstopper
- **NOTE** — Minor improvement or style suggestion

## Final Verdict

End your review with exactly one of these lines:

```
VERDICT: APPROVE
```

or

```
VERDICT: REVISE
```

Use APPROVE only if there are zero BLOCKING issues.
