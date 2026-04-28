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
                   (unless (zerop (call-process "head" "/dev/urandom"
                                                t nil "-c" "16"))
                     (error "Failed to read from /dev/urandom"))
                   (when (/= (buffer-size) 16)
                     (error "Expected 16 bytes, got %d"
                            (buffer-size))))
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
