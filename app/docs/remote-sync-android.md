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
| 扫码 | `com.google.zxing:core` + `androidx.camera:camera-*` | **3.5.4** / **1.7.0**（11-18） | 100% 离线 YUV 解码（含反色适配暗底终端 ASCII 二维码），无需 GMS 动态模型；`PreviewView` 使用 `COMPATIBLE` 模式 |
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

- **三档主题切换**：支持 `system`（默认跟随系统）/ `dark`（Obsidian `#0C0E12` 终端暗色工作台）/ `light`（Crisp Daylight `#FFFFFF` 亮色工作台），可在 `settings` 顶部分段切换并持久化于 `SecretStore`（退出登录后保留）。冷启动通过 `values/themes.xml` 与 `values-night/themes.xml` 匹配窗口背景色，避免闪白/闪黑。
- **终端原生层次与 WCAG AA 对比度**：列表与分组采用 `0.5dp` hairline 分隔行与 Material 3 `PrimaryTabRow` / `PullToRefreshBox`（去除了多余卡片边框、装饰性圆角底块与无限呼吸圆点）；`SidekickExtendedColors` 统一管理 `#34D399`（Dark）/ `#047857`（Light）状态强调色、聊天气泡色、代码块色与快捷键键帽色；Tool 色板按深/浅底色分别满足 AA 对比度并映射于 `ui/Icons.kt`。
- **高对比度终端画布与性能保障**：`Terminal` 视图在浅色主题下依然保持暗色终端画布（`#0B0E14` + 圆角边框容器）；图片缩略图/海报解码、QR 生成、附件元数据解析与长 scrollback（`>200` 行）ANSI 分块均在后台线程执行；交互控件满足最小 `48dp` 触控区与大字号 `defaultMinSize` 自适应布局。
- **Edge-to-Edge 与键盘适配**：启用 `enableEdgeToEdge` 并随当前主题切换亮/暗状态栏及导航栏图标；`session` 底部输入栏适配 `imePadding()`。

| 路由 | 内容 | 验收要点 |
|---|---|---|
| `login` | GitHub 登录表单 → Custom Tab（Debug 包另带回环地址快速填入与 `POST /auth/dev/login` 本地开发登录） | 未登录冷启动必到；返回键退出 App |
| `login/totp` | 6 位 code 输入 + recovery code 入口 | 错误 code 抖动提示 |
| `home` | 电脑列表（`0.5dp` hairline 分隔、在线/离线区分与错误重试） | 下拉刷新 `/devices` |
| `bridge/{deviceId}` | `PrimaryTabRow`（"会话/全部历史"）+ `PullToRefreshBox` + 虚拟化 `StartSessionSheet` | `Subscribe(updated)` 实时改 `LIVE` 徽标 |
| `session/{sid}` | 单行极简顶栏（`<-` + 工具文字锚点 + 无边框 `Chat / Terminal` 下划线切换 + `...`）与自动显隐标题/状态条；底部输入栏 | 见下 |
| `pair` | 离线 ZXing 扫码（`TextureView` `COMPATIBLE` + 反色解码）+ 手输降级 + 返回前台权限刷新与系统设置跳转 | 全流程 ≤3 屏（Demo 演示模式同样进入真实 `PairContent`） |
| `settings` | 外观主题（跟随系统/深色/浅色）、账号信息、TOTP 绑定、设备管理（标注本机/吊销）、登出 | 吊销 remote 设备立即生效；主题即时生效并持久化 |

`session/{sid}` 交互与输入栏：
- **自适应极简顶栏与自动唤出标题条**：移除冗余胶囊外框，顶栏仅保留 `<-`、工具名称点击锚点、无边框 `Chat / Terminal` 平滑滑动下划线 Tab（`48dp` 触控区，仅指示条轻量滑动、内容区干脆直切，大字体模式自动换行不挤压工具标题）与溢出菜单（内置终端字号/换行/复制屏幕）；进入页面或切换 Tab 时完整标题、连接状态、`session_id` 与终端 `ANSI · N 行` 信息条自然展示 `2.4s` 后平滑收起，弹出键盘、点击对话/终端空白处或向下滚动阅读时自动收起键盘/弹窗与标题条；当手指向上回拉、断开连接、回到前台或点按顶栏工具锚点时自动唤出或固定原标题条，且各悬浮操作按钮统一降为 `1dp` 轻阴影与 `0.5dp` hairline 轮廓。
- **底部悬浮输入框（ChatGPT 风格一体化胶囊）**：自适应 `navigationBarsPadding().imePadding()`；内部为 `16sp/23sp` 无边框文本域（IME action=send 等价于 `submit=true`）、左下角 `+` 多媒体附件面板与可折叠终端快捷键键帽开关、右下角高对比度圆形发送按钮（`↑`）；待发送附件以紧凑条展示在胶囊上方；支持消息引用回复条（`QuotedMessageBanner`）、`@` 工作区文件补全浮层（`ListFiles` E2E RPC）与 `/` CLI 命令补全浮层（`ListCommands` E2E RPC，融合核心内置命令保底含 `/compact` 与磁盘动态发现，并支持「终端实时 `>_`」PTY 直通兜底）。
**输入框获焦时**发 `Presence{REMOTE,typing=true}`（节流 1s），失焦发 false；
对端 `Presence{LOCAL}` 时输入栏上方显示"本地正在输入…"banner（不锁输入，只提示）。

**Chat 视图**（`STREAM_MESSAGES` + `StreamingDraft`）：
- **类 ChatGPT 实时流式响应**：发送消息后立即在对话流底部展示乐观 User 气泡与 `StreamingAssistantTurn`（等待首字时展示紧凑思考指示，收到 `SessionEvent.draft` 后通过逐帧 typewriter 动画与末尾 `▍` 光标平滑渲染 Markdown）；当结构化 `Message` 落盘或原位增量更新完成时无缝切换为正式消息卡片；若新会话初始 `conversation.id` 为空，通过 `_pending_<sid>` 临时分区与 `SessionEvent.updated` 自动迁移并绑定历史库；
- **去重框流式排版（类 ChatGPT / Claude 移动端）**：User 消息为右侧 `RoundedCornerShape(22.dp)` 柔和圆角气泡（`16sp/23sp`）；Assistant 回复**直接铺在纯净主画布上**（浅色为纯白 `#FFFFFF`，深色为 `#0B0E14`），顶部仅极简工具头像+模型名（`15sp` SemiBold + `22dp` 图标），底部附轻量引用回复（`FormatQuote`）与复制按钮；
- `text` 渲染增强 Markdown（类 ChatGPT 移动端字号：正文 `16sp/26sp`、标题 `21/19/17sp`、行内代码 `14sp`、代码块 `13.5sp/20sp`；支持表格 / 语法高亮 / 引用块 / 分割线 / 加粗 / 列表）；
- `thinking`、`tool_call`/`tool_result` 采用轻量无边框内联折叠条，点开才展开等宽 JSON/输出；
- `media` 媒体卡片：支持真实 PNG/JPEG/WebP 缩略图预览与全屏双指缩放灯箱（自动触发 `GetMediaRequest` 拉取并校验原图）、视频封面与全屏 `VideoView` 播放弹窗（点击后加密拉取并播放）、内联 `MediaPlayer` 音频波形与进度播放条，以及底部图片/视频/音频选择后分块加密上传（`UploadMediaRequest` ≤ 16 MiB）并以 `@rel_path` 发送给会话；
- **同机 Agent 工作移交（Handover）**：会话顶部更多菜单提供 `"移交给其他 Agent"`，弹出面板支持选择同机其他 Agent（自动新建同目录会话）或注入到同机另一运行中会话，默认仅发送来源 Agent / Session ID / 工作区元信息与用户输入的交接说明（附带最近对话/终端上下文作为默认关闭的可选项），通过 `HandoverSessionRequest` 交接并直接切换进入目标 Agent 会话；
- 底部 sticky "回到底部" 悬浮按钮，未上翻或主动发送时自动滚底；`reset` 事件 → 清空该 conv 的 Room 缓存 + `after_seq=0` 重拉 + 顶部 toast "历史已刷新"。

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
  9. `structured_history=false` 的无历史工具会话 → Chat tab 隐藏，Terminal 正常；`antigravity` (`agy`) 与 `codex/claude/pi/devin` 均支持 Chat/Terminal 双视图。

## 10. 后续（P6+）

- **推送**：FCM（Google 服务）或 UnifiedPush/ntfy（无 GMS 也通）。注意隐私边界：
  relay 只看到 bridge 上报的**明文 metadata**（"session X needs attention"），
  内容仍 E2E；总纲 P6 再评估是否接受这个泄露面。v1 只做"App 前台时本地通知"。
- agy 结构化历史已在 Go bridge 落地（`conversation_summaries.db` + `brain/<uuid>/.system_generated/logs/transcript.jsonl`），App 侧已同步开启 Chat/Terminal 双视图。
- **后续（Tier B 超大媒体扩展）**：>16 MiB 超大视频加密 Blob 中继断点续传（`BlobPointer`）、移动端直接录制 Opus 语音条与 Media3 高级自定义控制。
- 多 bridge 并存时的快速切换 UI；session 搜索（Room FTS）。
