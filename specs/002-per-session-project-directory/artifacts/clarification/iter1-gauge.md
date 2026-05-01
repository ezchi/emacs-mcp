# Gauge Review: Clarification Iteration 1

**Reviewer:** Codex (gpt-5.5)
**Date:** 2026-04-29
**Verdict:** REVISE

## Findings

### [BLOCKING] Same-directory hook behavior contradicts AC-6
- **Location:** CLR-4; `spec.md` FR-5 / AC-6
- **Issue:** CLR-4 says same canonical directory succeeds but `emacs-mcp-project-dir-changed-hook` SHALL NOT fire. AC-6 says the hook fires whenever `setProjectDir` succeeds. That is a direct contradiction.
- **Suggestion:** Update FR-5 and AC-6 to say the hook fires only when the canonical project directory actually changes.

### [BLOCKING] Allowlist error non-leak rule is missing from the spec
- **Location:** CLR-6; `spec.md` FR-3 / AC-4
- **Issue:** CLR-6 adds a security requirement, but it is marked `[NO SPEC CHANGE]`. The current spec only says "descriptive" / "clear" error message, which still permits leaking allowed directories.
- **Suggestion:** Update FR-3 or FR-4 to require allowlist rejection messages not enumerate allowed paths, and update AC-4 accordingly.

### [BLOCKING] Deferred-operation context rule is not specified
- **Location:** CLR-5; `spec.md` FR-2 / AC-2
- **Issue:** CLR-5 defines behavior for in-flight deferred tool operations during a project switch. That affects authorization and per-session scoping, but the spec never states it.
- **Suggestion:** Add a requirement that deferred operations retain the project context captured at dispatch time, and only later tool calls use the new project directory.

### [BLOCKING] Canonical comparison order is still ambiguous
- **Location:** CLR-3; `spec.md` FR-3
- **Issue:** CLR-3 rationale says both sides must be canonical before `file-in-directory-p`, but the applied spec only explicitly canonicalizes allowlist entries. An implementer could compare an expanded symlink path against the allowlist before resolving it, then return a canonical path outside the allowlist.
- **Suggestion:** State the validation order explicitly: expand and `file-truename` the client path before allowlist comparison, canonicalize allowlist entries the same way, then compare canonical-to-canonical.

### [WARNING] CLR-7 makes a false claim about JSON parsing defaults
- **Location:** CLR-7
- **Issue:** `json-parse-string` does not convert JSON object keys to symbols by default; bare parsing returns a hash table with string keys. This repo's wrapper does produce symbol-key alists because it passes `:object-type 'alist`.
- **Suggestion:** Rewrite the sentence to reference `emacs-mcp--jsonrpc-parse` / `:object-type 'alist`, not the default behavior.

VERDICT: REVISE
