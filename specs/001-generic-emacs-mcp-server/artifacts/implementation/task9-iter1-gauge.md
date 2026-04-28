# Gauge Review: Task 9 — Transport Core Routing (Iteration 1)

## Issues Found

### BLOCKING

**1. POST handler crashes on nil/empty body**

```elisp
(condition-case _err
    (emacs-mcp--jsonrpc-parse body)
  (json-parse-error nil))
```

If `body` is `nil` (POST with no body), `json-parse-string nil` raises `wrong-type-argument`, NOT `json-parse-error`. This propagates uncaught and crashes the handler.

**Fix:** Check for nil/empty body before parsing, or expand the `condition-case` to catch `wrong-type-argument`.

---

**2. GET handler deferred delivery bug — serializes in-progress entries**

```elisp
(maphash (lambda (req-id resp)
           (emacs-mcp--http-send-sse-event
            process
            (emacs-mcp--jsonrpc-serialize resp))  ; <-- BUG
           (remhash req-id deferred))
         (copy-hash-table deferred))
```

The deferred hash contains TWO types of values:
- **In-progress:** `(:process PROC :session-id SID)` — a plist
- **Completed:** JSON-RPC response alist

The code blindly serializes ALL entries. Serializing an in-progress plist produces garbage JSON like `{":process": ..., ":session-id": ...}`, corrupting the SSE stream.

**Fix:** Check if entry is a completed response (has `jsonrpc` key or similar marker) before serializing.

---

**3. Test coverage does not meet verification criteria**

The task lists 13 verification criteria. The test file covers only:
- Session validation (4 tests)
- Two inline pcase expressions (not the actual `emacs-mcp--transport-send-http-error` function)

**Missing test coverage for:**
- POST with `initialize` → session created, `Mcp-Session-Id` header returned
- POST with valid session → protocol dispatch called
- POST without session header (non-initialize) → 400
- POST with unknown/expired session → 404
- POST with notifications-only → 202
- POST with batch of 2 requests → JSON array
- POST with `initialize` in batch → `-32600`
- POST with malformed JSON → `-32700`
- GET without session → 400
- DELETE without session → 400
- DELETE with valid session → 200, session removed

The two "error helper" tests are meaningless:
```elisp
(ert-deftest emacs-mcp-test-transport-error-400 ()
  (let ((reason (pcase 400 (400 "Bad Request") (_ "Error"))))
    (should (equal reason "Bad Request"))))
```
This tests a local pcase, not `emacs-mcp--transport-send-http-error`.

---

### WARNING

**4. No fallthrough for unhandled HTTP methods**

```elisp
(pcase method
  ("POST" ...)
  ("GET" ...)
  ("DELETE" ...))
;; No `_` arm — PUT/PATCH/OPTIONS return nil, client hangs
```

Should return 405 Method Not Allowed for unknown methods.

---

**5. `emacs-mcp--transport-validate-session` returns session struct but callers ignore it**

The function returns `(cons session session-id)` on success. Every call site:
1. Checks `(eq (car validation) :error)`
2. Extracts `(cdr validation)` for session-id
3. **Re-fetches** session via `(emacs-mcp--session-get session-id)`

The session struct in `car` is never used. Either:
- Remove it from the return value (simpler), or
- Use it directly (more efficient)

---

### NOTE

**6. Initialize path: no response on nil dispatch result**

```elisp
((equal method "initialize")
 (let ((resp (emacs-mcp--protocol-dispatch msg nil)))
   (when resp  ; <-- if nil, client hangs
     ...)))
```

If `emacs-mcp--protocol-dispatch` returns nil for initialize (shouldn't happen, but defensive code is warranted), no response is sent.

---

**7. Batch initialize detection iterates full batch after finding initialize**

```elisp
(seq-doseq (msg batch)
  (when (equal (alist-get 'method msg) "initialize")
    (setq has-init t)))  ; no break
```

Inefficient but not incorrect. Could use `seq-find` or `cl-some` for early exit.

---

**8. `push` on `cl-defstruct` accessor slot**

```elisp
(push process (emacs-mcp-session-sse-streams session))
```

This works only if `sse-streams` slot is not `:read-only`. Verify the struct definition. If it's read-only, this silently fails.

---

VERDICT: REVISE
