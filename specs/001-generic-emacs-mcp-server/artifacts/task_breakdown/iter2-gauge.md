# Gauge Review — Task Breakdown Iteration 2

**Reviewer**: Codex (GPT-5.5)
**Date**: 2026-04-27

Previous BLOCKING issues (1, 2) resolved. Previous MAJOR issues (3-7) resolved. Previous MINOR issue (8) resolved. Three new MAJOR issues found.

### Issue 1: Session activity is not wired into request handling
**Severity**: MAJOR  
**Criteria**: Completeness, Verification Criteria  
**Details**: Task 3 defines `emacs-mcp--session-update-activity`, but Task 9 never requires POST/GET/DELETE request handling to call it. FR-4.2 requires `last-activity` to update on every request, and FR-4.5 defines idle timeout by request activity. The task breakdown can pass isolated session tests while active sessions still time out incorrectly.  
**Suggestion**: Require `emacs-mcp--transport-validate-session` or each transport handler to update activity after successful session validation. Add tests proving valid POST, GET, and DELETE request paths update `last-activity` and restart the idle timer.

### Issue 2: Task 9 granularity is still too coarse
**Severity**: MAJOR  
**Criteria**: Granularity  
**Details**: Previous Issue 7 is only partially fixed. Built-in tools were split, but Task 9 still combines transport routing, session validation, JSON parsing, batch semantics, SSE lifecycle, deferred storage, timeout handling, and reconnection behavior. That is not a single focused implementation session.  
**Suggestion**: Split Task 9 into separate tasks: routing/session validation, POST parsing and batch response semantics, and SSE/deferred lifecycle with timeout/reconnect tests.

### Issue 3: Malformed JSON transport behavior is not verified
**Severity**: MAJOR  
**Criteria**: Verification Criteria  
**Details**: FR-2.7 requires malformed JSON bodies to return JSON-RPC parse error `-32700`. Task 2 verifies the low-level parser rejects malformed JSON, but Task 9 does not verify that HTTP POST catches that failure and serializes the correct JSON-RPC error response.  
**Suggestion**: Add Task 9 verification for malformed POST bodies returning JSON-RPC `-32700` with the correct response shape.

VERDICT: REVISE
