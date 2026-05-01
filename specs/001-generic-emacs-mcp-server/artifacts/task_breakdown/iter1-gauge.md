# Gauge Review — Task Breakdown Iteration 1

**Reviewer**: Codex (GPT-5.5)
**Date**: 2026-04-27

### Issue 1: Invalid task dependencies
**Severity**: BLOCKING  
**Criteria**: Ordering & Dependencies  
**Details**: Task 4 verifies confirmation integration, but Task 5 implements confirmation. Task 4 cannot pass as written before Task 5. The parallel group also lists Tasks 4 and 8 together even though Task 8 depends on Task 4.  
**Suggestion**: Make Task 4 depend on Task 5 or move confirmation verification out of Task 4. Fix parallel group B so Task 8 starts only after Tasks 2, 3, 4, and 5 are complete.

### Issue 2: Shared defcustoms and hooks are defined too late
**Severity**: BLOCKING  
**Criteria**: Ordering & Dependencies, Constitution Alignment  
**Details**: Earlier modules reference variables defined only in Task 11: `emacs-mcp-session-timeout`, `emacs-mcp-deferred-timeout`, lockfile directory variables, project directory, and lifecycle hooks. Those modules are required to byte-compile cleanly before Task 11, which is not realistic without declarations or earlier definitions.  
**Suggestion**: Move core defgroup/defcustom/hook definitions into Task 1 or a dedicated config module, or require each earlier module to declare externally defined variables/functions explicitly.

### Issue 3: Session timer state is underspecified
**Severity**: MAJOR  
**Criteria**: Completeness, Verification Criteria  
**Details**: Task 3 requires idle timers to start, restart, cancel, and remove sessions, but the session struct has no timer field. Task 6.2 also requires all timers to be cancelled on shutdown. The task breakdown does not specify where idle timer handles live.  
**Suggestion**: Add an idle timer field to `emacs-mcp-session`, and add tests proving timer replacement and cancellation on session removal and server stop.

### Issue 4: Project directory semantics are not covered
**Severity**: MAJOR  
**Criteria**: Completeness  
**Details**: FR-4.2 defines exact project directory selection: `emacs-mcp-project-directory`, then `project-current`, then `default-directory`, fixed at server start. Tasks mention the defcustom and session field, but no task implements or verifies this selection contract. Built-in path authorization depends on it.  
**Suggestion**: Add an explicit helper/task requirement for resolving the server project directory at start, passing it into new sessions, and testing all three fallback cases.

### Issue 5: Transport verification misses required edge cases
**Severity**: MAJOR  
**Criteria**: Verification Criteria  
**Details**: Task 9 does not verify syntactically invalid `Mcp-Session-Id` returns HTTP 400, DELETE with unknown session returns HTTP 404, Accept headers are ignored, or mixed immediate/deferred batch responses use SSE and close correctly. These are explicit FR-1.2 and FR-4.1 requirements.  
**Suggestion**: Add Task 9 tests for invalid session-id syntax, unknown DELETE, missing/unexpected Accept headers, and batch behavior with mixed immediate/deferred responses.

### Issue 6: Hook argument contract is not testable
**Severity**: MAJOR  
**Criteria**: Completeness, Constitution Alignment  
**Details**: FR-8.3 says hooks receive arguments: started gets port, connected/disconnected get session ID. Task 11 only says hooks fire at correct times. That can pass while using `run-hooks`, which would violate the spec.  
**Suggestion**: Require `run-hook-with-args` behavior and add tests asserting hook functions receive the documented arguments.

### Issue 7: Task granularity is too coarse
**Severity**: MAJOR  
**Criteria**: Granularity  
**Details**: Task 9 combines transport routing, session validation, JSON-RPC batch handling, SSE lifecycle, deferred storage, timeout, and reconnection. Task 10 implements ten built-in tools plus authorization and feature flags. These are not single focused sessions.  
**Suggestion**: Split Task 9 into routing/session validation, POST/batch handling, and SSE/deferred handling. Split Task 10 into shared helpers/config, buffer/file tools, introspection tools, diagnostics/xref tools, and `execute-elisp`.

### Issue 8: Zero external dependency verification is weak
**Severity**: MINOR  
**Criteria**: Completeness, Constitution Alignment  
**Details**: NFR-2 requires no required external dependencies, but no task explicitly checks `Package-Requires` stays limited to Emacs or that optional `flycheck` remains runtime-detected only.  
**Suggestion**: Add validation in Task 14 or CI that package metadata has no required dependencies beyond Emacs and that optional packages are guarded with `require ... nil t` or equivalent runtime checks.

VERDICT: REVISE
