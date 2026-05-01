# Gauge Code Review — Task 3: Session Management (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Implement `emacs-mcp-session.el`: Session lifecycle management — creation with UUID v4, lookup, activity tracking, idle timeout, and cleanup. Sessions are the core state container for connected clients.

**Functions/structures to implement**:
- `cl-defstruct emacs-mcp-session` — Fields: session-id, client-info, project-dir, state, connected-at, last-activity, deferred (hash-table), sse-streams, **timer** (idle timeout timer handle for cancellation on activity reset and session removal)
- `emacs-mcp--sessions` — Global hash-table of active sessions
- `emacs-mcp--generate-uuid` — UUID v4 from `/dev/urandom` per RFC 4122
- `emacs-mcp--session-create` — Create session, store in `emacs-mcp--sessions`, start idle timer
- `emacs-mcp--session-get` — Lookup by ID
- `emacs-mcp--session-remove` — Remove by ID, **cancel idle timer**, close SSE streams, run `emacs-mcp-client-disconnected-hook` with `run-hook-with-args` passing session ID
- `emacs-mcp--session-update-activity` — Touch `last-activity` timestamp, **cancel and restart idle timer**
- `emacs-mcp--session-start-timeout-timer` — Create idle timer via `run-at-time` using `emacs-mcp-session-timeout`; store handle in session's `timer` field
- `emacs-mcp--session-cleanup-all` — Remove all sessions (cancel all timers, close all SSE streams)
- `emacs-mcp--resolve-project-dir` — Implement FR-4.2 fallback: (1) `emacs-mcp-project-directory` if non-nil, (2) `(project-root (project-current))` if available, (3) `default-directory`

**Verification criteria**:
- UUID v4 format is correct (version nibble = 4, variant bits = 10xx)
- Session create/get/remove lifecycle works
- Activity update cancels old timer and starts new one
- Timer handle stored in session struct, cancelled on removal
- Timeout fires after configured seconds of inactivity, removes session
- `session-cleanup-all` cancels all timers and removes all sessions
- `emacs-mcp-client-disconnected-hook` called via `run-hook-with-args` with session ID on removal
- `emacs-mcp--resolve-project-dir` tested with all 3 fallback cases
- No `/dev/urandom` on non-Unix signals `user-error`
- All tests pass via `ert-run-tests-batch`
- File byte-compiles clean

## Coding Standards (from Constitution)

- Style: Follow Emacs Lisp conventions, `checkdoc` compliant
- Naming: Public symbols `emacs-mcp-`, internal `emacs-mcp--`
- Docstrings: Every public function/variable must have a docstring passing `checkdoc`
- Byte-compilation: Clean with no warnings
- Line length: 80 columns soft limit
- No `cl-lib` abuse: Use `cl-lib` where it genuinely improves clarity (e.g., `cl-defstruct`)
- No global state pollution outside the package namespace

## Full File: emacs-mcp-session.el

```elisp
;;; emacs-mcp-session.el --- Session management for emacs-mcp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; License: AGPL-3.0-or-later
;; See the file LICENSE for the full license text.

;;; Commentary:

;; This library manages MCP client sessions, including creation,
;; lookup, timeout, and teardown.  Each session is identified by a
;; cryptographically random UUID v4.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'emacs-mcp)

;;;; Session structure

(cl-defstruct (emacs-mcp-session (:constructor emacs-mcp--make-session))
  "An MCP client session."
  (session-id "" :type string)
  (client-info nil)
  (project-dir "" :type string)
  (state 'initializing :type symbol)
  (connected-at 0 :type number)
  (last-activity 0 :type number)
  (deferred (make-hash-table :test 'equal))
  (sse-streams nil :type list)
  (timer nil))

;;;; Global session store

(defvar emacs-mcp--sessions (make-hash-table :test 'equal)
  "Hash-table mapping session ID strings to `emacs-mcp-session' structs.")

;;;; UUID v4 generation

(defun emacs-mcp--generate-uuid ()
  "Generate a UUID v4 string from /dev/urandom per RFC 4122.
Signals `user-error' if /dev/urandom is unavailable."
  (unless (file-exists-p "/dev/urandom")
    (user-error "emacs-mcp: cannot generate secure session IDs \
(no /dev/urandom)"))
  (let ((bytes (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (let ((coding-system-for-read 'no-conversion))
                   (call-process "head" "/dev/urandom" t nil
                                 "-c" "16"))
                 (buffer-string))))
    ;; Set version nibble (byte 6): 0100xxxx
    (aset bytes 6 (logior #x40 (logand (aref bytes 6) #x0f)))
    ;; Set variant bits (byte 8): 10xxxxxx
    (aset bytes 8 (logior #x80 (logand (aref bytes 8) #x3f)))
    (format "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"
            (aref bytes 0) (aref bytes 1) (aref bytes 2)
            (aref bytes 3) (aref bytes 4) (aref bytes 5)
            (aref bytes 6) (aref bytes 7) (aref bytes 8)
            (aref bytes 9) (aref bytes 10) (aref bytes 11)
            (aref bytes 12) (aref bytes 13) (aref bytes 14)
            (aref bytes 15))))

;;;; Session lifecycle

(defun emacs-mcp--session-create (project-dir &optional client-info)
  "Create a new session for PROJECT-DIR with optional CLIENT-INFO.
Returns the new session ID string.  Starts the idle timeout timer."
  (let* ((id (emacs-mcp--generate-uuid))
         (now (float-time))
         (session (emacs-mcp--make-session
                   :session-id id
                   :client-info client-info
                   :project-dir project-dir
                   :state 'initializing
                   :connected-at now
                   :last-activity now
                   :deferred (make-hash-table :test 'equal)
                   :sse-streams nil
                   :timer nil)))
    (emacs-mcp--session-start-timeout-timer session)
    (puthash id session emacs-mcp--sessions)
    id))

(defun emacs-mcp--session-get (session-id)
  "Look up a session by SESSION-ID.  Returns the session or nil."
  (gethash session-id emacs-mcp--sessions))

(defun emacs-mcp--session-remove (session-id)
  "Remove the session identified by SESSION-ID.
Cancels the idle timer, closes SSE streams, and runs
`emacs-mcp-client-disconnected-hook' with the session ID."
  (let ((session (gethash session-id emacs-mcp--sessions)))
    (when session
      ;; Cancel idle timer
      (when (emacs-mcp-session-timer session)
        (cancel-timer (emacs-mcp-session-timer session)))
      ;; Close SSE streams
      (dolist (stream (emacs-mcp-session-sse-streams session))
        (when (processp stream)
          (ignore-errors (delete-process stream))))
      ;; Remove from store
      (remhash session-id emacs-mcp--sessions)
      ;; Run hook
      (run-hook-with-args 'emacs-mcp-client-disconnected-hook
                          session-id))))

;;;; Activity tracking

(defun emacs-mcp--session-update-activity (session)
  "Update the last-activity timestamp of SESSION and restart idle timer."
  (setf (emacs-mcp-session-last-activity session) (float-time))
  ;; Cancel old timer and start new one
  (when (emacs-mcp-session-timer session)
    (cancel-timer (emacs-mcp-session-timer session)))
  (emacs-mcp--session-start-timeout-timer session))

(defun emacs-mcp--session-start-timeout-timer (session)
  "Start an idle timeout timer for SESSION.
On expiry, the session is removed via `emacs-mcp--session-remove'."
  (setf (emacs-mcp-session-timer session)
        (run-at-time emacs-mcp-session-timeout nil
                     #'emacs-mcp--session-timeout-handler
                     (emacs-mcp-session-session-id session))))

(defun emacs-mcp--session-timeout-handler (session-id)
  "Handle idle timeout for SESSION-ID by removing the session."
  (emacs-mcp--session-remove session-id))

;;;; Cleanup

(defun emacs-mcp--session-cleanup-all ()
  "Remove all sessions, cancelling all timers and closing SSE streams."
  (maphash (lambda (id _session)
             (emacs-mcp--session-remove id))
           (copy-hash-table emacs-mcp--sessions)))

;;;; Project directory resolution

(defun emacs-mcp--resolve-project-dir ()
  "Resolve the project directory for the MCP server.
Uses the following fallback chain:
1. `emacs-mcp-project-directory' if non-nil.
2. `project-root' of `project-current' if available.
3. `default-directory'."
  (or emacs-mcp-project-directory
      (when-let* ((proj (project-current)))
        (project-root proj))
      default-directory))

(provide 'emacs-mcp-session)
;;; emacs-mcp-session.el ends here
```

## Full File: test/emacs-mcp-test-session.el

```elisp
;;; emacs-mcp-test-session.el --- Tests for emacs-mcp-session -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for session management.

;;; Code:

(require 'ert)
(require 'emacs-mcp-session)

;;;; Test helpers

(defmacro emacs-mcp-test-with-clean-sessions (&rest body)
  "Run BODY with a fresh empty session store."
  (declare (indent 0))
  `(let ((emacs-mcp--sessions (make-hash-table :test 'equal))
         (emacs-mcp-session-timeout 1800))
     (unwind-protect
         (progn ,@body)
       ;; Clean up any timers
       (maphash (lambda (_id session)
                  (when (emacs-mcp-session-timer session)
                    (cancel-timer (emacs-mcp-session-timer session))))
                emacs-mcp--sessions))))

;;;; UUID tests

(ert-deftest emacs-mcp-test-session-uuid-format ()
  "UUID v4 has correct format: 8-4-4-4-12 hex digits."
  (let ((uuid (emacs-mcp--generate-uuid)))
    (should (string-match-p
             "^[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}$"
             uuid))))

(ert-deftest emacs-mcp-test-session-uuid-version-nibble ()
  "UUID v4 has version nibble = 4."
  (let ((uuid (emacs-mcp--generate-uuid)))
    (should (= (aref uuid 14) ?4))))

(ert-deftest emacs-mcp-test-session-uuid-variant-bits ()
  "UUID v4 has variant bits = 10xx (char 8, 9, a, or b)."
  (let ((uuid (emacs-mcp--generate-uuid)))
    (should (memq (aref uuid 19) '(?8 ?9 ?a ?b)))))

(ert-deftest emacs-mcp-test-session-uuid-uniqueness ()
  "Two UUIDs are different."
  (should-not (equal (emacs-mcp--generate-uuid)
                     (emacs-mcp--generate-uuid))))

;;;; Session lifecycle tests

(ert-deftest emacs-mcp-test-session-create ()
  "Create a session and retrieve it."
  (emacs-mcp-test-with-clean-sessions
    (let ((id (emacs-mcp--session-create "/tmp/project")))
      (should (stringp id))
      (should (emacs-mcp--session-get id))
      (should (equal (emacs-mcp-session-project-dir
                      (emacs-mcp--session-get id))
                     "/tmp/project")))))

(ert-deftest emacs-mcp-test-session-create-with-client-info ()
  "Create a session with client info."
  (emacs-mcp-test-with-clean-sessions
    (let* ((info '((name . "test") (version . "1.0")))
           (id (emacs-mcp--session-create "/tmp" info)))
      (should (equal (emacs-mcp-session-client-info
                      (emacs-mcp--session-get id))
                     info)))))

(ert-deftest emacs-mcp-test-session-initial-state ()
  "New session starts in initializing state."
  (emacs-mcp-test-with-clean-sessions
    (let* ((id (emacs-mcp--session-create "/tmp"))
           (session (emacs-mcp--session-get id)))
      (should (eq (emacs-mcp-session-state session)
                  'initializing)))))

(ert-deftest emacs-mcp-test-session-remove ()
  "Remove a session."
  (emacs-mcp-test-with-clean-sessions
    (let ((id (emacs-mcp--session-create "/tmp")))
      (should (emacs-mcp--session-get id))
      (emacs-mcp--session-remove id)
      (should-not (emacs-mcp--session-get id)))))

(ert-deftest emacs-mcp-test-session-remove-runs-hook ()
  "Removing a session runs the disconnected hook with session ID."
  (emacs-mcp-test-with-clean-sessions
    (let ((hook-called nil)
          (emacs-mcp-client-disconnected-hook nil))
      (add-hook 'emacs-mcp-client-disconnected-hook
                (lambda (sid) (setq hook-called sid)))
      (let ((id (emacs-mcp--session-create "/tmp")))
        (emacs-mcp--session-remove id)
        (should (equal hook-called id))))))

(ert-deftest emacs-mcp-test-session-remove-nonexistent ()
  "Removing a non-existent session is a no-op."
  (emacs-mcp-test-with-clean-sessions
    (emacs-mcp--session-remove "nonexistent")))

;;;; Activity tracking tests

(ert-deftest emacs-mcp-test-session-activity-update ()
  "Activity update changes last-activity timestamp."
  (emacs-mcp-test-with-clean-sessions
    (let* ((id (emacs-mcp--session-create "/tmp"))
           (session (emacs-mcp--session-get id))
           (old-time (emacs-mcp-session-last-activity session)))
      ;; Small delay to ensure different timestamp
      (sleep-for 0.01)
      (emacs-mcp--session-update-activity session)
      (should (> (emacs-mcp-session-last-activity session)
                 old-time)))))

(ert-deftest emacs-mcp-test-session-timer-exists ()
  "Session has a timer after creation."
  (emacs-mcp-test-with-clean-sessions
    (let* ((id (emacs-mcp--session-create "/tmp"))
           (session (emacs-mcp--session-get id)))
      (should (timerp (emacs-mcp-session-timer session))))))

(ert-deftest emacs-mcp-test-session-timer-cancelled-on-remove ()
  "Timer is cancelled when session is removed."
  (emacs-mcp-test-with-clean-sessions
    (let* ((id (emacs-mcp--session-create "/tmp"))
           (session (emacs-mcp--session-get id))
           (timer (emacs-mcp-session-timer session)))
      (emacs-mcp--session-remove id)
      ;; Timer should have been cancelled
      (should-not (memq timer timer-list)))))

;;;; Cleanup tests

(ert-deftest emacs-mcp-test-session-cleanup-all ()
  "Cleanup removes all sessions."
  (emacs-mcp-test-with-clean-sessions
    (emacs-mcp--session-create "/tmp/a")
    (emacs-mcp--session-create "/tmp/b")
    (should (= (hash-table-count emacs-mcp--sessions) 2))
    (emacs-mcp--session-cleanup-all)
    (should (= (hash-table-count emacs-mcp--sessions) 0))))

;;;; Resolve project directory tests

(ert-deftest emacs-mcp-test-resolve-project-dir-defcustom ()
  "Returns defcustom value when non-nil."
  (let ((emacs-mcp-project-directory "/custom/path"))
    (should (equal (emacs-mcp--resolve-project-dir)
                   "/custom/path"))))

(ert-deftest emacs-mcp-test-resolve-project-dir-default-directory ()
  "Returns default-directory when defcustom is nil and no project."
  (let ((emacs-mcp-project-directory nil)
        (default-directory "/fallback/"))
    (cl-letf (((symbol-function 'project-current)
               (lambda () nil)))
      (should (equal (emacs-mcp--resolve-project-dir)
                     "/fallback/")))))

(ert-deftest emacs-mcp-test-resolve-project-dir-project-current ()
  "Returns project-root when defcustom is nil but project exists."
  (let ((emacs-mcp-project-directory nil))
    (cl-letf (((symbol-function 'project-current)
               (lambda () '(vc Git "/project/root/")))
              ((symbol-function 'project-root)
               (lambda (_proj) "/project/root/")))
      (should (equal (emacs-mcp--resolve-project-dir)
                     "/project/root/")))))

(provide 'emacs-mcp-test-session)
;;; emacs-mcp-test-session.el ends here
```

## Test Results

All 16 tests pass. Byte-compilation clean (no warnings).

## Review Checklist

1. **Correctness**: Does the code implement all required functions/structures? Any logic errors in UUID generation, timer management, or project resolution?
2. **Code quality**: Clean, readable, well-structured? Appropriate use of `cl-defstruct`?
3. **Constitution compliance**: Naming conventions (`emacs-mcp--` for internal), docstrings, byte-compile clean, 80-col soft limit?
4. **Security**: UUID generation from `/dev/urandom` — is it cryptographically sound? Error handling for missing `/dev/urandom`?
5. **Error handling**: Graceful handling of nonexistent sessions, timer cancellation, SSE stream cleanup?
6. **Test coverage**: All key paths covered? UUID format/version/variant/uniqueness, create/get/remove lifecycle, activity tracking, timer management, cleanup-all, all 3 resolve-project-dir fallbacks?
7. **Performance**: Any unbounded loops or allocations? Timer leak potential?
8. **Scope creep**: Does the code stay within task requirements? No premature HTTP/transport code?

List issues with severity: BLOCKING / WARNING / NOTE
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
