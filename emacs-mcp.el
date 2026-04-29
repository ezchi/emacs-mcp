;;; emacs-mcp.el --- MCP server for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: emacs-mcp contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; URL: https://github.com/anthropics/emacs-mcp
;; License: AGPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public
;; License along with this program.  If not, see
;; <https://www.gnu.org/licenses/>.

;;; Commentary:

;; emacs-mcp exposes an MCP (Model Context Protocol) server from a
;; running Emacs instance, allowing AI assistants to interact with
;; Emacs programmatically.  This file defines the customization
;; group, user options, hook variables, and the start/stop/restart
;; commands.

;;; Code:

(require 'cl-lib)

;; Forward declarations for sub-modules (loaded on demand)
(declare-function emacs-mcp--http-start "emacs-mcp-http")
(declare-function emacs-mcp--http-stop "emacs-mcp-http")
(declare-function emacs-mcp--resolve-project-dir
                  "emacs-mcp-session")
(declare-function emacs-mcp--validate-project-dir
                  "emacs-mcp-session")
(declare-function emacs-mcp--session-cleanup-all
                  "emacs-mcp-session")
(declare-function emacs-mcp--lockfile-create-all
                  "emacs-mcp-lockfile")
(declare-function emacs-mcp--lockfile-remove-all
                  "emacs-mcp-lockfile")
(declare-function emacs-mcp--lockfile-cleanup-stale
                  "emacs-mcp-lockfile")
(declare-function emacs-mcp--transport-handle-request
                  "emacs-mcp-transport")
(declare-function emacs-mcp--register-builtin-tools
                  "emacs-mcp-tools-builtin")

;;;; Customization group

(defgroup emacs-mcp nil
  "MCP server for Emacs."
  :group 'tools
  :group 'comm)

;;;; User options

(defcustom emacs-mcp-server-port 38840
  "Port number for the MCP HTTP server.
When nil, the server automatically selects an available port.
When an integer, the server binds to that specific port."
  :type '(choice (const :tag "Auto-select" nil)
                 (integer :tag "Fixed port"))
  :safe (lambda (v)
          (or (null v)
              (and (integerp v) (<= 1 v 65535))))
  :group 'emacs-mcp)

(defcustom emacs-mcp-project-directory nil
  "Root directory of the project the server exposes.
When nil, the project root is detected automatically using
`project-current'.  When a directory path, that directory is used
as-is."
  :type '(choice (const :tag "Auto-detect" nil)
                 (directory :tag "Fixed directory"))
  :safe (lambda (v) (or (null v) (stringp v)))
  :group 'emacs-mcp)

(defcustom emacs-mcp-lockfile-directory "~/.emacs-mcp"
  "Directory where MCP lockfiles are written.
Each running server writes a lockfile so that external processes
can discover the server port."
  :type 'directory
  :safe #'stringp
  :group 'emacs-mcp)

(defcustom emacs-mcp-extra-lockfile-directories nil
  "Additional directories where lockfiles should be written.
This is useful when multiple tools scan different paths for MCP
server discovery."
  :type '(repeat directory)
  :safe (lambda (v)
          (and (listp v) (cl-every #'stringp v)))
  :group 'emacs-mcp)

(defcustom emacs-mcp-session-timeout 1800
  "Idle timeout for MCP sessions, in seconds.
Sessions that receive no requests within this period are
automatically terminated."
  :type 'integer
  :safe #'integerp
  :group 'emacs-mcp)

(defcustom emacs-mcp-deferred-timeout 300
  "Timeout for deferred tool results, in seconds.
If a deferred tool call is not resolved within this period, it
is considered failed."
  :type 'integer
  :safe #'integerp
  :group 'emacs-mcp)

(defcustom emacs-mcp-allowed-project-directories nil
  "List of directories clients may request as project roots.
When nil, any existing directory is allowed.  When non-nil, each
client-requested project directory must be within one of these
directories.  Paths are canonicalized before comparison."
  :type '(choice (const :tag "No restriction" nil)
                 (repeat :tag "Allowed directories" directory))
  :safe (lambda (v)
          (or (null v)
              (and (listp v) (cl-every #'stringp v))))
  :group 'emacs-mcp)

;;;; Hook variables

(defvar emacs-mcp-server-started-hook nil
  "Hook run after the MCP server starts.
Functions receive one argument: the port number.")

(defvar emacs-mcp-server-stopped-hook nil
  "Hook run after the MCP server stops.")

(defvar emacs-mcp-client-connected-hook nil
  "Hook run when a new MCP client session is initialized.
Functions receive one argument: the session ID string.")

(defvar emacs-mcp-client-disconnected-hook nil
  "Hook run when an MCP client session is terminated.
Functions receive one argument: the session ID string.")

(defvar emacs-mcp-project-dir-changed-hook nil
  "Hook run when a session's project directory changes.
Functions receive three arguments: the session ID string, the old
project directory, and the new project directory.  Only fires when
the canonical directory actually changes, not on no-op calls.")

;;;; Internal state

(defvar emacs-mcp--server-process nil
  "The MCP HTTP server network process, or nil.")

(defvar emacs-mcp--server-port nil
  "The port the server is listening on, or nil.")

(defvar emacs-mcp--project-dir nil
  "The project directory for the running server.")

;;;; Interactive commands

;;;###autoload
(defun emacs-mcp-start ()
  "Start the MCP server.
If already running, return the existing port."
  (interactive)
  (if (and emacs-mcp--server-process
           (process-live-p emacs-mcp--server-process))
      (progn
        (message "emacs-mcp: server already running on port %d"
                 emacs-mcp--server-port)
        emacs-mcp--server-port)
    ;; Validate port
    (when (and emacs-mcp-server-port
               (not (and (integerp emacs-mcp-server-port)
                         (<= 1 emacs-mcp-server-port 65535))))
      (user-error "emacs-mcp: invalid port %S (must be nil or 1-65535)"
                  emacs-mcp-server-port))
    ;; Load sub-modules
    (require 'emacs-mcp-session)
    (require 'emacs-mcp-lockfile)
    (require 'emacs-mcp-transport)
    (require 'emacs-mcp-tools-builtin)
    ;; Resolve project directory
    (setq emacs-mcp--project-dir (emacs-mcp--resolve-project-dir))
    ;; Clean stale lockfiles
    (emacs-mcp--lockfile-cleanup-stale)
    ;; Register built-in tools
    (emacs-mcp--register-builtin-tools)
    ;; Start HTTP server
    (condition-case err
        (setq emacs-mcp--server-process
              (emacs-mcp--http-start
               emacs-mcp-server-port
               #'emacs-mcp--transport-handle-request))
      (error
       (user-error "emacs-mcp: cannot bind to port %s: %s"
                   (or emacs-mcp-server-port "auto")
                   (error-message-string err))))
    ;; Get actual port
    (setq emacs-mcp--server-port
          (process-contact emacs-mcp--server-process :service))
    ;; Create lockfiles
    (emacs-mcp--lockfile-create-all
     emacs-mcp--server-port emacs-mcp--project-dir)
    ;; Add kill-emacs-hook
    (add-hook 'kill-emacs-hook #'emacs-mcp-stop)
    ;; Run hook
    (run-hook-with-args 'emacs-mcp-server-started-hook
                        emacs-mcp--server-port)
    (message "emacs-mcp: server started on port %d"
             emacs-mcp--server-port)
    emacs-mcp--server-port))

;;;###autoload
(defun emacs-mcp-stop ()
  "Stop the MCP server."
  (interactive)
  (when emacs-mcp--server-process
    ;; Cleanup sessions (cancels timers, closes SSE)
    (require 'emacs-mcp-session)
    (emacs-mcp--session-cleanup-all)
    ;; Stop HTTP server
    (require 'emacs-mcp-http)
    (emacs-mcp--http-stop emacs-mcp--server-process)
    ;; Remove lockfiles
    (when emacs-mcp--server-port
      (require 'emacs-mcp-lockfile)
      (emacs-mcp--lockfile-remove-all emacs-mcp--server-port))
    ;; Remove kill-emacs-hook
    (remove-hook 'kill-emacs-hook #'emacs-mcp-stop)
    ;; Clear state
    (setq emacs-mcp--server-process nil
          emacs-mcp--server-port nil
          emacs-mcp--project-dir nil)
    ;; Run hook
    (run-hooks 'emacs-mcp-server-stopped-hook)
    (message "emacs-mcp: server stopped")))

;;;###autoload
(defun emacs-mcp-restart ()
  "Restart the MCP server."
  (interactive)
  (emacs-mcp-stop)
  (emacs-mcp-start))

;;;; Global minor mode

;;;###autoload
(define-minor-mode emacs-mcp-mode
  "Toggle the emacs-mcp server.
When enabled, starts the MCP server.  When disabled, stops it."
  :global t
  :lighter " MCP"
  :group 'emacs-mcp
  (if emacs-mcp-mode
      (emacs-mcp-start)
    (emacs-mcp-stop)))

;;;; Connection info

(defun emacs-mcp-connection-info ()
  "Return connection information for the running MCP server.
Returns nil when no server is running."
  (when emacs-mcp--server-port
    `((:port . ,emacs-mcp--server-port)
      (:host . "127.0.0.1")
      (:url . ,(format "http://127.0.0.1:%d/mcp"
                       emacs-mcp--server-port))
      (:lockfile . ,(expand-file-name
                     (format "%d.lock"
                             emacs-mcp--server-port)
                     emacs-mcp-lockfile-directory)))))

(provide 'emacs-mcp)
;;; emacs-mcp.el ends here
