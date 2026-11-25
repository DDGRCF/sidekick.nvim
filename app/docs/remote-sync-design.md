# sidekick 远程同步设计文档（总纲）

> sidekick 远程同步（手机 App 远程查看和操作本地 AI CLI 会话）的唯一权威总纲。
> 所有实现者（人或 AI）以本文档 + `app/server/proto/sidekick/v1/remote.proto` 为准。
> 若实现中发现与现实的冲突，**先核实真实状态，再回来更新文档**，不要静默偏离。
>
> 状态：P0–P5 已实现并完成单元测试 / in-process e2e 验证（`make e2e` 实时 docker-compose 与真机手工 9 项联调待在目标环境实测），P6 待后续推进。
>
> 子文档（实现细节必读）：
> - **`remote-sync-server.md`** — Go relay + bridge 的技术栈、provider 存储格式、部署、验收
> - **`remote-sync-android.md`** — Kotlin/Compose App 的技术栈、UI 规格、Noise 选型、验收

## 目录

- [1. 目标与范围](#1-目标与范围)
- [2. 总体架构](#2-总体架构)
- [3. 威胁模型与安全设计](#3-威胁模型与安全设计)
- [4. 仓库布局](#4-仓库布局)
- [5. 协议](#5-协议)
- [6. 分阶段实施计划](#6-分阶段实施计划)
- [7. 全局开发规约](#7-全局开发规约)
- [附录 A：关键术语](#附录-a关键术语)
- [附录 B：决策记录](#附录-b决策记录)

---

## 1. 目标与范围

用户在手机上通过 Android App：

1. 查看本地（Neovim + sidekick.nvim 管理的）AI CLI agent 会话列表与历史对话；
2. 以聊天视图和终端视图实时同步会话输出；
3. 在手机端输入文本/按键，驱动本地 agent；
4. 在手机上新建会话、恢复历史会话。

中转服务器是用户自建的公网服务器，只做路由与账号系统，**不能读到对话内容**。

### 范围约束（已定）

- **必须开启 `cli.mux.enabled`**：会话跑在 tmux/zellij 里，Neovim 关闭后仍存活。
  不开 mux 的 Neovim job 会话**不支持远程**（v1，后续可再议）。
- 首批 provider（sidekick tool 名）：`devin`、`antigravity`（agy）、`codex`、`claude`、`pi`。
- 平台：Linux 桌面（bridge），Android（Kotlin + Jetpack Compose）。
- 登录：GitHub OAuth + TOTP 两步验证（无邮箱密码、无 SMTP）。
- 中继：Go + **Gin**，SQLite（`modernc.org/sqlite`），Docker Compose + Caddy 部署。

## 2. 总体架构

```
┌──────────────┐  HTTPS   ┌───────────────┐  WSS(主动外连)  ┌──────────────────────┐
│ Android App  │◄────────►│  sidekick-    │◄───────────────►│  sidekick-bridge     │
│ (Kotlin/     │  OAuth/  │  relay        │  E2E 密文帧      │  (本地 Go 守护进程)   │
│  Compose)    │  REST    │  (公网, Go)   │                 │                      │
└──────┬───────┘          │               │                 │  ┌─ mux 层 (tmux/    │
       │                  │  · 账号/设备   │                 │  │   zellij)         │
       │  WSS + Noise E2E │  · 配对路由    │                 │  ├─ state/history    │
       └─────────────────►│  · 不存内容    │                 │  ├─ launch 助手      │
          密文             └───────────────┘                 │  └─ audit/白名单    │
                                                          └──────────────────────┘
                                          sidekick.nvim 插件:
                                          · `cli.mux.enabled` 会话脱离 nvim 存活
                                          · `Util.set_state` 持久化会话元数据
                                          · `sk/cli/remote.lua` launch 助手（P1 新增）
```

三层信道（自外而内）：

| 层 | 端点 | 内容 |
|---|---|---|
| L1 传输 | App ↔ relay / bridge ↔ relay | WSS（TLS）。两端都**主动外连**，本地不开监听端口 |
| L2 Noise | phone ↔ bridge（经 relay 转发） | Noise 握手 + 加密 transport message；relay 只见密文 |
| L3 应用 | `Frame`（protobuf） | 请求/响应/事件，见 [§5](#5-协议) |

relay 路由规则：**同账号下** `kind=phone` ↔ `kind=bridge` 的 device，按目标 device_id 转发；
relay 只解析设备握手协议（device_id、账号归属），不解析 L2/L3。

## 3. 威胁模型与安全设计

**核心原则：手机上能操作的 agent = 能在你电脑上执行任意命令。** 因此假设：

- 攻击者控制公网 relay 服务器（包括数据库、转发逻辑）；
- 攻击者盗取了用户 GitHub 账号；
- 攻击者截获 QR 配对码图片。

### 3.1 账号系统（relay 侧，细节 → server 文档 §5）

- GitHub OAuth + `GITHUB_ALLOWED_LOGINS` 白名单；可选 `REQUIRE_TOTP`。
- TOTP 两步：OAuth 成功 → `mfa_ticket` → TOTP → tokens；recovery codes 一次性。
- access token 短期 JWT（Ed25519）；refresh token 长期、库只存哈希、家族旋转、可吊销。
- 设备（phone/bridge）可吊销；吊销立即断 WSS。
- 登录/配对接口按 IP + 账号限流；`audit_events` 记登录、配对、吊销事件。

### 3.2 设备配对与 E2E（phone ↔ bridge，协议级约定）

**设备是一等身份**：bridge 与 phone 都必须是 `devices` 表中的注册设备（`device_id` +
`kind` + `pubkey`）才能配对或连接。配对是唯一一次"带外"信任建立：

0. **首次使用先登录标识设备**：bridge 执行 `sidekick-bridge login`（CLI 设备授权流，
   浏览器批准）→ 注册 `kind=bridge` 设备得 `device_id`；phone App 首次登录后同样
   `POST /devices` 注册 `kind=phone` 设备。未完成 login 的 bridge 无法 enroll/serve。
1. bridge 本地生成 X25519 静态密钥对 `S_b`（`identity.key`，0600）。
2. bridge `enroll`（带设备凭证）：relay 建 enrollment 绑到该 `device_id`，
   得 `enroll_id` + 6 位人读码 + `poll_token`。
3. bridge 终端打印 QR，JSON 载荷：
   `{"v":1,"relay":"wss://…","eid":"…","pk":"<S_b.pub b64>","psk":"<一次性 psk b64>"}`。
   **`psk` 由 bridge 本地生成，从不发送给 relay。**
4. App 扫码（或手输 6 位码）→ 已登录 → approve → 绑定账号。
5. 首次 Noise 握手：**`Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`**；成功后双方 pin 对方静态公钥。
6. 之后每次连接：**`Noise_KK_25519_ChaChaPoly_BLAKE2s`**；psk 只用一次即弃。

设计意图：

- relay 完全恶意也无法伪造 handshake（没有 psk、没有静态私钥）；
- QR 泄露 ≠ 沦陷：psk 一次性、enroll 过期失效；
- GitHub 账号被盗 ≠ 内容泄露：token 只决定"能不能连"，Noise pin 决定"连上的是不是你的
  bridge"；未 pin 过的新设备直接被 KK 拒绝。

### 3.3 bridge 本地安全（细节 → server 文档 §3）

- `workspaces` 白名单：`start/input` 的 cwd 必须 `EvalSymlinks` 后落在白名单目录内。
- `tools` 白名单；`audit.jsonl` 记每次远程动作（只记 hash+长度，不记明文）。
- 本地 `sidekick-bridge stop` / `systemctl --user stop` 立即断连。

### 3.4 L2 载荷分片格式（两端实现必须一致）

Noise transport message 上限约 64KiB，屏幕快照/大消息必须分片：

```
+--------+-------------------+------------------------+
| u48    | u8 flags          | u16 chunk_len          |  chunk payload ...
| msg_id | bit0 = LAST       |                        |
+--------+-------------------+------------------------+
```

- `msg_id`：同一 L3 Frame 的分片共用，48-bit 计数器；
- `chunk_len` ≤ 60000；单 Frame 重组上限 **8 MiB**；
- `LAST=1` 的 chunk 到达后按 `msg_id` 重组出完整 protobuf bytes 再 `Unmarshal`。

### 3.5 媒体传输协议（图片 / 视频 / 音频，E2E 加密设计方案）

- **核心约束**：
  - **Relay 零信任**：relay 不得看到媒体明文、原始文件名或 MIME 类型；
  - **单帧与阻塞控制**：L3 Frame 重组上限 8 MiB，因此高清视频/长音频不能塞入单个 protobuf Frame，也不能阻塞低延迟的 `STREAM_SCREEN` / `Input` / `Ctrl-C` 控制流（防队头阻塞 HoL blocking）；
  - **弱网断点续传**：移动端上传/下载大图或视频需支持分块校验与断点续传。

- **双通道分级传输架构（Tier A / Tier B）**：
  1. **Tier A — 小媒体与缩略图直传（≤ 2 MiB：压缩图片、内联缩略图、短语音）**
     - 直接复用现有 Noise WSS 加密隧道；
     - 通过低优先级流式分片 RPC（每片 48 KiB，滑动窗口 `window = 4`）发送，`Input` / `Keys` / `Screen` 帧优先插队调度；
     - 无需依赖 Relay 对象存储，覆盖绝大多数截图与语音消息场景。
  2. **Tier B — 大媒体流式加密 Blob + Noise 指针（> 2 MiB，上限 100 MiB：高清视频、长录屏、无损音频）**
     - **客户端流式 AEAD 加密**：发送端生成随机 256-bit `content_key` 与 `nonce_base`，按 **256 KiB** 分块进行 `XChaCha20-Poly1305`（或 `AES-256-GCM`）加密，AAD 绑定 `blob_id || chunk_idx || is_final` 防重排或截断攻击；
     - **Relay 密文临时中转**：发送端带 JWT 调用 `PUT /blobs/:id` 上传**纯密文**（支持 HTTP `Range` / 分片断点续传，TTL 1 小时或双方确认消费后立即删除，配单对象 ≤ 100 MiB 与单用户配额）；
     - **Noise 指针帧交换**：发送端通过 Noise E2E 发送轻量 `MediaPart` / `SendMediaRequest` 指针（含 `blob_id`、`content_key`、`sha256_plain`、`sha256_cipher`、`mime_type`、`size_bytes`、`width/height`、`duration_ms`、`filename` 以及 ≤ 24 KiB 的 WebP 内联缩略图）；
     - **接收端流式解密**：凭 JWT 拉取密文后边下边解密落盘并校验 `sha256_plain`，避免大文件整块驻留内存。

- **编解码、隐私与 Bridge CLI 适配策略**：
  - **图片**：默认剥离 EXIF/GPS 隐私元数据，按最长边 2048px 转码压缩为 WebP/JPEG（可选原图开关），随消息附带 ≤ 16 KiB WebP 缩略图实现列表秒开；
  - **音频**：移动端语音默认录制 Opus/M4A 32–48 kbps 单声道（~250 KiB/min，绝大部分可走 Tier A）；Android 侧展示波形与播放控制，Bridge 侧可按需调用本地 STT 转写喂给仅支持文本的 CLI；
  - **视频**：默认限制/转码 720p/1080p MP4（`faststart`），提取首帧缩略图与时长；大文件走 Tier B，若目标 CLI 不直接支持视频输入，Bridge 可按关键帧抽帧供多模态模型读取；
  - **Bridge 落盘安全**：解码后的附件仅写入当前会话工作区隔离目录 `<workspace>/.sidekick/attachments/<sha256前12位>_<sanitized_name>`，严格校验 `EvalSymlinks` 不越界后，再把路径安全引用给 CLI。

- **已实现（Tier A 电脑 Agent → 手机图片回传）与待落地草案（P6 双向音视频 / Blob）**：
  - 已在 `remote.proto` 落地 `MediaKind`、`MediaPart`、`Part.media`、`GetMediaRequest`、`GetMediaResponse`；
  - Bridge 侧 (`internal/bridge/media.go`) 支持提取 Codex `image_url` / Claude `image` 及工作区 Markdown/路径图片（严格 `EvalSymlinks` 白名单校验），自动生成 `≤ 24 KiB`（320px）内联缩略图并按 256 KiB 分块响应 `GetMedia`；
  - Android 侧通过 `BitmapFactory` 在聊天气泡展示真实缩略图并在点击后拉取原图至私有缓存，支持全屏双指缩放灯箱查看；
  - 待落地（P6 后续）：`BlobPointer`、`MediaUploadChunk`、`SendMediaRequest` 以及移动端 → 电脑端的图片/视频/音频加密上传。

## 4. 仓库布局

```
sidekick.nvim/                       主仓库（nvim 插件 + 文档）
├── app/
│   ├── docs/
│   │   ├── remote-sync-design.md    ← 本文档（总纲）
│   │   ├── remote-sync-server.md    ← Go 技术栈子文档
│   │   └── remote-sync-android.md   ← Android 技术栈子文档
│   ├── android/                     submodule → DDGRCF/sidekick.android
│   └── server/                      submodule → DDGRCF/sidekick.server
│       ├── proto/sidekick/v1/remote.proto   ← L3 协议（权威）
│       └── …                            （详细布局见 server 文档 §2）
├── lua/sidekick/cli/ …              nvim 插件（已有）
└── sk/cli/remote.lua                P1 新增：launch 助手入口
```

## 5. 协议

权威定义：`app/server/proto/sidekick/v1/remote.proto`（实现者直接读它，此处只列语义要点）。

- **Frame**：`version` + `id`（发送方单调递增；0 = 事件）+ `reply_to` + `oneof body`；
  响应带 `reply_to`；`id` 不回绕。
- **Hello**：加密通道建立后双方互发；`capabilities`/`tools`/`workspaces` 决定 UI 能力
  （`structured_history=false` 的 tool 不显示 Chat 视图）。
- **Session.id = mux session 名 = sidekick sid**：`"<tool> <sha256(cwd) 前缀>[ <iid>]"`，
  与 Lua 端逐字节一致（`internal/sid` 有 nvim 生成的测试向量）。
  **远程新建会话必须按此命名**，否则电脑端无法识别/attach。
- **Conversation**：`{id, provider, resumable}`；provider 私有字段（文件路径）**绝不离开 bridge**。
- **Message**：`seq` 从 1 起按主链单调；`parts` ∈ `text`/`thinking`/`tool_call`/`tool_result`。
- **reset**：provider 改写历史（压缩/分叉）时置 `reset`；客户端必须清缓存从 `after_seq=0` 重拉。
- **Screen**：v1 全量快照（`capture-pane -e` ANSI）+ 单调 `revision`；不做 diff。
- **InputRequest**：`text` 原样粘贴不解释成按键；按键只走 `KeysRequest` 枚举。
- **Error**：统一 `Error{code,message}`，不带堆栈。

### 协议演进规则

- `proto3`：只准新增 optional 字段/新 message/新 enum 值；**禁止改字段号、改类型、删字段**；
- `PROTOCOL_VERSION` 只在破坏性升级时递增；
- Android 侧 `proto/` 是从 server 同步的拷贝，`sync-proto.sh` 用 SHA-256 校验一致。

## 6. 分阶段实施计划

实现要点与验收清单全部在子文档（server 文档 §3-§8；android 文档 §3-§9）。此处只列目标与完成定义。

| 阶段 | 目标 | 完成定义（验收细节见子文档） |
|---|---|---|
| **P0** ✅ | 协议 + Go 骨架 | `remote.proto`、`internal/sid`（nvim 真实向量）、`internal/state`、CI 绿 |
| **P1** ✅ | bridge mux 层 + launch 助手 + audit + 本地 ctl | `sk/cli/remote.lua`、`internal/{config,audit,mux,launch}`、`bridge ctl` |
| **P2** ✅ | 结构化历史（codex/claude/pi/devin；agy 只终端） | 四 provider `Messages` 解析 + fixture 校验、fsnotify+poll watch、reset 处理 |
| **P3** ✅ | relay 账号系统（Gin） | 登录/TOTP/token 旋转与重放吊销/设备表/GitHub OAuth/RFC 8628 device flow/admin 全链路 + 单测 |
| **P4** ✅ | relay WSS 路由 + 配对 + Noise E2E + 重连 | `internal/noise`（XXpsk3/KK + L2 9B 分片）、`relayhub`、`relayclient`、`bridge serve`、in-process `e2etest`、`deploy/` |
| **P5** ✅ | Android App（登录/配对/会话/双视图/输入） | `core:{protocol,noise,ansi,store,relay}` + `:app` 源码/单测/Compose UI test + `assembleDebug` APK |
| **P6** | agy spike、推送、nvim 联动 | 见子文档"后续"章节 |

依赖关系：P1/P2 可并行（都纯本地）；P3/P4 顺序；P5 依赖 P4（需真实 E2E 通道联调，
但 UI/协议层可用 fake relay 先行开发）；P6 任意顺序。

## 7. 全局开发规约

- **先读后写**：动手前 grep/read 相关代码核实现状，不猜 API 行为。
- **协议只增不减**：proto 字段号不可改；破坏性变化升 `PROTOCOL_VERSION` 并同步三端 + 本文档。
- **安全优先**：新"远程执行"能力必须在 §3 边界内；新依赖 release ≥7 天、钉版本。
- **Lua 单一事实来源**：tool 命令、sid 命名、state 写盘都在 nvim 侧；Go 只读副本或调 nvim。
- **不入库 secret**：`relay.toml`、`.env`、QR 截图、真实会话数据不进 git。
- 每阶段完成 → 更新本文档状态行 + 子文档验收清单勾选。
- commit 风格：`feat|fix|chore|docs(remote|bridge|relay|proto|android): ...`。

## 附录 A：关键术语

- **sid**：sidekick session id = mux session 名，`"<tool> <hash>[ <iid>]"`。
- **conversation**：provider 原生会话 id（如 codex `session_meta.id`、devin `sessions.id`）。
- **structured vs terminal plane**：结构化消息流 vs 终端 ANSI 抓屏流。
- **enroll / pairing**：bridge 向 relay 注册；phone↔bridge 建 Noise pin。
- **reset**：provider 改写历史 → 客户端清缓存重拉。

## 附录 B：决策记录

| 决策 | 理由 |
|---|---|
| 独立 Go bridge，而非 nvim 内置 | nvim 可能未开；无原生 WS/加密；长连接占编辑器线程 |
| mux-only | Neovim job 会话 nvim 关了就没法操作；mux 会话可脱 nvim 存活 |
| 两端主动外连 relay | 本地不开端口，NAT/防火墙无感 |
| Noise E2E + psk 配对 | relay 完全恶意也读不到内容；psk 一次性防 MITM |
| GitHub OAuth + TOTP | 用户指定；免维护密码体系；白名单控制注册 |
| relay HTTP 用 Gin | 用户指定；中间件生态贴合登录与管理端点 |
| SQLite | 单机部署最简单；个人规模足够 |
| `nvim -l` launch 助手 | tool `cmd`/`env`/`mux_focus` 可被用户配置覆盖，Go 不复制 |
| v1 Screen 全量快照 | 增量 diff 复杂收益小；后续再优化 |
| agy 结构化延后 | protobuf blob 无 schema 需逆向；终端平面可用 |
