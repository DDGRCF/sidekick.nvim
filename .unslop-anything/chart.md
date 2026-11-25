# Chart

Stack: Android Jetpack Compose (Material 3 1.5.0, Compose BOM 2026.11.01) + Navigation 3 + Hilt
Platforms: Android (minSdk 26, targetSdk 37)
Visits: on

## Top tasks
1. Open Home, see paired workstations (`online`/`offline`), tap into an online bridge (`HomeScreen` -> `BridgeScreen`).
2. Inspect live sessions or history, send prompts/keys/media, and switch between `Chat` and `Terminal` (`BridgeScreen` -> `SessionScreen`).
3. Pair a new bridge via QR or manual `user_code` + PSK, or switch theme / revoke devices (`PairScreen`, `SettingsScreen`).

## Users and context
Developers away from their desk using one thumb on a phone to monitor local tmux/zellij AI CLI sessions (Codex, Claude, Pi, Devin, agy), inspect diffs/screenshots, paste snippets, and send `Ctrl-C`.

## Brand
- Color: Terminal workbench palette — obsidian `#0C0E12` (dark) / clean white `#FFFFFF` (light) canvas with phosphor emerald `#34D399` (dark) / `#059669` (light) accent and `#0B0E14` high-contrast terminal surface.
- Type: System Material 3 type scale (`sp`) + `FontFamily.Monospace` strictly for paths, fingerprints, ANSI output, code blocks, and keycaps.
- Keep: Dark `#0B0E14` ANSI terminal canvas even in light mode; E2E error guardrails (no PSK fallback, key pin mismatch block).

## Accepted
- `SessionContent` `"Chat"` / `"Terminal"` labels and `"输入指令…"` placeholder text kept for accessibility and Compose UI test stability.

## Off limits
- Business logic in `core/*`, Room schema, Noise protocol (`XXpsk3`/`KK`), and `SessionViewModel` RPC contracts.
