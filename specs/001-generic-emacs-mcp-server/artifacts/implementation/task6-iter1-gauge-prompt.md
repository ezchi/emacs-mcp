# Gauge Code Review — Task 6: Lockfile Management (Iteration 1)

You are a strict code reviewer. Review the implementation below against the task requirements, spec, and coding standards.

## Task Description

Implement `emacs-mcp-lockfile.el`: Lockfile creation, removal, and stale lockfile cleanup. Lockfiles are JSON files that let MCP clients discover running servers.

**Functions to implement**:
- `emacs-mcp--lockfile-path` — Compute `<dir>/<port>.lock` path
- `emacs-mcp--lockfile-create` — Write JSON lockfile (pid, port, workspaceFolders, serverName, transport) to one directory
- `emacs-mcp--lockfile-create-all` — Write to `emacs-mcp-lockfile-directory` + all `emacs-mcp-extra-lockfile-directories`
- `emacs-mcp--lockfile-remove` — Delete lockfile from one directory
- `emacs-mcp--lockfile-remove-all` — Delete from primary + all extra directories
- `emacs-mcp--lockfile-cleanup-stale` — Scan all lockfile directories, read PID from each `.lock` file, remove if process dead (via `process-attributes`)

**Verification criteria**:
- Lockfile contains valid JSON with correct fields (pid, port, workspaceFolders, serverName, transport)
- `workspaceFolders` is a JSON array (vector in Elisp)
- `serverName` is `"emacs-mcp"`
- `transport` is `"streamable-http"`
- Create writes to correct path; remove deletes it
- `create-all` writes to multiple directories
- `remove-all` deletes from all directories
- Stale cleanup removes lockfiles for dead PIDs, leaves alive PIDs
- Missing lockfile directory is created automatically
- All tests pass via `ert-run-tests-batch`
- File byte-compiles clean

## Coding Standards (from Constitution)

- Style: Follow Emacs Lisp conventions, `checkdoc` compliant
- Naming: Public symbols `emacs-mcp-`, internal `emacs-mcp--`
- Docstrings: Every public function/variable must have a docstring passing `checkdoc`
- Byte-compilation: Clean with no warnings
- Line length: 80 columns soft limit
- No global state pollution outside the package namespace

## Full File: emacs-mcp-lockfile.el

```elisp
;;; emacs-mcp-lockfile.el --- Lockfile management for emacs-mcp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; License: AGPL-3.0-or-later
;; See the file LICENSE for the full license text.

;;; Commentary:

;; This library handles creation and removal of lockfiles that
;; allow external processes to discover running emacs-mcp servers.

;;; Code:

(require 'emacs-mcp)

;;;; Lockfile path

(defun emacs-mcp--lockfile-path (dir port)
  "Return the lockfile path for PORT in directory DIR."
  (expand-file-name (format "%d.lock" port) dir))

;;;; Create

(defun emacs-mcp--lockfile-create (dir port project-dir)
  "Write a lockfile for PORT in DIR.
PROJECT-DIR is the workspace folder to record."
  (let ((path (emacs-mcp--lockfile-path dir port))
        (data `((pid . ,(emacs-pid))
                (port . ,port)
                (workspaceFolders . ,(vector project-dir))
                (serverName . "emacs-mcp")
                (transport . "streamable-http"))))
    (make-directory dir t)
    (with-temp-file path
      (insert (json-serialize data
                              :null-object :null
                              :false-object :false)))))

(defun emacs-mcp--lockfile-create-all (port project-dir)
  "Write lockfiles for PORT to all configured directories.
Writes to `emacs-mcp-lockfile-directory' and all
`emacs-mcp-extra-lockfile-directories'."
  (emacs-mcp--lockfile-create emacs-mcp-lockfile-directory
                              port project-dir)
  (dolist (dir emacs-mcp-extra-lockfile-directories)
    (emacs-mcp--lockfile-create dir port project-dir)))

;;;; Remove

(defun emacs-mcp--lockfile-remove (dir port)
  "Remove the lockfile for PORT from DIR."
  (let ((path (emacs-mcp--lockfile-path dir port)))
    (when (file-exists-p path)
      (delete-file path))))

(defun emacs-mcp--lockfile-remove-all (port)
  "Remove lockfiles for PORT from all configured directories."
  (emacs-mcp--lockfile-remove emacs-mcp-lockfile-directory port)
  (dolist (dir emacs-mcp-extra-lockfile-directories)
    (emacs-mcp--lockfile-remove dir port)))

;;;; Stale cleanup

(defun emacs-mcp--lockfile-cleanup-stale ()
  "Remove lockfiles for dead processes in all lockfile directories."
  (dolist (dir (cons emacs-mcp-lockfile-directory
                     emacs-mcp-extra-lockfile-directories))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.lock\\'"))
        (condition-case nil
            (let* ((content (with-temp-buffer
                              (insert-file-contents file)
                              (buffer-string)))
                   (data (json-parse-string
                          content
                          :object-type 'alist
                          :null-object :null))
                   (pid (alist-get 'pid data)))
              (when (and pid (integerp pid)
                         (not (process-attributes pid)))
                (delete-file file)))
          (error nil))))))

(provide 'emacs-mcp-lockfile)
;;; emacs-mcp-lockfile.el ends here
```

## Full File: test/emacs-mcp-test-lockfile.el

```elisp
;;; emacs-mcp-test-lockfile.el --- Tests for emacs-mcp-lockfile -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for lockfile management.

;;; Code:

(require 'ert)
(require 'emacs-mcp-lockfile)

(defmacro emacs-mcp-test-with-temp-lockdir (&rest body)
  "Run BODY with a temporary lockfile directory."
  (declare (indent 0))
  `(let* ((tmpdir (make-temp-file "emacs-mcp-test-" t))
          (emacs-mcp-lockfile-directory tmpdir)
          (emacs-mcp-extra-lockfile-directories nil))
     (unwind-protect
         (progn ,@body)
       (delete-directory tmpdir t))))

;;;; Path tests

(ert-deftest emacs-mcp-test-lockfile-path ()
  "Lockfile path has correct format."
  (should (string-match-p
           "/dir/8080\\.lock$"
           (emacs-mcp--lockfile-path "/dir" 8080))))

;;;; Create/remove tests

(ert-deftest emacs-mcp-test-lockfile-create ()
  "Create a lockfile with valid JSON content."
  (emacs-mcp-test-with-temp-lockdir
    (emacs-mcp--lockfile-create emacs-mcp-lockfile-directory
                                8080 "/project")
    (let* ((path (emacs-mcp--lockfile-path
                  emacs-mcp-lockfile-directory 8080))
           (content (with-temp-buffer
                      (insert-file-contents path)
                      (buffer-string)))
           (data (json-parse-string content :object-type 'alist)))
      (should (file-exists-p path))
      (should (equal (alist-get 'pid data) (emacs-pid)))
      (should (equal (alist-get 'port data) 8080))
      (should (equal (alist-get 'serverName data) "emacs-mcp"))
      (should (equal (alist-get 'transport data)
                     "streamable-http")))))

(ert-deftest emacs-mcp-test-lockfile-remove ()
  "Remove a lockfile."
  (emacs-mcp-test-with-temp-lockdir
    (emacs-mcp--lockfile-create emacs-mcp-lockfile-directory
                                8080 "/project")
    (let ((path (emacs-mcp--lockfile-path
                 emacs-mcp-lockfile-directory 8080)))
      (should (file-exists-p path))
      (emacs-mcp--lockfile-remove emacs-mcp-lockfile-directory 8080)
      (should-not (file-exists-p path)))))

(ert-deftest emacs-mcp-test-lockfile-remove-nonexistent ()
  "Removing a nonexistent lockfile is a no-op."
  (emacs-mcp-test-with-temp-lockdir
    (emacs-mcp--lockfile-remove emacs-mcp-lockfile-directory 9999)))

(ert-deftest emacs-mcp-test-lockfile-create-all ()
  "Create lockfiles in multiple directories."
  (let* ((dir1 (make-temp-file "emacs-mcp-test1-" t))
         (dir2 (make-temp-file "emacs-mcp-test2-" t))
         (emacs-mcp-lockfile-directory dir1)
         (emacs-mcp-extra-lockfile-directories (list dir2)))
    (unwind-protect
        (progn
          (emacs-mcp--lockfile-create-all 8080 "/project")
          (should (file-exists-p
                   (emacs-mcp--lockfile-path dir1 8080)))
          (should (file-exists-p
                   (emacs-mcp--lockfile-path dir2 8080))))
      (delete-directory dir1 t)
      (delete-directory dir2 t))))

(ert-deftest emacs-mcp-test-lockfile-remove-all ()
  "Remove lockfiles from all directories."
  (let* ((dir1 (make-temp-file "emacs-mcp-test1-" t))
         (dir2 (make-temp-file "emacs-mcp-test2-" t))
         (emacs-mcp-lockfile-directory dir1)
         (emacs-mcp-extra-lockfile-directories (list dir2)))
    (unwind-protect
        (progn
          (emacs-mcp--lockfile-create-all 8080 "/project")
          (emacs-mcp--lockfile-remove-all 8080)
          (should-not (file-exists-p
                       (emacs-mcp--lockfile-path dir1 8080)))
          (should-not (file-exists-p
                       (emacs-mcp--lockfile-path dir2 8080))))
      (delete-directory dir1 t)
      (delete-directory dir2 t))))

(ert-deftest emacs-mcp-test-lockfile-create-missing-dir ()
  "Create lockfile auto-creates missing directory."
  (let ((tmpdir (concat (make-temp-file "emacs-mcp-test-" t)
                        "/subdir")))
    (unwind-protect
        (progn
          (should-not (file-directory-p tmpdir))
          (emacs-mcp--lockfile-create tmpdir 8080 "/project")
          (should (file-exists-p
                   (emacs-mcp--lockfile-path tmpdir 8080))))
      (delete-directory (file-name-directory tmpdir) t))))

;;;; Stale cleanup tests

(ert-deftest emacs-mcp-test-lockfile-cleanup-stale ()
  "Stale lockfiles for dead PIDs are removed."
  (emacs-mcp-test-with-temp-lockdir
    ;; Create a lockfile with a dead PID (PID 1 is init, but
    ;; PID 999999 is almost certainly dead)
    (let ((path (emacs-mcp--lockfile-path
                 emacs-mcp-lockfile-directory 9999)))
      (make-directory emacs-mcp-lockfile-directory t)
      (with-temp-file path
        (insert (json-serialize
                 `((pid . 999999)
                   (port . 9999)
                   (workspaceFolders . ,(vector "/tmp"))
                   (serverName . "emacs-mcp")
                   (transport . "streamable-http"))
                 :null-object :null
                 :false-object :false)))
      (should (file-exists-p path))
      (emacs-mcp--lockfile-cleanup-stale)
      (should-not (file-exists-p path)))))

(ert-deftest emacs-mcp-test-lockfile-cleanup-keeps-alive ()
  "Lockfiles for alive processes are kept."
  (emacs-mcp-test-with-temp-lockdir
    (let ((path (emacs-mcp--lockfile-path
                 emacs-mcp-lockfile-directory 8080)))
      (make-directory emacs-mcp-lockfile-directory t)
      (with-temp-file path
        (insert (json-serialize
                 `((pid . ,(emacs-pid))
                   (port . 8080)
                   (workspaceFolders . ,(vector "/tmp"))
                   (serverName . "emacs-mcp")
                   (transport . "streamable-http"))
                 :null-object :null
                 :false-object :false)))
      (should (file-exists-p path))
      (emacs-mcp--lockfile-cleanup-stale)
      (should (file-exists-p path)))))

(provide 'emacs-mcp-test-lockfile)
;;; emacs-mcp-test-lockfile.el ends here
```

## Test Results

All 9 tests pass. Byte-compilation clean (no warnings).

## Review Checklist

1. **Correctness**: Does the code implement all required functions? Is the JSON lockfile structure correct (pid, port, workspaceFolders as array, serverName, transport)? Does `cleanup-stale` correctly use `process-attributes` to detect dead PIDs?
2. **Code quality**: Clean, readable, well-structured? Appropriate error handling in `cleanup-stale`?
3. **Constitution compliance**: Naming conventions (`emacs-mcp--` for all functions — all internal), docstrings, byte-compile clean, 80-col soft limit?
4. **Security**: File permissions on lockfiles? Race conditions between create/remove? Can a malicious lockfile cause issues during `cleanup-stale` (JSON parsing is guarded by `condition-case`)?
5. **Error handling**: What happens if `json-serialize` fails? What if `delete-file` fails (permissions)? Is the `condition-case` in `cleanup-stale` too broad (catches all errors silently)?
6. **Test coverage**: All key paths covered? Path format, create with JSON validation, remove, remove-nonexistent, create-all multi-dir, remove-all multi-dir, auto-create missing dir, stale cleanup (dead PID removed, alive PID kept)? Missing: `workspaceFolders` array structure verification, corrupt lockfile handling in cleanup, error during lockfile creation?
7. **Performance**: Any concerns with scanning lockfile directories? (Unlikely for typical use — few lockfiles)
8. **Scope creep**: Does the code stay within task requirements? No premature server integration?

List issues with severity: BLOCKING / WARNING / NOTE
End with exactly: `VERDICT: APPROVE` or `VERDICT: REVISE`
