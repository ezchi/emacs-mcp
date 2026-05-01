# Delta Revision — Iteration 4

## User Feedback
"please create README file with details instruction about how to use this MCP with examples for claude code, gemini cli and codex. It has needs to have detail information about how to add new tools to the MCP server"

## Changes Made

### clarifications.md
- Added C-8: README requirement with 9-section structure covering installation, quick start, configuration, LLM agent connection examples (Claude Code, Gemini CLI, Codex, generic curl), built-in tools reference, custom tool guide (deftool, register-tool, unregister-tool, types, return values, deferred pattern), lockfile discovery, security, and license.

### spec.md
- Added NFR-8 (README Documentation) between NFR-7 and the existing NFR-7 (renumbered nothing — NFR-8 is new).
- Added AC-15 requiring README.org to exist with the specified sections.
- Updated Changelog with delta1 entry.

## Sections NOT Modified
- All existing C-1 through C-7 clarifications untouched
- All FR-1 through FR-9 untouched
- All NFR-1 through NFR-7 untouched
- All existing AC-1 through AC-14 untouched
- All User Stories, Out of Scope sections untouched
