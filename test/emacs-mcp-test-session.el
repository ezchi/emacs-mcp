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
