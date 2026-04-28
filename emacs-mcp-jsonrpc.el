;;; emacs-mcp-jsonrpc.el --- JSON-RPC 2.0 message handling for emacs-mcp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.
;; License: AGPL-3.0-or-later
;; See the file LICENSE for the full license text.

;;; Commentary:

;; This library implements JSON-RPC 2.0 message encoding, decoding,
;; and type predicates for the emacs-mcp package.  It is a pure data
;; transformation layer with no network or MCP knowledge.
;;
;; JSON arrays are represented as vectors throughout this layer.
;; This ensures correct round-trip serialization of nested arrays
;; (e.g., MCP content arrays) and makes batch detection trivial.

;;; Code:

;;;; Error code constants

(defconst emacs-mcp--jsonrpc-parse-error -32700
  "JSON-RPC error code for parse errors.")

(defconst emacs-mcp--jsonrpc-invalid-request -32600
  "JSON-RPC error code for invalid requests.")

(defconst emacs-mcp--jsonrpc-method-not-found -32601
  "JSON-RPC error code for method not found.")

(defconst emacs-mcp--jsonrpc-invalid-params -32602
  "JSON-RPC error code for invalid method parameters.")

(defconst emacs-mcp--jsonrpc-internal-error -32603
  "JSON-RPC error code for internal errors.")

;;;; Parsing

(defun emacs-mcp--jsonrpc-parse (json-string)
  "Parse JSON-STRING into a JSON-RPC message or batch vector.
Returns a single alist for a single JSON object, or a vector of
alists for a batch array.  JSON arrays are always parsed as
vectors.  Signals `json-parse-error' on malformed JSON."
  (json-parse-string json-string
                     :object-type 'alist
                     :array-type 'array
                     :null-object :null
                     :false-object :false))

;;;; Type predicates

(defun emacs-mcp--jsonrpc-batch-p (parsed)
  "Return non-nil if PARSED is a JSON-RPC batch (a vector)."
  (vectorp parsed))

(defun emacs-mcp--jsonrpc-request-p (msg)
  "Return non-nil if MSG is a JSON-RPC request (has `method' and `id')."
  (and (assq 'method msg)
       (assq 'id msg)))

(defun emacs-mcp--jsonrpc-notification-p (msg)
  "Return non-nil if MSG is a JSON-RPC notification (has `method', no `id')."
  (and (assq 'method msg)
       (not (assq 'id msg))))

(defun emacs-mcp--jsonrpc-response-p (msg)
  "Return non-nil if MSG is a JSON-RPC response (has `result' or `error')."
  (and (assq 'id msg)
       (or (assq 'result msg)
           (assq 'error msg))))

;;;; Response construction

(defun emacs-mcp--jsonrpc-make-response (id result)
  "Build a JSON-RPC 2.0 success response alist.
ID is the request ID (string or number), RESULT is the result value."
  `((jsonrpc . "2.0")
    (id . ,id)
    (result . ,result)))

(defun emacs-mcp--jsonrpc-make-error (id code message &optional data)
  "Build a JSON-RPC 2.0 error response alist.
ID is the request ID (string, number, or :null for parse errors).
CODE is the error code integer.  MESSAGE is the error description.
DATA is optional additional error data."
  (let ((err `((code . ,code)
               (message . ,message))))
    (when data
      (setq err (append err `((data . ,data)))))
    `((jsonrpc . "2.0")
      (id . ,id)
      (error . ,err))))

;;;; Serialization

(defun emacs-mcp--jsonrpc-serialize (msg)
  "Serialize MSG to a JSON string.
MSG can be a single JSON-RPC message alist, a vector of message
alists (batch response), or a list of message alists (which is
converted to a vector for JSON array output)."
  (let ((obj (if (and (listp msg)
                      (not (null msg))
                      (consp msg)
                      (listp (car msg))
                      (consp (caar msg)))
                 (vconcat msg)
               msg)))
    (json-serialize obj
                    :null-object :null
                    :false-object :false)))

(provide 'emacs-mcp-jsonrpc)
;;; emacs-mcp-jsonrpc.el ends here
