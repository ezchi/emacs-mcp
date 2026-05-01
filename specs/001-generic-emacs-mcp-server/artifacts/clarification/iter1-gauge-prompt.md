# Gauge Review: Clarification Iteration 1

You are the Gauge — an independent reviewer for the clarification stage.

## Context

**Project**: `emacs-mcp` — Generic Emacs MCP server package (standalone, client-agnostic).
**MCP version**: 2025-03-26, Streamable HTTP transport.
**Constitution**: Emacs-native, MCP-compliant, zero external deps, AGPL-3.0, user control, Emacs 29+.

**User input for this clarification stage**: "let user customize the port and raise error if the port is not usable."

## Files to Review

1. **Clarifications**: /Users/ezchi/Projects/emacs-mcp/specs/001-generic-emacs-mcp-server/clarifications.md
2. **Updated spec**: /Users/ezchi/Projects/emacs-mcp/specs/001-generic-emacs-mcp-server/spec.md

## What Changed

7 clarifications were identified. 4 result in spec updates, 2 are context-only (no spec change), 1 provides implementation guidance:

**[SPEC UPDATE] changes applied:**
1. FR-1.6: Default port changed from nil (auto) to `38840` (fixed). Added range validation (1-65535). Added `user-error` on bind failure with message format.
2. FR-4.2: `emacs-mcp-project-directory` formally declared as defcustom with `:type` and default nil.
3. FR-6.1/6.2/6.3: `emacs-mcp-start`, `emacs-mcp-stop`, `emacs-mcp-restart` explicitly marked as interactive commands with `;;;###autoload`.
4. FR-1.2 GET: Resolved GET ambiguity — server supports SSE streams (not 405). GET requires valid `Mcp-Session-Id`.

**[NO SPEC CHANGE]:**
5. Tool wire names are kebab-case MCP tool names, not Emacs function names.
6. Stale lockfile cleanup on startup (implementation guidance).

## Review Criteria

1. **Clarifications quality**: Complete, logical, aligned with constitution? All ambiguities resolved?
2. **Spec updates correctness**: For each [SPEC UPDATE], verify the change was correctly applied to spec.md. Check consistency with rest of spec.
3. **Missed updates**: Any [NO SPEC CHANGE] items that should actually update the spec?
4. **Changelog**: Entries accurate?
5. **User feedback addressed**: Does C-1 adequately address the user's input about port customization and error handling?

End with: `VERDICT: APPROVE` or `VERDICT: REVISE`
