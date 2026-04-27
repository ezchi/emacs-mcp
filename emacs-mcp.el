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
;; group, user options, hook variables, and internal state variables
;; used throughout the package.

;;; Code:

(require 'cl-lib)

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

;;;; Internal state

(defvar emacs-mcp--server-process nil
  "The MCP HTTP server network process, or nil.")

(defvar emacs-mcp--project-dir nil
  "The project directory for the running server.")

;;;; Public API stubs

(defun emacs-mcp-connection-info ()
  "Return connection information for the running MCP server.
Returns nil when no server is running.  Will be fully implemented
in a later task."
  nil)

(provide 'emacs-mcp)
;;; emacs-mcp.el ends here
