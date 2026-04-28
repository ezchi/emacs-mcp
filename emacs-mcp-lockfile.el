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
