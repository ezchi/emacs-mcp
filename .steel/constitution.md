# Project Constitution

## Governing Principles

1. **Emacs-native design** — Follow Emacs conventions and idioms. The package must feel like a natural part of the Emacs ecosystem, not a foreign wrapper.
2. **MCP specification compliance** — Adhere strictly to the Model Context Protocol specification. Interoperability with other MCP clients/servers is non-negotiable.
3. **Minimal dependencies** — Prefer built-in Emacs libraries over third-party packages. Every external dependency must justify its existence.
4. **AGPL-3.0 compliance** — All code must be compatible with the GNU Affero General Public License v3. No proprietary dependencies or license-incompatible code.
5. **User control** — The user must be able to configure, override, or disable any behavior. No silent network calls, no opaque defaults.

## Technology Stack

- **Language**: Emacs Lisp (primary and only implementation language)
- **Target platform**: GNU Emacs 29+ (tree-sitter support, native JSON parsing)
- **Build/package tools**: Eask, Cask, or Eldev for CI/packaging (to be determined)
- **Testing**: ERT (Emacs Regression Testing) for unit tests, Buttercup for BDD-style tests if warranted
- **CI**: GitHub Actions
- **Protocol**: Model Context Protocol (MCP) `2025-03-26` over Streamable HTTP (JSON-RPC 2.0)

## Coding Standards

- **Style**: Follow the Emacs Lisp conventions in the Emacs manual and `checkdoc`.
- **Naming**: Prefix all public symbols with `emacs-mcp-` (or agreed shorter prefix). Internal symbols use `emacs-mcp--` (double dash).
- **Docstrings**: Every public function, variable, and macro must have a docstring that passes `checkdoc`.
- **Byte-compilation**: All code must compile cleanly with no warnings under `byte-compile-warnings` set to `t`.
- **Autoloads**: Public entry points (interactive commands, minor modes) must have `;;;###autoload` cookies.
- **Custom variables**: User-facing configuration uses `defcustom` with appropriate `:type`, `:group`, and `:safe` declarations.
- **No `cl-lib` abuse**: Use `cl-lib` macros where they genuinely improve clarity (e.g., `cl-defstruct`, `cl-loop`), but do not import the entire CL namespace for trivial uses.
- **Line length**: 80 columns soft limit, consistent with Emacs tradition.

## Development Guidelines

- **Branching**: `main` is the release branch, `develop` is the integration branch, feature branches use `feature/` prefix.
- **Commits**: Use `type(scope): description` format (e.g., `feat(transport): add stdio transport layer`). Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
- **Testing**: Every public function must have corresponding ERT tests. Tests live in a `test/` directory.
- **Code review**: All changes to `main` go through pull requests. No direct pushes to `main`.
- **Byte-compile check**: Code must byte-compile without warnings before merging.
- **Checkdoc**: All public symbols must pass `checkdoc` before merging.

## Emacs Lisp Pitfalls

These are non-obvious Emacs API behaviors that caused bugs during implementation. Treat them as mandatory coding rules.

1. **JSON array type**: Always use `:array-type 'array` (not `'list`) with `json-parse-string` when the parsed data may be serialized back to JSON. Lists are indistinguishable from alists, breaking round-trip serialization of nested arrays (e.g., MCP `content` arrays). The `'array` option produces vectors, which `json-serialize` correctly encodes as JSON arrays.

2. **Reading `/dev/urandom`**: `insert-file-contents-literally` with start/end byte offsets fails on character devices (`file-error`). Use `(call-process "head" "/dev/urandom" t nil "-c" "N")` with `(let ((coding-system-for-read 'no-conversion)) ...)` to read raw bytes. Always validate the byte count after reading.

3. **No `return` statement**: Emacs Lisp has no `return` keyword. `(return expr)` compiles without error but calls an undefined function at runtime. Use `cond`/nested `if` for early-exit control flow. Do not use `cl-return-from` with `defun` names — it requires an explicit `cl-block`. Prefer restructuring with `cond` over `cl-block`/`cl-return-from`.

4. **`let` vs `let*` for closures**: With `lexical-binding: t`, `let` evaluates all init-forms in the *outer* lexical scope. A lambda assigned to one binding cannot close over a variable from another binding in the same `let` form — the variable resolves in the outer scope (typically nil or unbound). Use `let*` whenever a lambda must capture a variable defined in an earlier binding.

5. **Regex string anchors**: `^` and `$` match *line* boundaries in Emacs regex, not string boundaries. For string-start/end matching, use `\`` and `\'`. This is security-critical for input validation (e.g., Origin headers): an attacker can embed a newline to bypass `^...$` patterns. Additionally, pre-filter control characters (`[\x00-\x1f\x7f]`) before regex matching on untrusted input.

## Constraints

- **No network calls at load time** — The package must load instantly without blocking Emacs. All network/process activity happens on explicit user action or deferred initialization.
- **No global state pollution** — Do not modify global Emacs state (keymaps, hooks, variables) outside of the package's own namespace unless the user explicitly enables it via a minor/global mode.
- **Emacs 29+ minimum** — Do not support Emacs versions older than 29. This allows use of native JSON parsing (`json-parse-string`, `json-serialize`), tree-sitter APIs, and other modern features.
- **Process management** — MCP server subprocesses must be properly managed: started, monitored, and cleaned up. No orphaned processes on package unload or Emacs exit.
- **Security** — Never execute arbitrary code from MCP server responses without user confirmation. Tool calls that modify the filesystem or run commands require explicit approval.
