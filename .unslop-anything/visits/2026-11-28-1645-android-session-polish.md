# Unslop Visit — 2026-11-28-1645-android-session-polish

- **Mode**: `treat`
- **Target**: `app/android/app/src/main/kotlin/dev/ddgrcf/sidekick/ui/` (`DiffPreview.kt`, `RuntimeControls.kt`, `BridgeScreen.kt`, `SessionScreen.kt`) & `AppUiTest.kt`
- **Chart**: `.unslop-anything/chart.md`
- **Baseline Score (Before)**: `17/24` → **Estimated Score (After)**: `~20/24`

## 6 UI / UX Unslop Fixes Applied

1. **Nested Border & Chrome Reduction (`DiffPreview.kt`, `SessionScreen.kt`)**:
   - Added shared `DiffStatText(added, removed)` (`+N` / `-M`) and `framed: Boolean = true` parameter to `DiffCodeBlock`.
   - Set `framed = false` for inline edit previews embedded inside tool activity cards in `SessionScreen.kt`, removing triple-nested card borders.
2. **Borderless Composer Config & Compact Neovim Statusline (`RuntimeControls.kt`, `SessionScreen.kt`)**:
   - Simplified `ComposerConfigPill` into a lightweight inline trigger without heavy bordered card framing.
   - Streamlined `SidekickContextBar` into a dense Neovim-style statusline with `HairlineDivider` separators and removed unnecessary `!!` smart-cast warnings.
   - Wired `onOpenInNvim` button into `NvimContextSheet` for single-tap jump from mobile inspector to desktop Neovim.
3. **Flat Hairline-Separated Bottom Sheets & Flexible Weight Heights (`RuntimeControls.kt`)**:
   - Replaced nested card containers inside `SessionSettingsBottomSheet`, `WorkspaceDiffSheet`, and `NvimContextSheet` with flat `HairlineDivider`-separated rows.
   - Switched hardcoded sheet list max-heights to flexible `weight(1f, fill = false)` constraints so small and large screens adapt without awkward clipping.
4. **Terminology & Copy Consistency (`RuntimeControls.kt`, `BridgeScreen.kt`, `SessionScreen.kt`)**:
   - Unified Chinese labels across sheets and overlays (`"思考强度"`, `"选择 Agent"`, `"切到终端"`).
5. **Deduplicated & Grouped Header Overflow Menu (`SessionScreen.kt`)**:
   - Grouped session overflow actions cleanly and omitted the redundant `"切换模型 (/model)"` menu entry when `sessionConfig != null` (already accessible via the composer `ComposerConfigPill`).
6. **Lightweight User Bubbles + Hoisted Long-Press Action Sheet (`SessionScreen.kt`, `AppUiTest.kt`)**:
   - Added crisp `0.5.dp` `extras.userBubbleBorder` around user bubbles and removed permanent `MessageActionRow` strips below user messages.
   - Hoisted `bubbleMenuText` into `ChatView` outside `LazyColumn` and placed `.combinedClickable` on the inner `Column` inside `Surface` (avoiding Material 3 `Surface`'s internal `pointerInput` interception), opening a haptic-backed Material 3 `ModalBottomSheet` with `"复制消息"`, `"引用回复"`, and `"填入输入框重编"`.
   - Added `AppUiTest.userBubbleLongPressShowsCopyQuoteAndReeditActions` verifying long-press sheet actions and re-edit composer insertion.

## Verification

- `node /home/r/Scripts/sidekick.nvim/.agents/skills/unslop-anything/scripts/detect.js app/android/app/src/main/kotlin/dev/ddgrcf/sidekick/ui/`: **0 findings** across 12 files (`Dr. Unslopovich found nothing in 12 files`).
- `JAVA_HOME=/opt/android-studio/jbr ./gradlew test assembleDebug --no-daemon -Dorg.gradle.java.home=/opt/android-studio/jbr`: **BUILD SUCCESSFUL** in 59s.
  - `:app:testDebugUnitTest`: **49 / 49** passed (`AppUiTest`: 41, `ChatTurnTranslatorTest`: 6, `DiffPreviewTest`: 2; 0 skipped, 0 failures).
  - `:core:*` suites (`AnsiParserTest`: 1, `NoiseInteropTest`: 2, `ProtocolTest`: 3, `RelayApiAndTokenTest`: 3, `RelaySocketAndApiIntegrationTest`: 2, `DatabaseTest`: 1, `SecretStoreTest`: 1): **13 / 13** up-to-date & passed.
- APK built (`app-debug.apk`, 33M) and installed via USB/wireless ADB onto `V2419A` (`transport_id=10`, `adb reverse tcp:18090 tcp:18090`, `lastUpdateTime=2026-11-28 17:07:13`).
- **Not checked**: Visual screenshot capture on physical device after install and runtime frame-timing / jank profiling.
