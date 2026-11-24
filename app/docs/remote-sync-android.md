# sidekick 远程同步 — Android 技术栈

> 总纲：`remote-sync-design.md`（先读它）。本文档只管 `app/android` 仓库
> （`github.com/DDGRCF/sidekick.android`，sidekick.nvim 的 submodule）内的实现。
> 协议以 `../server/proto/sidekick/v1/remote.proto` 为权威，本文档不写协议语义。

## 目录

- [1. 技术栈总览](#1-技术栈总览)
- [2. 模块布局](#2-模块布局)
- [3. 协议与 proto 同步](#3-协议与-proto-同步)
- [4. Noise on Android（需先 spike）](#4-noise-on-android需先-spike)
- [5. 登录与配对流程](#5-登录与配对流程)
- [6. UI 规格](#6-ui-规格)
- [7. 本地存储](#7-本地存储)
- [8. 网络与生命周期](#8-网络与生命周期)
- [9. 测试与验收](#9-测试与验收)
- [10. 后续（P6+）](#10-后续p6)

## 1. 技术栈总览

| 用途 | 坐标 | 最新版本 | 备注 |
|---|---|---|---|
| 语言 | `org.jetbrains.kotlin` | **2.4.21**（10-08） | 2.5.0-RC 已出，正式版预计 2026-12 |
| Gradle | `com.android.application` | AGP **9.5.2** + Gradle **9.6.0** | Kotlin 2.4+ 兼容 Gradle 9 |
| SDK | — | compileSdk/targetSdk **37.1**，minSdk **26** | Compose 1.13 要求 compileSdk 37.1 |
| UI | `androidx.compose:compose-bom` | **2026.11.01**（11-19） | Compose 1.13 / Material3 1.5.0；深色 + 浅色双主题（跟随系统 / 深色 / 浅色三档切换，持久化于 SecretStore；支持可选 `dynamicColorScheme`）；Edge-to-Edge 系统栏适配 |
| 导航 | `androidx.navigation3:navigation3-*` | **1.2.2**（11-18） | Navigation 2.x 已进入维护模式；新项目用 Nav3 |
| 生命周期 | `androidx.lifecycle:lifecycle-*` | **2.11.1**（11-18） | `ViewModel` + `collectAsStateWithLifecycle` |
| DI | `com.google.dagger:hilt-*` / `androidx.hilt:*` | **2.60.1**（07-07）/ **1.4.0**（07-01） | KSP；`hiltViewModel()` 在 `hilt-lifecycle-viewmodel-compose` artifact |
| protobuf | `com.squareup.wire:wire-*` | **7.2.2**（11-17） | 只生成 message（不用 wire-grpc） |
| HTTP/WS | `com.squareup.okhttp3:okhttp` | **5.5.1**（10-22） | 5.x 稳定线；不用 `java.net.http`（无 WS） |
| DB/缓存 | `androidx.room3:*` | **3.0.3**（09-09） | Room 新 major 线（旧线 2.x 止于 2.8.5） |
| 数据存储 | `androidx.datastore:datastore*` + `datastore-tink` | **1.3.0**（10-21） | 1.3.0 起官方内置 Tink AEAD（`AeadSerializer`）——**替代已弃用的 `security-crypto`/`EncryptedSharedPreferences`，禁止引入后者** |
| 敏感密钥 | Android Keystore | — | Noise 静态私钥优先 `AndroidKeyStore`（`PURPOSE_AGREE_KEY`）；拿不到私钥时 fallback：datastore-tink 存 raw key |
| 登录浏览器 | `androidx.browser:browser` | 最新 | Custom Tabs 承载 GitHub OAuth |
| 扫码 | `com.google.android.gms:play-services-mlkit-barcode-scanning` + `androidx.camera:camera-*` | **18.3.1** / **1.7.0**（11-18） | thin 模型走 GMS 省体积；bundled 为 `com.google.mlkit:barcode-scanning:17.3.0` |
| 后台 | `androidx.work:work-*` | **2.12.0**（09-23） | + ForegroundService 前台保活 WSS；推送见 §10 |
| Noise | `org.bouncycastle:bcprov-jdk18on` + 纯 Kotlin 状态机 | **1.87** | 见 §4，已通过 `flynn/noise` `interop_vectors.json` 字节级互操作验证 |
| JSON | `org.jetbrains.kotlinx:kotlinx-serialization-json` | 随 Kotlin 插件最新 | REST 响应、enroll 载荷 |
| 测试 | JUnit + Robolectric + Compose UI test | 最新 | `core/*` 纯 JVM 模块可脱离 Android 测 |

## 2. 模块布局

```
app/android/
├── settings.gradle.kts / build.gradle.kts / gradle/libs.versions.toml
├── proto/                     # 从 ../server/proto 同步的 remote.proto（scripts 管理）
├── scripts/
│   └── sync-proto.sh          # 校验/同步 proto（§3）
├── core/
│   ├── protocol/              # Frame 编解码、分片重组（纯 JVM，不依赖 Android）
│   ├── noise/                 # Noise 握手 + transport（spike 后定实现）
│   ├── relay/                 # REST client + WSS client + token 管理
│   ├── store/                 # Room 3 实体/DAO、DataStore(tink 加密) 敏感项
│   └── ansi/                  # ANSI SGR → AnnotatedString 解析器（纯 JVM）
└── app/
    ├── ui/                    # Compose screens + components
    ├── vm/                    # ViewModels
    ├── nav/                   # Navigation3 路由
    ├── service/               # ForegroundService（WSS 保活）
    └── MainActivity.kt
```

`core/protocol`、`core/noise`、`core/ansi` 必须是**纯 Kotlin/JVM** 模块（无 Android 依赖），
保证可 JUnit + Robolectric 单测，也方便拿 Go 端测试向量做互操作。

## 3. 协议与 proto 同步

- `proto/remote.proto` 是 server repo 文件的**拷贝**，不手改；
  `scripts/sync-proto.sh`：
  1. `cp ../server/proto/sidekick/v1/remote.proto proto/`；
  2. CI 里对比两文件 SHA-256，不一致 → fail（防止协议漂移）。
- codegen：Wire Gradle plugin，`com.squareup.wire` 生成 Kotlin 类到 `build/generated`。
- `Frame` 序列化 → `core/noise` 分片（总纲 §3.4 帧格式：`u48 msg_id | u8 flags | u16 len | payload`，
  `chunk_len ≤ 60000`，单 Frame ≤ 8MiB，`LAST=1` 重组）→ Noise 加密 → WS binary。
- 应用层约定：request `id` 单调递增不复用；响应按 `reply_to` 配对，60s 超时；
  `version != PROTOCOL_VERSION_1` 的 Frame 直接忽略并 log。

## 4. Noise on Android（已选型并完成互操作验证）

目标：与 Go `flynn/noise` 的 `XXpsk3`/`KK` + `25519_ChaChaPoly_BLAKE2s` 完全互操作。

已选方案：**`org.bouncycastle:bcprov-jdk18on:1.87` 原语 + 纯 Kotlin `NoiseHandshake` / `NoiseSession` 状态机**（`core/noise` 模块）：
- 使用 BouncyCastle `X25519`、`ChaCha20Poly1305`、`Blake2sDigest` 实现 Noise `CipherState`、`SymmetricState` 与 `XXpsk3`/`KK` `HandshakeState`。
- 通过 Go 端 `internal/noise` 生成的 `interop_vectors.json` 完成字节级互操作单测（含 `XXpsk3` 配对、`KK` 断线重连双向加解密与错误 PSK / 静态钥拒绝）。

密钥存储：使用 `DataStore` + Google `Tink` AES256-GCM AEAD（`SecretStore`）持久化 32B 静态 X25519 私钥、device token 与 peer pin 表（`AndroidKeyStore` 作为 Tink master key）。

## 5. 登录与配对流程

### 登录（GitHub OAuth + TOTP）

```
App → Custom Tab: GET /auth/github/start?redirect_uri=sidekick://auth/callback
   → GitHub 页面 → 回调 sidekick://auth/callback?code=…&state=…
   → POST /auth/token/exchange {code}        （relay 校验 state+code）
   → 200 {access,refresh}                    （TOTP 未启用或已验证）
   → 202 {mfa_ticket}                        （TOTP 已启用）
        → POST /auth/totp/verify {mfa_ticket, code} → {access,refresh}
```

- `AndroidManifest` 注册 `sidekick://` scheme intent-filter（`VIEW` + `DEFAULT` + `BROWSABLE`）。
- token 存 DataStore（`datastore-tink` `AeadSerializer` 加密）；access 过期前 1min 主动 refresh；
  refresh 失败 401 → 清 token 回登录页。
- TOTP 绑定在 `settings`：`POST /auth/totp/enroll` 拿 `otpauth://` URI → 显示 QR
  （`qrcode` 库本地渲染，不要外传 secret）→ `confirm` 首个 code → 展示 10 个 recovery codes
  （一次性，提示"只显示一次，请离线保存"）。

### 配对（bridge enroll + Noise pin）

0. **设备标识**：首次登录成功后立即生成 Noise 静态密钥对并
   `POST /devices {kind:"phone", name:机型, pubkey}` → 得 `device_id`（持久化，
   设备列表/吊销/WSS 都以它标识本机）。
1. `settings` → "添加电脑" → CameraX 扫 bridge 终端 QR：
   `{"v":1,"relay":"wss://…","eid":"…","pk":"…","psk":"…"}`（或手输 6 位 `user_code`）。
   QR 页同时显示 bridge 公钥指纹（`sha256(pk)` 前 12 hex），与电脑上
   `sidekick-bridge whoami` 输出核对。
2. `POST /devices/enroll/approve {eid|user_code, device_id}` → 绑定 bridge 到账号。
3. 打开 `/ws/device` → 收到 `paired_devices` → 对 bridge 发起 **XXpsk3**（psk 来自 QR）；
   成功后把 bridge 静态公钥 pin 进本地；psk 用完即弃。
4. 之后每次连接走 **KK**；`remote_static ≠ pinned` → 拒绝连接并提示"设备密钥已变更"
   （不自动重配，防静默 MITM）。

降级：无相机权限 → 手输 `user_code` 走 approve；psk 缺失时 **禁止**降级为无 psk 握手
（那是 MITM 入口），直接报错让用户重新生成 QR。

## 6. UI 规格

### 双主题视觉体系（Dark & Light）

- **三档主题切换**：支持 `system`（默认跟随系统）/ `dark`（Obsidian 暗色 IDE 风格）/ `light`（Daylight Porcelain 亮色 IDE 风格），可在 `settings` 顶部分段切换并持久化于 `SecretStore`（退出登录后保留）。冷启动通过 `values/themes.xml` 与 `values-night/themes.xml` 匹配窗口背景色，避免闪白/闪黑。
- **色彩层级与对比度**：采用完整的 Material 3 `surfaceContainerLowest..Highest` 表面层级 + 1dp hairline 边框卡片；`SidekickExtendedColors` 统一管理连接状态色、聊天气泡色、代码块色、快捷键键帽色；Tool 色板按深/浅底色分别调优（`ToolVisuals.color(tool, isDark)` / `containerColor(tool, isDark)`），映射放 `ui/Icons.kt`。
- **高对比度终端画布**：`Terminal` 视图在浅色主题下依然保持暗色终端画布（`#0B0E14` + 圆角边框容器），确保 ANSI SGR 色彩清晰可读。
- **Edge-to-Edge 与键盘适配**：启用 `enableEdgeToEdge` 并随当前主题切换亮/暗状态栏及导航栏图标；`session` 底部输入栏适配 `navigationBarsPadding().imePadding()`。
- **交互与视觉细化**：登录页品牌头卡片与 E2E/OAuth 徽章；TOTP 6 格分段验证码框；首页呼吸连接状态胶囊、等宽指纹标签与引导空状态；电脑详情页 `ModalBottomSheet` 新建会话与 `LIVE` 徽章；Chat 左右气泡区分、`AnimatedVisibility` 折叠思考/工具卡片及带语言头和一键复制的代码块；扫码页圆角取景框与四角支架；设置页主题切换、TOTP 二维码白色留白框及吊销/登出二次确认弹窗。

| 路由 | 内容 | 验收要点 |
|---|---|---|
| `login` | GitHub 登录按钮 → Custom Tab | 未登录冷启动必到；返回键退出 App |
| `login/totp` | 6 位 code 输入 + recovery code 入口 | 错误 code 抖动提示 |
| `home` | bridge 卡片列表（在线/离线、名称、最后活跃） | 离线置灰；下拉刷新 `/devices` |
| `bridge/{deviceId}` | live sessions 分组在上 + history 列表在下；tab "会话/全部历史" | `Subscribe(updated)` 实时改 `live` 徽标 |
| `session/{sid}` | 顶部标题/工具徽标/在场状态；tab `Chat`/`Terminal`；底部输入栏 | 见下 |
| `pair` | 扫码 + 手输降级 + 配对结果 | 全流程 ≤3 屏 |
| `settings` | 外观主题（跟随系统/深色/浅色）、账号卡片、TOTP 绑定状态、设备管理（吊销）、登出 | 吊销 remote 设备立即生效；主题即时生效并持久化 |

`session/{sid}` 交互与输入栏：
- **顶部与模式切换**：`TopAppBar` 展示工具徽标、标题、实时连接状态胶囊与溢出菜单（同步历史、复制 `session_id`、停止会话二次确认）；双模话柄采用分段胶囊切换 `Chat` / `Terminal`。
- **底部输入栏**：自适应 `navigationBarsPadding().imePadding()`；`+` 多媒体附件面板（图片 / 视频 / 音频选择与剪贴板粘贴，自动标注 `Noise ≤2MiB` 或 `Blob >2MiB` 分级路由 + 待发送附件托盘）、可折叠终端快捷键栏（`⏎`、`Esc`、`Tab`、`S-Tab`、`⌫`、`↑`、`↓`、`←`、`→`、`Ctrl-C`、`Ctrl-D`、`粘贴`）及胶囊文本框（IME action=send 等价于 `submit=true`）。
**输入框获焦时**发 `Presence{REMOTE,typing=true}`（节流 1s），失焦发 false；
对端 `Presence{LOCAL}` 时输入栏上方显示"本地正在输入…"banner（不锁输入，只提示）。

**Chat 视图**（`STREAM_MESSAGES`）：
- `LazyColumn` 按 `seq` 排序；User 右侧气泡与 Assistant 左侧卡片区分（含模型标签、时间与整段复制）；
- `text` 渲染增强 Markdown（标题 / 列表 / 引用块 / 分割线 / 加粗 / 行内代码 / 带语言头与复制按钮的代码块）；
- `thinking` 默认折叠（`AnimatedVisibility` 展开，带左侧强调条）；`tool_call`/`tool_result` 状态着色卡片；
- `media` 媒体卡片：支持图片预览与全屏双指缩放灯箱、视频封面与时长徽章、音频波形与播放条（详见总纲 §3.5）；
- 底部 sticky "回到底部" 悬浮按钮，未上翻时自动滚底；`reset` 事件 → 清空该 conv 的 Room 缓存 + `after_seq=0` 重拉 + 顶部 toast "历史已刷新"。

**Terminal 视图**（`STREAM_SCREEN`）：
- 顶部紧凑控制条：显示行数，支持字号缩放（10–16sp）、自动换行/横向滚动切换与一键复制屏幕文本；
- `core/ansi` 把 `Screen.ansi` 解析成 `List<AnnotatedString>`（只支持 SGR：
  `0,1,3,4,7,30-37,90-97,38;5;n,38;2;r;g;b` + `39/49` reset 前景/背景；其余 sequence 丢弃）。
- 渲染：`LazyColumn` 分块（每 ~50 行一块）+ `item key=revision`；**不要** `Text(ansiString)` 一把梭
  （2000 行 scrollback 会掉帧）。等宽字体 `FontFamily.Monospace`，`lineHeight` 紧凑。
- 底部 sticky "回到底部" FAB；新 `Screen` 到达时若用户未上翻则 auto-scroll。

**会话/历史列表**：
- `HistoryEntry` 卡片：tool 徽标 + title/preview + 相对时间 + `live` 绿点。
- 点 history entry → 若 `resumable` → `StartSessionRequest{tool,cwd,resume_conversation_id}`；
  成功后跳 `session/{sid}`。

## 7. 本地存储

Room（`sidekick.db`）：

```kotlin
@Entity(tableName = "sessions", primaryKeys = ["bridgeId","sid"])
data class SessionEntity(bridgeId: String, sid: String, tool: String, cwd: String,
    title: String?, convId: String?, live: Boolean, lastActivityMs: Long, updatedMs: Long)

@Entity(tableName = "messages", primaryKeys = ["bridgeId","convId","seq"])
data class MessageEntity(bridgeId: String, convId: String, seq: Long, role: String,
    partsJson: String, createdMs: Long, model: String?)

@Entity(tableName = "history", primaryKeys = ["bridgeId","convId"])
data class HistoryEntity(bridgeId: String, convId: String, tool: String, cwd: String,
    title: String?, preview: String?, updatedMs: Long, liveSid: String?)
```

- `messages` 的 `reset` = `DELETE WHERE convId=?` 再重拉；`seq` 不回插，防脏数据。
- 敏感项（DataStore + `datastore-tink`，key 存 AndroidKeyStore）：`refresh_token`、
  `noise_static_priv`、`peer_pins`（Map<deviceId,pubkey>）、`last_bridge_id`、
  以及外观偏好 `theme_mode`（`system|dark|light`，登出保留）。

## 8. 网络与生命周期

- `core/relay`：`OkHttpClient` + `newWebSocket("wss://…/ws/device", headers)`；
  token 401 → 先 refresh 再重连，refresh 也 401 → 登出回 login。
- 重连：指数退避 1s→…→60s + 20% jitter；`CONNECTING/CONNECTED/OFFLINE` 状态
  `StateFlow` 暴露给 UI（顶栏连接点）。
- 生命周期：App 前台 → `ForegroundService` 起 WSS 并持有 `WakeLock`（partial，定时释放）；
  退后台 → service 保留但允许系统回收 → WorkManager `NetworkType.CONNECTED` 约束下
  周期重连窗口（v1 只保证前台体验，后台推送 §10）。
- `presence` 与 `Input`/`Keys` 走当前活跃 WSS；会话切换时 `UnsubscribeRequest`。

## 9. 测试与验收

- [x] **JUnit/Robolectric**：`core/protocol` 分片重组（含乱序/丢片/8MiB 边界）、
  `core/ansi` SGR 解析（真彩/256 色/属性）、
  token 刷新逻辑、`NoiseInteropTest` 与 `flynn/noise` 互操作向量、`core/store` SecretStore/Room 单测。
- [x] **Compose UI test**：登录按钮/认证流、`HomeScreen`/`BridgeScreen`/`SessionScreen` 渲染与输入栏交互（`AppUiTest`）。
- [ ] **手工 e2e**（真机里程碑验收，待有真机/Docker Compose 环境时实测）：
  1. 未登录冷启动 → GitHub 登录 →（若开 TOTP）TOTP → home；
  2. 扫码 → bridge 出现在 home；
  3. 进入一个 codex live session → Chat/Terminal 双视图都有内容；
  4. 输入 `hello` 发送 → tmux 里出现 → 收到新 Screen/Message；
  5. `Esc`/`Ctrl-C`/`↑` 快捷键生效；
  6. 手机切飞行模式 → "离线"提示 → 恢复后自动重连且消息不丢（`after_seq` 续传）；
  7. 在电脑上 nvim attach 同一会话输入 → 手机显示"本地正在输入"；
  8. 吊销该手机设备 → App 被迫登出/断连；
  9. `structured_history=false` 的 agy 会话 → Chat tab 隐藏，Terminal 正常。

## 10. 后续（P6+）

- **推送**：FCM（Google 服务）或 UnifiedPush/ntfy（无 GMS 也通）。注意隐私边界：
  relay 只看到 bridge 上报的**明文 metadata**（"session X needs attention"），
  内容仍 E2E；总纲 P6 再评估是否接受这个泄露面。v1 只做"App 前台时本地通知"。
- agy 结构化历史（若 server spike 成功，Chat 视图直接复用，无额外工作）。
- **媒体端到端收发管线**：按总纲 `§3.5` 落地图片压缩/EXIF 剥离、Opus 语音录制、Tier A Noise 流式分片、Tier B 客户端 AEAD 加密 Blob 上传/断点续传下载与 Media3 音视频播放。
- 多 bridge 并存时的快速切换 UI；session 搜索（Room FTS）。
