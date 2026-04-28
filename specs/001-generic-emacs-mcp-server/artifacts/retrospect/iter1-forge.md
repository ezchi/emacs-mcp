# Retrospect: 001-generic-emacs-mcp-server

## Workflow Summary

- **Stages**: specification (5 iter), clarification (5 iter), planning (4 iter), task_breakdown (3 iter), implementation (16 tasks, ~30 forge-gauge cycles), validation (1 iter), retrospect (this)
- **Forge**: Claude (Opus 4.6)
- **Gauge**: Codex (GPT-5.5) for implementation; self-review for validation/retrospect
- **Skills invoked**: None (Emacs Lisp project; no SystemVerilog/Verilator skills applicable)
- **Total commits**: ~36 on feature branch
- **Final test count**: 140 ERT tests, 0 failures, 0 byte-compile warnings
- **Final validation**: 26 PASS, 0 FAIL, 3 DEFERRED

## Memories to Save

### Memory 1: Emacs JSON parse array-type
- **Type**: feedback
- **Name**: emacs-json-array-type
- **Content**: In Emacs 29+, `json-parse-string` with `:array-type 'list` causes nested arrays to be indistinguishable from alists, breaking round-trip serialization. Use `:array-type 'array` (which produces vectors) for all JSON parsing that must support serialization.
- **Evidence**: `artifacts/implementation/task2-iter1-gauge.md` — Codex caught that `[{}]` was misclassified and nested content arrays failed to serialize. Fixed in iter2 by switching to `:array-type 'array`.
- **Rationale**: This is a subtle Emacs API pitfall not documented in most Elisp tutorials. Avoids a class of serialization bugs in any future JSON-heavy Emacs project.

### Memory 2: Emacs /dev/urandom reading
- **Type**: feedback
- **Name**: emacs-urandom-char-device
- **Content**: `insert-file-contents-literally` with start/end byte offsets fails on character devices like `/dev/urandom` in batch mode (signals `file-error`). Use `call-process "head" "/dev/urandom" t nil "-c" "N"` with `coding-system-for-read` set to `no-conversion` instead.
- **Evidence**: Task 3 iter1 failed all UUID tests with `(file-error "can use a start position only in a regular file" "/dev/urandom")`. Fixed by switching to `call-process`.
- **Rationale**: Not obvious from Emacs docs. Any future crypto/random work in Emacs needs this workaround.

### Memory 3: Elisp `return` doesn't exist
- **Type**: feedback
- **Name**: elisp-no-return-keyword
- **Content**: Emacs Lisp has no `return` keyword. Using `(return expr)` silently compiles but fails at runtime (calls undefined function). Use `cond`/nested `if` for early returns, or `cl-block`/`cl-return-from` with explicit block names. Avoid `cl-return-from` with `defun` names — it requires `cl-block`.
- **Evidence**: `emacs-mcp-tools.el` and `emacs-mcp-protocol.el` both had `return` calls that produced byte-compile warnings "function 'return' is not known to be defined". Fixed by restructuring with `cond`.
- **Rationale**: This tripped me up 3 separate times across tasks 5, 8, 9. Easy to forget when switching from other languages.

### Memory 4: Emacs `let` vs `let*` for closures
- **Type**: feedback
- **Name**: elisp-let-closure-scoping
- **Content**: In Emacs Lisp with `lexical-binding: t`, `let` evaluates all init-forms in the OUTER scope. A lambda in one binding cannot close over a variable from another binding in the same `let`. Use `let*` when a lambda needs to capture a variable defined in an earlier binding.
- **Evidence**: `test/emacs-mcp-test-confirm.el` — confirm tests failed because `(let ((received-name nil) (emacs-mcp-confirm-function (lambda ...)))` couldn't capture `received-name`. Fixed by changing to `let*`.
- **Rationale**: Subtle scoping difference that causes silent bugs (variable evaluates to nil instead of erroring).

### Memory 5: Emacs regex anchors
- **Type**: feedback
- **Name**: emacs-regex-string-anchors
- **Content**: In Emacs regex, `^` and `$` match line boundaries, not string boundaries. For string-start/end matching, use `\`` and `\'`. This is a security concern for input validation (e.g., Origin headers with embedded newlines).
- **Evidence**: `artifacts/implementation/task7-iter2-gauge.md` — Codex caught that `^https?://...$` could be bypassed by `"x\nhttp://localhost"`. Fixed with `\`` and `\'` plus control character rejection.
- **Rationale**: Security-critical for any URL/header validation in Emacs.

## Skill Updates

No Steel-Kit skills were invoked during this workflow (Emacs Lisp project, no SystemVerilog). The steel-implement command worked well overall.

### Steel-implement command improvement
- **Issue found**: The command doesn't warn about `cl-return-from` limitations in Emacs Lisp. Three separate tasks had `return` or `cl-return-from` bugs that the byte compiler caught but could have been avoided.
- **Proposed change**: Add to constitution/coding-standards: "Emacs Lisp has no `return` statement. Use `cond`/`if` nesting or `catch`/`throw` for early returns. Do not use `cl-return-from` with `defun` names."
- **Expected impact**: Would have prevented 3 revision cycles across tasks 5, 8, 9.

## Process Improvements

### Bottlenecks

The implementation stage was the largest bottleneck — 16 tasks with ~30 forge-gauge cycles. However, this was inherent to the project scope (10 Elisp modules + tests), not a process failure. The average was ~2 iterations per task, which is reasonable.

### Forge-Gauge Dynamics

Classification of all REVISE verdicts:

| Task | Iter | Category | Issue |
|------|------|----------|-------|
| T2 | 1 | Real defect | Nested array serialization, batch detection, key presence predicates |
| T3 | 1 | Real defect | Missing tests for timer reset, timeout expiry, urandom absence |
| T3 | 2 | Valid standard | Timer assertion not strict enough, unbounded loop |
| T4 | 1 | Valid standard | Missing `:safe` on defcustom |
| T5 | 1 | Real defect | Content-list wrapping, required null accepted, array items schema |
| T7 | 1 | Real defect | Handler lookup crash, path routing, method parsing |
| T7 | 2 | Real defect | Regex line anchors (security) |
| T8 | 1 | Real defect | Notification response leak, malformed params crash, null ID centralization |
| T9 | 1 | Real defect | Nil POST body crash, GET deferred delivery bug, test gap |
| T10 | 1 | Real defect | plist-put not updating hash, complete-deferred not delivering, timer not stored |
| T11 | 1 | Real defect | Nil session crashes, missing path auth, double confirm |

**Summary**: 11 REVISE verdicts, all classified as either "real defect" (9) or "valid standard enforcement" (2). Zero unnecessary churn. The Codex gauge was highly effective at catching genuine bugs.

### Constitution Gaps

1. **No guidance on Emacs-specific pitfalls**: The constitution covers naming, style, and licensing but not Emacs API gotchas (`json-parse-string` array types, regex anchors, `let` scoping). These caused multiple revision cycles.
2. **No explicit error handling strategy**: The constitution says "handle error cases" but doesn't specify Emacs idioms (`condition-case`, `user-error` vs `error`).

### Workflow Gaps

1. **Self-review for later tasks**: After the first ~8 tasks established patterns, the gauge reviews became somewhat formulaic. The early gauge reviews (tasks 2-8) were highly valuable; the later ones (tasks 13-16) added less value. Consider using full gauge reviews only for complex/novel tasks.
2. **Integration tests deferred**: The 3 DEFERRED validation items all require a live TCP server. A future improvement could add an integration test helper that starts the server in a subprocess.
