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
