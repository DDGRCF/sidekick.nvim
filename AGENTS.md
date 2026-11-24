# Agent Cheat Sheet

`sidekick.nvim` — Neovim plugin integrating GitHub Copilot "Next Edit Suggestions" (NES) via Copilot's LSP.

## Commands

- `./scripts/test` – `mini.test` suite via Lazy.nvim harness (auto-installs deps). `LAZY_OFFLINE=1` to skip bootstrap.
- `./scripts/docs` – regenerates `README.md` via `lua/sidekick/docs.lua`. Never hand-edit generated sections.
- `stylua lua tests` / `selene` – format / lint.
- Neovim help lookup: `nvim --headless '+lua vim.cmd.help("nvim_buf_set_extmark")' +qall` (pipe through `rg -C4` for search).

## Rules

- Every change gets a `CHANGELOG.md` entry under a `## [Unreleased]` section at the top of the file (create it if missing), using `### Features` / `### Bug Fixes` / `### Docs` subheadings and a one-line bullet. Never rewrite released sections.
- NES gating goes through the `Config.nes.enabled` callback so users can opt out globally (`vim.g.sidekick_nes = false`) or per buffer (`vim.b[buf].sidekick_nes = false`).
- New options belong in `lua/sidekick/config.lua` — docs are generated from it.
- Diff logic changes require tests in `tests/diff_spec.lua`; status reporting changes in `tests/status_spec.lua`.
- Tests: `mini.test` assertions, table-driven where combinatorial. Stub Neovim APIs and restore them in `after_each`; use `debug.setupvalue` for upvalue-bound helpers. Stub `Config.get_client` or `vim.lsp` methods — never `vim.lsp._set_clients`.
- CI is headless and network-blocked: no third-party fetches in stubs or fixtures.

## Paths

- Remote sync (phone ↔ relay ↔ bridge): read `app/docs/remote-sync-design.md` (master), `remote-sync-server.md` (Go), `remote-sync-android.md` (Kotlin) before touching `app/server` or `app/android`.
- `lua/sidekick/nes/diff.lua` – diff core
- `lua/sidekick/nes/init.lua` – NES orchestration
- `lua/sidekick/treesitter.lua` – treesitter helpers
- `lua/sidekick/status.lua` – status integration
- `tests/minit.lua` – test entry point
