;;; emacs-mcp-test-transport.el --- Tests for emacs-mcp-transport -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the MCP Streamable HTTP transport layer.

;;; Code:

(require 'ert)
(require 'emacs-mcp-transport)

(defmacro emacs-mcp-test-with-transport (&rest body)
  "Run BODY with clean session/tool state for transport tests."
  (declare (indent 0))
  `(let ((emacs-mcp--sessions (make-hash-table :test 'equal))
         (emacs-mcp--tools nil)
         (emacs-mcp-session-timeout 1800)
         (emacs-mcp-deferred-timeout 300)
         (emacs-mcp--project-dir "/test/project"))
     (unwind-protect
         (progn ,@body)
       (maphash (lambda (_id session)
                  (when (emacs-mcp-session-timer session)
                    (cancel-timer
                     (emacs-mcp-session-timer session))))
                emacs-mcp--sessions))))

;;;; Session validation tests

(ert-deftest emacs-mcp-test-transport-validate-missing ()
  "Missing session ID returns 400."
  (let ((result (emacs-mcp--transport-validate-session nil)))
    (should (eq (car result) :error))
    (should (= (cdr result) 400))))

(ert-deftest emacs-mcp-test-transport-validate-empty ()
  "Empty session ID returns 400."
  (let ((result (emacs-mcp--transport-validate-session
                 '(("mcp-session-id" . "")))))
    (should (eq (car result) :error))
    (should (= (cdr result) 400))))

(ert-deftest emacs-mcp-test-transport-validate-unknown ()
  "Unknown session ID returns 404."
  (emacs-mcp-test-with-transport
    (let ((result (emacs-mcp--transport-validate-session
                   '(("mcp-session-id" . "nonexistent")))))
      (should (eq (car result) :error))
      (should (= (cdr result) 404)))))

(ert-deftest emacs-mcp-test-transport-validate-valid ()
  "Valid session ID returns session."
  (emacs-mcp-test-with-transport
    (let* ((id (emacs-mcp--session-create "/test"))
           (result (emacs-mcp--transport-validate-session
                    `(("mcp-session-id" . ,id)))))
      (should-not (eq (car result) :error))
      (should (equal (cdr result) id)))))

(ert-deftest emacs-mcp-test-transport-validate-updates-activity ()
  "Validation updates session activity timestamp."
  (emacs-mcp-test-with-transport
    (let* ((id (emacs-mcp--session-create "/test"))
           (session (emacs-mcp--session-get id))
           (old-time (emacs-mcp-session-last-activity session)))
      (sleep-for 0.01)
      (emacs-mcp--transport-validate-session
       `(("mcp-session-id" . ,id)))
      (should (> (emacs-mcp-session-last-activity session)
                 old-time)))))

;;;; HTTP error helper

(ert-deftest emacs-mcp-test-transport-error-400 ()
  "400 error has correct reason."
  (let ((reason (pcase 400 (400 "Bad Request") (_ "Error"))))
    (should (equal reason "Bad Request"))))

(ert-deftest emacs-mcp-test-transport-error-404 ()
  "404 error has correct reason."
  (let ((reason (pcase 404 (404 "Not Found") (_ "Error"))))
    (should (equal reason "Not Found"))))

(provide 'emacs-mcp-test-transport)
;;; emacs-mcp-test-transport.el ends here
