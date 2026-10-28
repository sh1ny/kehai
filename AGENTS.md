# Project workflow

- Use the GitHub account `sh1ny` for pushes, pull requests, replies, and thread resolution. Fence authenticated operations with Specwright's `as.sh`; do not switch the globally active account.
- Commit as `Nikolay Bochev <309868+sh1ny@users.noreply.github.com>` (`sh1ny`). Include this trailer on every agent-created commit:

  `Co-authored-by: KintsugiBot <296966193+KintsugiBot@users.noreply.github.com>`

- After opening or finding a pull request, check its author. If the author is `sh1ny`, do not request review from `sh1ny` or post a review-request comment. Otherwise, request review from `sh1ny` if it has not already been requested or completed.
- Use the workflow settings in `openspec/specwright.yaml`: finish through pull requests, allow cross-model reviews, and require the pre-ship review. No pre-push validation command is configured.

# Toolchain

- mise manages every project tool: Dart, jj, ripgrep, gh, gitleaks, Node and OpenSpec are pinned in `mise.toml`. Run `mise install` once, then use `mise run <task>` (`format`, `format:check`, `analyze`, `test`, `check`, `openspec:validate`, `secrets`; `mise tasks` lists them). Don't install project tools globally or bypass the pins.
- `DART_DATA_HOME` points at `.dart_tool/dart-data`, so this repo's Dart tool state, including the MCP server app bundle, never contends with other projects.
- The official Dart MCP server is configured in `.mcp.json` and runs through `mise exec`. Flutter tools are disabled; `run_tests`, `dart_fix` and `dart_format` are enabled. Prefer its `analyze_files`, `run_tests` and `lsp` tools over ad-hoc shell commands when available.
- Official Dart team skills from `dart-lang/skills` are vendored into `.agents/skills/` and `.claude/skills/` at the commit pinned in each `UPSTREAM.json` (license in `LICENSE.dart`). Update them by re-vendoring both copies at a new pinned commit and refreshing `UPSTREAM.json`; never edit them in place.
