# Gauge Review: Task 10 — Transport SSE & Deferred Response Lifecycle (Iteration 1)

## Summary

This implementation has fundamental architectural issues in the deferred response lifecycle. The core problem: the completion-to-delivery path is broken for connected clients, and several hash table mutation patterns are incorrect.

---

## BLOCKING Issues

### 1. Missing Required API Functions

**Location**: Entire file
**Issue**: Task spec requires implementing:
- `emacs-mcp--transport-open-sse-stream`
- `emacs-mcp--transport-send-sse-event`
- `emacs-mcp--transport-handle-deferred`

None of these named functions exist. The code delegates directly to `emacs-mcp--http-*` functions or inlines the logic.

**Impact**: External callers expecting these entry points cannot use them. The transport layer doesn't expose the specified API.

---

### 2. `plist-put` Does Not Update Hash Table

**Location**: `emacs-mcp--transport-open-deferred-sse` disconnect handler
```elisp
(let ((entry (gethash request-id (emacs-mcp-session-deferred session))))
  (when (and entry (listp entry))
    (plist-put entry :process nil)))
```

**Issue**: `plist-put` may return a new list rather than mutating in-place when the key doesn't exist at `car`. The hash table still holds the original list. The updated plist is discarded.

**Fix**:
```elisp
(puthash request-id
         (plist-put entry :process nil)
         (emacs-mcp-session-deferred session))
```

---

### 3. `emacs-mcp-complete-deferred` Does Not Deliver to Live Stream

**Location**: Integration gap
**Issue**: Per task spec: "When called, write response as SSE event on the stored stream, close the stream, remove deferred entry."

Current behavior: `emacs-mcp-complete-deferred` stores the response in the hash. It does NOT:
- Check if `:process` is still live
- Send the SSE event to the open stream
- Close the connection
- Remove the deferred entry

A connected client waits forever for a response that is sitting in the hash table.

---

### 4. GET Handler Serializes In-Progress Plists as Responses

**Location**: `emacs-mcp--transport-handle-get`
```elisp
(maphash (lambda (req-id resp)
           (emacs-mcp--http-send-sse-event
            process
            (emacs-mcp--jsonrpc-serialize resp))
           (remhash req-id deferred))
         (copy-hash-table deferred))
```

**Issue**: The deferred hash contains two value types:
- In-progress: `(:process PROC :session-id SID)`
- Completed: `((jsonrpc . "2.0") (id . N) (result . ...))`

This code serializes both. In-progress plists become malformed JSON sent to the client.

**Fix**: Check for completed responses before serializing:
```elisp
(when (alist-get 'jsonrpc resp)  ; Only completed responses have jsonrpc key
  ...)
```

---

### 5. Timeout Timer Not Cancelled on Successful Completion

**Location**: `emacs-mcp--transport-open-deferred-sse`
```elisp
(run-at-time emacs-mcp-deferred-timeout nil
             #'emacs-mcp--transport-deferred-timeout
             session-id request-id)
```

**Issue**: The timer reference is discarded. When `emacs-mcp-complete-deferred` is called, the timer continues running. If the client disconnects after completion but before reconnecting, the timeout fires and calls `remhash` — removing the completed response before the client can retrieve it.

**Fix**: Store the timer in the deferred entry:
```elisp
(let ((timer (run-at-time ...)))
  (puthash request-id
           (list :process process :session-id session-id :timer timer)
           ...))
```
Cancel the timer in `emacs-mcp-complete-deferred`.

---

### 6. SSE Stream Never Closes After Successful GET Delivery

**Location**: `emacs-mcp--transport-handle-get` (end of function)
**Issue**: After delivering completed responses via `maphash`, the function returns without closing the connection. The SSE stream stays open indefinitely.

Contrast with timeout path (`emacs-mcp--transport-deferred-timeout`) which does call `emacs-mcp--http-close-connection`.

---

### 7. Batch SSE Lacks Completion Tracking

**Location**: `emacs-mcp--transport-open-batch-sse`
**Issue**: Multiple deferred entries share one connection. Each entry's timeout independently tries to close the connection. There's no tracking of "all entries resolved → close stream."

Scenario: Batch with 2 deferred requests. Request A times out, closes connection. Request B's timeout fires, finds `(process-live-p proc)` is nil, silently removes entry without sending error. Client receives only one timeout error.

---

## WARNING Issues

### 8. Undefined Function Reference

**Location**: `emacs-mcp--transport-deferred-timeout`
```elisp
(emacs-mcp--wrap-tool-error "Deferred operation timed out")
```

**Issue**: `emacs-mcp--wrap-tool-error` is not defined in this file and no `require` imports it. Byte-compilation will warn about unknown function.

**Fix**: Add `(require 'emacs-mcp-tools)` or whichever file defines this function.

---

### 9. Disconnect Sentinel Mechanism Unverified

**Location**: `emacs-mcp--transport-open-deferred-sse`
```elisp
(process-put process :on-disconnect
             (lambda (_proc) ...))
```

**Issue**: Emacs network processes do NOT automatically invoke `:on-disconnect` properties. This only works if `emacs-mcp-http.el` installs a sentinel that explicitly checks for and calls this property. If it doesn't, the disconnect handler never fires.

---

## NOTE Issues

### 10. Timeout Handler Works by Accident

**Location**: `emacs-mcp--transport-deferred-timeout`
**Note**: When the timeout fires on a completed entry (JSON-RPC alist), `(plist-get entry :process)` returns nil because the alist doesn't have a `:process` key. The guard fails, no SSE event is sent, and `remhash` cleans up. This is correct behavior but relies on `plist-get` returning nil for non-plists rather than explicit type checking.

---

### 11. Test Coverage Entirely Absent

**Location**: `test/emacs-mcp-test-transport.el`
**Note**: Zero tests for:
- `emacs-mcp--transport-open-deferred-sse`
- `emacs-mcp--transport-deferred-timeout`
- `emacs-mcp--transport-open-batch-sse`
- GET reconnection with deferred responses
- Batch SSE delivery

The forge note suggests deferring to Task 13 integration tests, but the BLOCKING bugs above would be caught by basic unit tests.

---

## Required Changes

1. **Add missing functions**: `emacs-mcp--transport-open-sse-stream`, `emacs-mcp--transport-send-sse-event`, `emacs-mcp--transport-handle-deferred` as specified
2. **Fix plist-put mutation**: Update hash table with returned value
3. **Implement active delivery**: When `emacs-mcp-complete-deferred` is called with a live process, send SSE event immediately
4. **Add type check in GET handler**: Only serialize completed responses
5. **Store and cancel timeout timers**: Track timer reference, cancel on completion
6. **Close connection after delivery**: Add close call after GET delivers all responses
7. **Track batch completion**: Count pending deferred entries, close when all resolved
8. **Add require statement**: `(require 'emacs-mcp-tools)` or equivalent
9. **Verify sentinel mechanism**: Confirm `emacs-mcp-http.el` invokes `:on-disconnect`

---

VERDICT: REVISE
