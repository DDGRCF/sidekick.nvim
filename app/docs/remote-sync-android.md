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
| Gradle | `com.android.application` | AGP 最新（随 Android Studio）+ Gradle 9.x | Kotlin 2.3+ 兼容 Gradle 9 |
| SDK | — | compileSdk/targetSdk **37.1**，minSdk **26** | Compose 1.13 要求 compileSdk 37.1 |
| UI | `androidx.compose:compose-bom` | **2026.11.01**（11-19） | Compose 1.13 / Material3 1.5.0；深色优先，`dynamicColorScheme` 可选 |
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
| Noise | **待定（先 spike）** | — | 见 §4，必须与 Go `flynn/noise` 互操作 |
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
- `Frame` 序列化 → `core/noise` 分片（总纲 §3.4 帧格式：`u48 msg_id | u8 flags | u15 len | payload`，
  `chunk_len ≤ 60000`，单 Frame ≤ 8MiB，`LAST=1` 重组）→ Noise 加密 → WS binary。
- 应用层约定：request `id` 单调递增不复用；响应按 `reply_to` 配对，60s 超时；
  `version != PROTOCOL_VERSION_1` 的 Frame 直接忽略并 log。

## 4. Noise on Android（需先 spike）

目标：与 Go `flynn/noise` 的 `XXpsk3`/`KK` + `25519_ChaChaPoly_BLAKE2s` 完全互操作。

候选（**按优先级**，P5 开工第一件事是 spike，产出互操作 demo 再定）：

1. **`com.goterl:lazysodium-android` + libsodium**：libsodium 有 `crypto_kx`/`crypto_aead`，
   但没有现成 Noise pattern 封装——需手写 X25519 DH + ChaChaPoly + BLAKE2s 的
   Noise state machine（工作量中等，库成熟）；
2. **`cashapp/bouncy` 或 BouncyCastle**：手写 Noise，crypto 原语全，但引入大依赖；
3. **裁剪 WireGuard Android 的 noise 实现**（`wireguard-android` tunnel 模块里有
   `NoiseHandshake`，基于自己 fork 的原语）——可读但耦合 WG 逻辑；
4. 纯 Kotlin 手写 Noise（最后手段）。

spike 验收：Go 端起 echo server 跑 XXpsk3+KK；Android 端完成握手、echo 10 条加密消息、
断线重连 KK 再 echo。用 Noise spec 附录的测试向量 + Go 端生成的真实握手 transcript
（存 `core/noise/testdata/`）双端互验。

密钥存储：静态 X25519 私钥优先 `AndroidKeyStore`（`PURPOSE_AGREE_KEY`）；若所选 Noise
实现拿不到私钥做 DH（硬件 key 不可导出），fallback 到 DataStore-tink 存
raw 32B 私钥 + pin 表 —— **spike 时一并验证**。

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

深色优先（M3 `darkColorScheme`），tool 色板：codex=蓝、claude=橙、pi=紫、devin=青、agy=绿
（与 nvim 侧 `Config.cli.icons` 的 glyph 对应的 Material Symbol 映射，icon 放 `ui/icons.kt`）。

| 路由 | 内容 | 验收要点 |
|---|---|---|
| `login` | GitHub 登录按钮 → Custom Tab | 未登录冷启动必到；返回键退出 App |
| `login/totp` | 6 位 code 输入 + recovery code 入口 | 错误 code 抖动提示 |
| `home` | bridge 卡片列表（在线/离线、名称、最后活跃） | 离线置灰；下拉刷新 `/devices` |
| `bridge/{deviceId}` | live sessions 分组在上 + history 列表在下；tab "会话/全部历史" | `Subscribe(updated)` 实时改 `live` 徽标 |
| `session/{sid}` | 顶部标题/工具徽标/在场状态；tab `Chat`/`Terminal`；底部输入栏 | 见下 |
| `pair` | 扫码 + 手输降级 + 配对结果 | 全流程 ≤3 屏 |
| `settings` | 账号卡片、TOTP 绑定状态、设备管理（吊销）、登出 | 吊销 remote 设备立即生效 |

`session/{sid}` 底部输入栏：文本框（IME action=send 等价于 `submit=true`）+ 一排快捷键
chip：`⏎`、`Esc`、`Tab`、`S-Tab`、`⌫`、`↑`、`↓`、`Ctrl-C`、`Ctrl-D` + 剪贴板粘贴。
**输入框获焦时**发 `Presence{REMOTE,typing=true}`（节流 1s），失焦发 false；
对端 `Presence{LOCAL}` 时输入栏上方显示"本地正在输入…"banner（不锁输入，只提示）。

**Chat 视图**（`STREAM_MESSAGES`）：
- `LazyColumn` 按 `seq` 排序；`text` 渲染 markdown（`compose-markdown` 或自写简化版：
  `##` 标题/``` 代码块/行内 `code`/列表/加粗，够用即可——**不要引入完整 CommonMark 渲染器**）。
- `thinking` 默认折叠成一行灰字"思考过程"；`tool_call`/`tool_result` 卡片
  （icon+name+status chip，点开展开 input_json/output 的等宽文本）。
- `reset` 事件 → 清空该 conv 的 Room 缓存 + `after_seq=0` 重拉 + 顶部 toast "历史已刷新"。

**Terminal 视图**（`STREAM_SCREEN`）：
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
  `noise_static_priv`、`peer_pins`（Map<deviceId,pubkey>）、`last_bridge_id`。

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

- **JUnit/Robolectric**：`core/protocol` 分片重组（含乱序/丢片/8MiB 边界）、
  `core/ansi` SGR 解析（Go 端 `capture-pane` 真实样本存 `testdata/`）、
  token 刷新逻辑、Noise spike 的互操作 transcript。
- **Compose UI test**：登录按钮→fake relay 回调；会话列表渲染 fake `ListSessionsResponse`；
  session 输入栏交互（fake `InputRequest` 断言发出）。
- **手工 e2e**（里程碑验收，P5 完成标准）：
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
- 多 bridge 并存时的快速切换 UI；session 搜索（Room FTS）。
