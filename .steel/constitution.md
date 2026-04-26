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
- **Protocol**: Model Context Protocol (MCP) over JSON-RPC/stdio

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

## Constraints

- **No network calls at load time** — The package must load instantly without blocking Emacs. All network/process activity happens on explicit user action or deferred initialization.
- **No global state pollution** — Do not modify global Emacs state (keymaps, hooks, variables) outside of the package's own namespace unless the user explicitly enables it via a minor/global mode.
- **Emacs 29+ minimum** — Do not support Emacs versions older than 29. This allows use of native JSON parsing (`json-parse-string`, `json-serialize`), tree-sitter APIs, and other modern features.
- **Process management** — MCP server subprocesses must be properly managed: started, monitored, and cleaned up. No orphaned processes on package unload or Emacs exit.
- **Security** — Never execute arbitrary code from MCP server responses without user confirmation. Tool calls that modify the filesystem or run commands require explicit approval.
