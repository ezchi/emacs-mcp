# Specification: Per-Session Project Directory

**Spec ID:** 002-per-session-project-directory
**Status:** Draft
**Date:** 2026-04-29

## Overview

Currently, all MCP sessions share a single global project directory
determined at server startup. This prevents multiple LLM agents from
working on different projects through the same Emacs MCP server instance.

This feature allows each MCP client to specify its own project directory
during initialization and change it mid-session, making the per-session
`project-dir` field in `emacs-mcp-session` actually per-session.

## User Stories

**US-1:** As an LLM agent connecting to Emacs MCP, I want to specify
which project directory my session should use, so that my tools are
scoped to the correct project even when other agents use different
projects.

**US-2:** As an LLM agent, I want to change my session's project
directory after initialization, so that I can switch projects without
tearing down the session.

**US-3:** As an Emacs user running the MCP server, I want the server to
validate client-requested project directories, so that clients cannot
escape the filesystem boundaries I control.

## Functional Requirements

### FR-1: Client-Specified Project Directory at Initialize

The `initialize` request handler (`emacs-mcp--handle-initialize`) SHALL
accept an optional `projectDir` field in the `params` object. When
present:

- The value MUST be a string containing an absolute directory path.
- The server MUST validate the path (see FR-3).
- The validated path is stored in the session's `project-dir` slot.

If `projectDir` is present but fails validation, the server SHALL return
a JSON-RPC error response (error code -32602, invalid params) and SHALL
NOT create a session.

When absent, the current fallback chain applies unchanged:
1. `emacs-mcp--project-dir` (global, set at server startup)
2. `emacs-mcp--resolve-project-dir` fallback

### FR-2: Mid-Session Project Directory Change

A new MCP method `emacs-mcp/setProjectDir` SHALL be added to the method
dispatch table. This is a JSON-RPC **request** (not notification)
requiring a valid session.

**Request params:**
```json
{
  "projectDir": "/absolute/path/to/project"
}
```

**Behavior:**
- Requires a valid `Mcp-Session-Id` header (existing session validation).
- The session MUST be in `ready` state (after `notifications/initialized`).
  If still `initializing`, return JSON-RPC error (code -32600, invalid
  request) with message "Session not ready".
- The `projectDir` param MUST be a string containing an absolute
  directory path.
- The server MUST validate the path (see FR-3).
- On success, updates the session's `project-dir` slot and returns the
  new project directory. Already-dispatched deferred tool operations
  retain the project context captured at dispatch time; only tool calls
  dispatched after the change use the new project directory.
- On failure, returns a JSON-RPC error (error code -32602, invalid
  params). The session's project directory is unchanged.

**Response result:**
```json
{
  "projectDir": "/validated/absolute/path"
}
```

### FR-3: Project Directory Validation

A new function `emacs-mcp--validate-project-dir` SHALL validate
client-supplied project directory paths. Validation rules, applied in
this order:

1. The value MUST be a non-empty string.
2. The path MUST be absolute (`file-name-absolute-p`).
3. Canonicalize the client path: `expand-file-name` then `file-truename`.
4. The canonical path MUST refer to an existing directory
   (`file-directory-p`).
5. If `emacs-mcp-allowed-project-directories` is non-nil (see FR-4),
   canonicalize each allowlist entry the same way (`expand-file-name` +
   `file-truename`), then check the canonical client path is within one
   of them (`file-in-directory-p`). Both sides MUST be in canonical form
   before comparison.

On validation failure, signal an error with a descriptive message. When
rejecting a path because it is outside the allowlist, the error message
MUST NOT enumerate the allowed directories (to prevent information
leakage about the server's filesystem layout). Use a generic message
such as "Project directory not in allowed list".
On success, return the expanded, canonical path
(`expand-file-name` + `file-truename` to resolve symlinks).

### FR-4: Allowed Project Directories (Security Boundary)

A new `defcustom` `emacs-mcp-allowed-project-directories` SHALL be
added:

- **Type:** list of directory paths (or nil).
- **Default:** nil (no restriction — any existing directory is allowed).
- **Behavior:** When non-nil, client-requested project directories MUST
  be within one of the listed directories. This prevents clients from
  requesting access to arbitrary filesystem locations.
- **Group:** `emacs-mcp`.

### FR-5: Hook on Project Directory Change

The existing `emacs-mcp-client-connected-hook` already fires on session
creation. A new hook `emacs-mcp-project-dir-changed-hook` SHALL fire
when a session's project directory changes via `emacs-mcp/setProjectDir`
and the new canonical directory differs from the current one. The hook
SHALL NOT fire when the resolved directory equals the session's existing
`project-dir`.

**Arguments:** session-id, old-project-dir, new-project-dir.

This enables integrations (e.g., lockfile updates, buffer rescanning)
to react to project switches.

## Non-Functional Requirements

### NFR-1: Backward Compatibility

Existing clients that do not send `projectDir` in `initialize` MUST
continue to work exactly as before. The fallback to the global
`emacs-mcp--project-dir` is preserved.

### NFR-2: No Load-Time Side Effects

The new `defcustom` and hook variable MUST NOT trigger network calls or
process creation at load time (constitution principle 1, constraint 1).

### NFR-3: Naming Conventions

All new public symbols use the `emacs-mcp-` prefix. All internal
symbols use `emacs-mcp--`. The custom method name uses the `emacs-mcp/`
namespace prefix per MCP convention for server-specific extensions.

### NFR-4: Docstrings and Byte-Compilation

All new functions, variables, and custom options MUST have docstrings
passing `checkdoc`. All code MUST byte-compile cleanly with no warnings.

## Acceptance Criteria

**AC-1:** Two clients connecting simultaneously can have different
`project-dir` values in their sessions by sending different `projectDir`
values in their `initialize` requests.

**AC-2:** A connected client can call `emacs-mcp/setProjectDir` and
subsequent tool calls in that session use the new project directory for
path authorization and project scoping.

**AC-3:** A client sending a `projectDir` that fails validation receives
a JSON-RPC error response (error code -32602, invalid params) and the
session's project directory is unchanged.

**AC-4:** When `emacs-mcp-allowed-project-directories` is set and a
client requests a directory outside the allowlist, the request is
rejected with a clear error message.

**AC-5:** A client that does not send `projectDir` in `initialize` gets
the same behavior as before this change (global fallback).

**AC-6:** `emacs-mcp-project-dir-changed-hook` fires with correct
arguments when `emacs-mcp/setProjectDir` succeeds and the canonical
project directory actually changes. The hook does NOT fire when the
resolved directory equals the current one.

**AC-7:** All new code byte-compiles without warnings and passes
`checkdoc`.

## Out of Scope

- **MCP `roots` capability**: The MCP specification defines a `roots`
  mechanism (client-advertised filesystem roots, `roots/list` server
  request, `notifications/roots/list_changed`). Full `roots` support is
  a separate, larger feature. This spec addresses the immediate need
  with a simpler, server-extension approach. A future spec may implement
  `roots` and deprecate or layer on top of `emacs-mcp/setProjectDir`.

- **Multiple project directories per session**: Each session has exactly
  one project directory. Supporting multiple concurrent project roots per
  session (like MCP `roots`) is out of scope.

- **Lockfile updates on project change**: The lockfile system currently
  records the server-wide project directory. Updating lockfiles per
  session is not addressed here.

- **Tool re-registration on project change**: Tools are registered
  globally, not per-session. Per-session tool visibility is out of scope.

## Open Questions

None — all design decisions are resolved in this spec.

## Changelog

- [Clarification iter1] FR-2: Added session state requirement — `setProjectDir` requires `ready` state, returns -32600 if still `initializing`.
- [Clarification iter1] FR-3: Allowlist entries are also canonicalized before comparison to prevent tilde/symlink mismatches.
- [Clarification iter2] FR-5/AC-6: Hook fires only when canonical directory actually changes; no-op when same directory is set.
- [Clarification iter2] FR-3: Allowlist rejection error messages must not enumerate allowed directories (security).
- [Clarification iter2] FR-2: Deferred operations retain project context from dispatch time; new dir applies only to later calls.
- [Clarification iter2] FR-3: Explicit validation order — canonicalize client path first, then canonicalize allowlist entries, then compare.
