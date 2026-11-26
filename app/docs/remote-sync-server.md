# sidekick 远程同步 — Server 技术栈（relay + bridge）

> 总纲：`remote-sync-design.md`（先读它，本文档只管 `app/server` 仓库内的实现细节）。
> 仓库：`github.com/DDGRCF/sidekick.server`（sidekick.nvim 的 `app/server` submodule）。
>
> 本文档覆盖：bridge 守护进程、relay 服务器、两者共用的协议/加密层、部署与验收。
> **改动任何实现前，先核实总纲与本文件中的"真实存储格式/真实命令"，不要凭记忆写解析器。**

## 目录

- [1. 技术栈总览](#1-技术栈总览)
- [2. 仓库布局](#2-仓库布局)
- [3. bridge 守护进程](#3-bridge-守护进程)
- [4. history 解析器（provider 存储格式）](#4-history-解析器provider-存储格式)
- [5. relay 服务器](#5-relay-服务器)
- [6. E2E 加密与断线重连（Go 侧）](#6-e2e-加密与断线重连go-侧)
- [7. 部署](#7-部署)
- [8. 分阶段验收](#8-分阶段验收)
- [9. 工程约定](#9-工程约定)

## 1. 技术栈总览

| 用途 | 坐标 | 最新版本 | 备注 |
|---|---|---|---|
| 语言/运行时 | `go` | **1.27.4**（11-10） | `go.mod` 当前声明 `1.26.11`（本机 toolchain，1.26 仍在安全支持期） |
| HTTP 框架 | `github.com/gin-gonic/gin` | **v1.12.0**（02-28） | release 模式；登录与管理端点（用户指定） |
| WebSocket | `github.com/coder/websocket` | **v1.8.15**（06-15） | `Accept` 直接吃 `c.Writer/c.Request`，gin 路由下无需 hijack |
| E2E 加密 | `github.com/flynn/noise` | **v1.1.0** | `Noise_XXpsk3` 首连 / `Noise_KK` 复连，`25519_ChaChaPoly_BLAKE2s` |
| TOTP | `github.com/pquerna/otp` | **v1.5.0**（05-16） | enroll/verify/recovery codes |
| JWT | `github.com/golang-jwt/jwt/v5` | **v5.3.1**（01-28） | Ed25519 签名 access token |
| SQLite | `modernc.org/sqlite` | **v1.63.0**（11-22） | 纯 Go 无 CGO；relay DB + devin 会话库只读 |
| 配置 | `github.com/pelletier/go-toml/v2` | **v2.4.3**（07-05） | bridge `config.toml`、relay `relay.toml` |
| 文件监听 | `github.com/fsnotify/fsnotify` | **v1.10.1** | jsonl tail + state dir 变化 |
| protobuf 运行时 | `google.golang.org/protobuf` | **v1.36.12** | v1.37.0 仍在 RC；主 module 唯一运行时依赖 |
| 代码生成 | `buf` + `protoc-gen-go` | buf **v1.75.0**（10-21） | 隔离在 `tools/` 独立 module（见 §9） |
| Lint/CI | `golangci-lint` | **v2.15.0**（10-16） | + GitHub Actions；`make test lint` 必须全绿 |

禁 `latest`/无界范围；加依赖跑 `go mod tidy`（tools 模块单独 `cd tools && go mod tidy`）。

## 2. 仓库布局

```
app/server/
├── proto/sidekick/v1/remote.proto     # L3 协议（权威，总纲 §5）
├── gen/go/sidekick/v1/                # protoc-gen-go 产物（提交入库）
│   ├── remote.pb.go
│   └── remote_test.go                 # Frame round-trip 测试
├── tools/                             # 独立 module：buf + protoc-gen-go 的 tool directives
├── _admin/                            # 管理控制台（Next.js 项目；`_` 前缀被 go 工具忽略，§5.6）
├── cmd/
│   ├── sidekick-bridge/               # bridge 守护进程
│   └── sidekick-relay/                # relay 服务器
├── internal/
│   ├── adminui/      ✅ done          # //go:embed 管理控制台静态导出 + SPA handler（§5.6）
│   ├── sid/          ✅ done          # session-id 命名，与 Lua 逐字节一致（含 nvim 生成的向量）
│   ├── state/        ✅ done          # nvim 持久化会话元数据读器
│   ├── config/       P1               # bridge/relay TOML 配置
│   ├── mux/          P1               # tmux/zellij 抽象
│   ├── launch/       P1               # nvim headless 启动助手客户端
│   ├── audit/        P1               # 审计日志
│   ├── history/      P2               # provider 历史解析（§4）
│   ├── store/        P3               # relay SQLite schema/migrations
│   ├── auth/         P3               # OAuth/TOTP/JWT/token
│   ├── relayclient/  P4               # bridge → relay WSS
│   ├── noise/        P4               # 握手/分片/静态钥 pin
│   └── e2etest/      P4               # in-process 全链路测试
├── deploy/                            # docker-compose + Caddyfile + relay.toml 样例（§7）
├── Makefile                           # generate/build/test/lint/tidy
└── .github/workflows/ci.yml           # test -race + golangci + buf lint + gen drift
```

## 3. bridge 守护进程

### 3.1 进程形态

- 单二进制，子命令：`login`（首次登录，标识设备）、`logout`、`whoami`、`enroll`（配对手机）、
  `serve`（常驻）、`stop`、`status`、`ctl`（本地调试客户端）。
- **`login`（设备授权流，RFC 8628 风格，必须先于一切其他远程功能）**：
  1. `sidekick-bridge login` → `POST /auth/device/code` → 得 `{device_code, user_code(8位),
     verification_uri, expires_in, interval}`；
  2. 终端打印 `verification_uri` + `user_code`（用户在任何浏览器打开——通常已登录 relay
     的浏览器——输入 code 批准）；
  3. 按 `interval` 轮询 `POST /auth/device/token` 直到 `approved` → 得 `{access,refresh}`；
  4. 生成/加载 Noise 静态密钥对 → `POST /devices {kind:"bridge", name:hostname, pubkey}`
     → relay 发 `device_id`；
  5. 持久化 `~/.config/sidekick-bridge/device.json`（0600）：
     `{device_id, relay_url, device_name, pubkey}`；token 单独存 `credentials.json`（0600）。
  **未完成 login 的 bridge 不能 enroll/serve**（`enroll` 直接报错"请先 login"）。
  `logout` 调 `DELETE /devices/:id` 吊销本机 device 并清空本地凭据；`whoami` 打印
  device_id + 指纹（`sha256(pubkey)` 前 12 hex，App 端配对页显示同一指纹供肉眼核对）。
- 常驻控制面：unix socket `$XDG_RUNTIME_DIR/sidekick-bridge.sock`（0600），JSON RPC：
  `{"cmd":"list|capture|input|keys|start|stop|messages|status", ...}` → 单行 JSON 响应。
  `ctl` 子命令就是这个 socket 的 thin client，P1 先实现它不依赖 relay。
- systemd user unit（`deploy/sidekick-bridge.service`，`WantedBy=default.target`），
  **默认不 enable**；也支持直接 `sidekick-bridge serve` 前台跑。

### 3.2 配置 `~/.config/sidekick-bridge/config.toml`

```toml
relay_url = "wss://relay.example.com"
workspaces = ["/home/r/Scripts", "/home/r/projects"]     # cwd 白名单
tools = ["codex", "claude", "pi", "devin", "antigravity"] # tool 白名单
state_dir = ""        # 覆盖 nvim state dir；默认按 XDG/NVIM_APPNAME 探测（internal/state）
audit_log = "~/.local/state/sidekick-bridge/audit.jsonl"
screen_idle_ms = 300  # 抓屏最小间隔
mux_dump_lines = 2000 # capture-pane -S 的行数（与 nvim 侧 mux.dump 对齐）
max_input_bytes = 65536
```

`workspaces` 校验：`start_session.cwd` 必须先 `filepath.EvalSymlinks`，再 `filepath.Rel(ws, cwd)`
结果不以 `..` 开头，否则 `ERROR_CODE_FORBIDDEN`。`tools` 不在白名单内一律拒绝。

### 3.3 `internal/mux`（P1）

接口：`type Backend interface { List() ([]Session, error); Start(spec StartSpec) (Session, error);
Capture(id string, lines int) ([]byte, error); Input(id, text string) error; Keys(id string, keys []Key) error;
Stop(id string) error }`，`tmux`/`zellij` 两个实现。mux 会话名 = `internal/sid` 产出的 sid。

**tmux（已实现行为必须与 nvim 侧 `lua/sidekick/cli/session/tmux.lua` 等价）：**

- **target 永远用 `=<name>` 精确匹配**。sid 形如 `codex 59bb842411d a947bb91`，
  `-t codex` 会前缀匹配所有 `codex *` 会话——这是会误操作的坑。
- List：`tmux list-sessions -F '#{session_name}\t#{session_attached}\t#{session_activity}\t#{session_windows}'`；
  只对能 `sid.Parse` 的会话返回；`attached>0` → `attached_locally`；
  pane 用 `list-panes -t =<sid> -F '#{pane_id}'` 取第一个。
- Start：`tmux new-session -d -s <sid> -c <cwd> <argv...>`；`argv`/`env` 只能来自 `internal/launch`，
  **不得**在 Go 里硬编码 tool 命令。env 形如 `-e K=V`、`-u K`（false 即 unset，同 tmux.lua `add_cmd`）。
- Capture：`tmux capture-pane -p -t =<sid> -S -<N> -E - -e`（`-e` 保留 ANSI SGR）→ `Screen.ansi`。
- Input：`tmux load-buffer -b sidekick-<pane_id> -`（stdin=text）→ `paste-buffer -b <buf> -d -r -t =<sid>`；
  `submit=true` 时隔 50ms 再 `send-keys -t =<sid> Enter`（部分 TUI 把紧贴的 CR 当换行）。
  若 tool `mux_focus=true`（gemini 类），先 `send-keys Escape [ I` 再 sleep 50ms 再粘贴（同 tmux.lua:192）。
- Keys 映射：`Enter/Escape/Tab/BTab/BSpace/Up/Down/Left/Right/C-c/C-d`；只接受枚举，拒绝任意键名。
- Stop：`tmux kill-session -t =<sid>`。
- 实时性：v1 不订阅 tmux control mode；`Capture` 按 `screen_idle_ms` 节流 + `revision` 去重
  （内容 hash 相同不重发）。`pipe-pane` 方案留到性能不足时再上。

**zellij：**

- `zellij list-sessions` 输出带 ANSI color → 先 strip（`\x1b\[[0-9;]*[A-Za-z]`）。
- `zellij action` 作用域要实测 0.44 的 `-s <name>` 是否对 action 生效；不生效则 v1 zellij 只读
  （list + `action dump-screen`），input 返回 `ERROR_CODE_UNSUPPORTED`。
- `dump-screen` 是纯文本无 ANSI；`Screen.ansi` 直接放纯文本，App 端标注"无颜色"。
- **zellij 不支持远程新建会话**（sidekick 的 zellij create 依赖 nvim 内 terminal）：
  `Start` → `ErrUnsupported`。

### 3.4 `internal/launch` + nvim 侧 `sk/cli/remote.lua`（P1，改 nvim 仓库）

Go 不复制 tool 启动逻辑（用户可在 `setup{cli.tools}` 覆盖 cmd/env/mux_focus）：

```bash
nvim --headless -u NONE --cmd 'set rtp^=/path/to/sidekick.nvim' \
  -l /path/to/sidekick.nvim/sk/cli/remote.lua <tool> <cwd> [--resume <conv_id>] [--instance <iid>]
```

`remote.lua` 职责（nvim 进程内）：
1. `require("sidekick.config").cli.tools[tool]` 取最终 `cmd`/`env`/`mux_focus`；
2. 若 `--resume`，走 `provider_sessions`/`managed_sessions` adapter 把 conv id 转成 resume argv
   （如 codex → `{"resume", id}`；pi → 走 `pi-sidekick.ts` 扩展路径，见 managed_sessions.lua:350-362）；
3. `instance_id = provided or Session.instance()`，`sid = Session.sid{tool,cwd,instance_id}`；
4. `Util.set_state(sid, {tool,cwd,instance_id,conversation?})` 落盘（让 bridge/state 读器立即认得它）；
5. `print(vim.json.encode({cmd=..., env=..., mux_focus=..., sid=..., cwd=...}))`，`qa!` 退出。

`internal/launch`：`exec` 上述命令，timeout 3s，解析 stdout JSON；nvim 缺失/超时/非 0 退出 →
`ERROR_CODE_UNAVAILABLE`。失败时若 `remote.lua` 已写 state 但 tmux new-session 失败，
bridge 侧调 `remote.lua --cleanup <sid>`（`Util.del_state`）回滚。

### 3.5 `internal/audit`

- `Append(Record{TS, DeviceID, Action, SessionID, Bytes, DetailHash})`，jsonl 追加，文件 0600。
- `input/keys` 只记 `Bytes` + `DetailHash`（文本 SHA-256），**绝不记明文**。
- 所有远程动作（subscribe/input/keys/start/stop）都过 audit，包括被拒绝的（FORBIDDEN 也记）。

### 3.6 Screen/消息推送循环（P2/P4 接线）

- 订阅表：`session_id → {streams, subscribers}`。
- `STREAM_SCREEN`：每 `screen_idle_ms` `Capture` 一次，`fnv64(ansi)` 变了才发 `Screen{revision++}`。
- `STREAM_MESSAGES`：见 §4 的 watcher；新行解析出 `Message{seq=last+1}` 即发 `SessionEvent.message`。
- `updated`：state dir 变化（fsnotify）或 pane 消失时发 `SessionEvent.updated/closed`。

## 4. history 解析器（provider 存储格式）

> 样本均来自真实机器（2026-11-23）。每种格式一个文件 `internal/history/<provider>.go` +
> `testdata/` 脱敏样本（只保留结构，内容打码）。

统一接口：

```go
type Parser interface {
    Roots(tool ToolCfg) []string                                    // 扫描根目录
    List(root string) ([]HistoryEntry, error)                       // 会话枚举
    Find(root, convID string) (Handle, error)                       // 定位文件/DB
    Messages(h Handle, afterSeq, limit uint64) ([]Message, bool, error) // msgs, hasMore
    Watch(h Handle) (<-chan Event, error)                           // append/reset 事件
}
```

公共约束：

- `seq` = **主链序号**（从 1），不是文件行号（pi/devin 是树）。
- 增量：jsonl 记 `offset`；devin 记 last `row_id`；重启全量重建，不持久化 offset。
- **reset 检测**：文件截断/重写（size 缩、inode 变）或 devin `main_chain_id` 变化 → `reset`。
- `HistoryEntry.preview`：最后一条 user/assistant 文本前 160 字，strip markdown/ANSI。
- cwd 一律从存储内读，**不信任**请求方给的 cwd（防止读错项目）。

### codex — `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`

行格式 `{"timestamp","ordinal","type","payload"}`：

| type | payload | 映射 |
|---|---|---|
| `session_meta` | `{id,cwd,originator,model_provider,source,cli_version,...}` | 会话元数据；conv id = `id` |
| `response_item` | `{type:"message",role,content:[{type:"input_text"\|"output_text",text}]}` | `Message` |
| `response_item` | `{type:"reasoning",summary:[{type:"summary_text",text}]}` | `ThinkingPart` |
| `response_item` | `{type:"custom_tool_call",call_id,name,input}` | `ToolCallPart` |
| `response_item` | `{type:"custom_tool_call_output",call_id,output}` | `ToolResultPart` |
| `response_item` | `{type:"additional_tools"}` | 忽略 |
| `event_msg` | `task_started/task_complete/token_count/item_completed/...` | 忽略 |
| `turn_context`/`world_state`/`token_usage_record` | — | 忽略 |

### claude — `~/.claude/projects/<encoded_cwd>/<session_id>.jsonl`

`<encoded_cwd>` 把 `/` 换成 `-`。行顶层 `{type,uuid,parentUuid,sessionId,cwd,timestamp,message?,...}`：

| type | 映射 |
|---|---|
| `user` / `assistant` | `message.content` block 数组：`text`/`thinking`/`tool_use`/`tool_result` |
| `summary` | `summary` 字段 → 标题 |
| `file-history-snapshot`/`attachment`/`mode`/`permission-mode`/`atis-latch`/`last-prompt`/`cost-state` | 非消息 |

`tool_use` → `ToolCallPart{id→call_id,name,input}`；`tool_result` → `ToolResultPart{tool_use_id→call_id,content}`
（content 可能 string 或 array）。conv id = `sessionId`；`parentUuid` 链 = 主链（v1 按文件顺序即可）。

### pi — `~/.pi/agent/sessions/<encoded_cwd>/<ts>_<uuid>.jsonl`（v3 树）

`PI_CODING_AGENT_DIR` 可改根。行 `{type,id,parentId,timestamp,message?}`：

| type | 映射 |
|---|---|
| `session` | `{id,cwd,version}` → 元数据；conv id = `id` |
| `message` | `message.role ∈ {user,assistant,system,toolResult}`，`message.content` 数组 |
| `model_change`/`thinking_level_change`/`custom_message`/`custom` | 非消息 |

**主链**：取最后一条 `message` 的 `id`，沿 `parentId` 走到 `null`，反转。
`content` 元素 `{type:"text"|"thinking"|"tool_call"|"tool_result"|"image"|...}`；
`toolResult` role → `ToolResultPart`。

### devin — `~/.local/share/devin/cli/sessions.db`（SQLite，WAL）

```sql
sessions(id PK, working_directory, backend_type, model, agent_mode,
         created_at, last_activity_at, title, main_chain_id, ...)
message_nodes(row_id PK AUTOINCREMENT, session_id, node_id, parent_node_id NULLABLE,
              chat_message TEXT /*JSON*/, created_at, metadata)
prompt_history(id PK AUTOINCREMENT, content, timestamp, session_id, is_shell)
```

- conv id = `sessions.id`；标题 `title`；活跃时间 `last_activity_at`（unix ms）。
- `chat_message` JSON：`{message_id, role, content, metadata}`；
  `role ∈ {system,user,assistant,...}`，`content` 随 role 变 —— **实现前先 dump 真实样本分类**。
- **主链**：`sessions.main_chain_id` 是**叶** `node_id`，沿 `parent_node_id` 回溯到 null 再反转。
- 打开方式：WAL 模式下 `immutable=1` 会看不到未 checkpoint 的数据 → 用
  `file:...?mode=ro&_pragma=busy_timeout(3000)` + `BEGIN DEFERRED`；
  增量轮询 `MAX(row_id)` 与 `last_activity_at`。

### antigravity (agy) — `~/.gemini/antigravity-cli`

- 会话索引：`conversation_summaries.db`（表 `conversation_summaries`：`conversation_id`、`title`、`preview`、`step_count`、`last_modified_time`、`workspace_uris`、`parent_conversation_id`，只读打开，过滤子代理会话 `parent_conversation_id != ''`；若无索引 DB 则回退扫描 `brain/*/`)；
- 结构化消息流：`brain/<uuid>/.system_generated/logs/transcript.jsonl`（与 `watchJSONLFile` 增量监听复用）：
  - `USER_EXPLICIT` / `USER_INPUT` → 提取 `<USER_REQUEST>...</USER_REQUEST>` 用户消息；
  - `MODEL` / `PLANNER_RESPONSE` → `thinking` + `tool_calls` + `content`；
  - `MODEL` / `GENERIC` → `ToolResultPart`（支持 `error` 与 `64 KiB` 截断）；
  - `CHECKPOINT` → `ROLE_SYSTEM` 压缩边界提示。
- `ToolInfo.structured_history = true`（同时支持 `antigravity` 与 `agy` 别名）。

## 5. relay 服务器

### 5.1 Gin 结构

```go
r := gin.New() // release 模式
r.Use(gin.Recovery(), slogLogger /*脱敏: /auth/* 不带 query*/, rateLimit)
api := r.Group("")
auth := api.Group("/auth")
dev  := api.Group("/devices", authn)   // authn: JWT → c.Set("device", claims)
adm  := api.Group("/admin", authn, adminOnly) // gh_login ∈ RELAY_ADMIN_LOGINS
```

路由（`{x}` = Gin `:x`）：

```
GET   /auth/github/start?redirect_uri=...  → 302 GitHub
GET   /auth/github/callback                → code → user → mfa_ticket | tokens
POST  /auth/device/code                    → bridge/CLI 发起设备授权（无需登录态）
GET   /auth/device/approve                 → 浏览器输入 user_code 的批准页
POST  /auth/device/approve                 → 已登录用户批准 device_code
POST  /auth/device/token                   → CLI 轮询 → pending | approved{tokens}
POST  /auth/totp/verify                    → mfa_ticket + code → tokens
POST  /auth/totp/enroll                    → 已登录 → secret + otpauth:// QR + recovery codes
POST  /auth/totp/confirm                   → 首个 code 激活 TOTP
POST  /auth/token/refresh                  → 旋转 access + refresh
POST  /auth/logout                         → 吊销 refresh family
POST  /devices                             → 已登录 → 注册设备 {kind,name,pubkey} → device_id
GET   /devices                             → 本账号设备列表
POST  /devices/enroll                      → bridge 设备凭证 → 创建 enrollment（pending）
GET   /devices/enroll/poll?token=          → bridge 轮询批准状态
POST  /devices/enroll/approve              → phone 批准 bridge
DELETE /devices/:id                        → 吊销（断开其 WSS）
GET   /admin/users                         → 用户列表
GET   /admin/audit                         → audit_events 分页
PATCH /admin/users/:id                     → 禁用/启用
GET   /admin/ui/*filepath                  → 内嵌管理控制台（§5.6）
GET   /ws/device                           → WSS 设备通道（§5.4）
```

统一错误体 `{"error":{"code":...,"message":...}}`；`authn` 失败 401，`adminOnly` 失败 403。

### 5.2 SQLite schema（`internal/store`，migrate 按版本序，`schema_migrations` 记账）

```sql
users(id PK, gh_id UNIQUE, login, display_name, avatar_url,
      totp_secret NULLABLE, totp_enabled, disabled_at NULLABLE, created_at);
recovery_codes(user_id, code_hash, used_at NULLABLE, PRIMARY KEY(user_id, code_hash));
oauth_states(state PK, redirect_uri, expires_at, used_at NULLABLE);
auth_codes(code PK, user_id, expires_at, used_at NULLABLE);        -- OAuth code → token
mfa_tickets(ticket PK, user_id, expires_at, used_at NULLABLE);
device_codes(device_code PK, user_code UNIQUE, user_id NULLABLE,
             interval_s, expires_at, approved_at NULLABLE);     -- CLI 设备授权流
refresh_tokens(id PK, user_id, family_id, token_hash, expires_at, revoked_at NULLABLE);
devices(id PK, user_id NULLABLE, kind CHECK(kind IN ('phone','bridge')),
        name, pubkey, enroll_state TEXT, created_at, last_seen_at, revoked_at NULLABLE);
enrollments(id PK, bridge_device_id, user_code, poll_token, user_id NULLABLE,
            expires_at, approved_at NULLABLE);
audit_events(id PK, user_id NULLABLE, device_id NULLABLE, event, detail, ip, ts);
```

连接串：`file:relay.db?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)`。
migrations 在 `store/migrations/0001_init.sql` 起按序，`BEGIN IMMEDIATE` 事务执行。

### 5.3 登录/token 细节

- GitHub OAuth web flow；`redirect_uri` 白名单（`/auth/github/callback` + App 的
  `sidekick://auth/callback`）。`oauth_states` 5min 一次性。
- `GITHUB_ALLOWED_LOGINS` 白名单（含 `RELAY_ADMIN_LOGINS` 超集关系不强制，admin 单独配）；
  白名单外 → 拒绝并写 `audit_events(event='login_denied')`。
- TOTP：enroll 生成 `totp_secret`（此时 `totp_enabled=0`）→ confirm 首个 code 后置 1 并
  发 recovery codes（10 个，bcrypt）。`REQUIRE_TOTP=1` 时未绑定账号登录只到 `mfa_ticket` 步，
  verify 阶段强制先 enroll。
- access token：JWT Ed25519，claims `{sub=user_id, device_id, jti, iat, exp}`，15min；
  私钥 `RELAY_JWT_KEY_PATH`（PEM，启动生成缺省）。
- refresh token：opaque 32B，库只存 SHA-256；`family_id` 串连旋转链；
  **旧 token 二次使用 → 整个 family revoked**（重放检测）。
- `disabled_at` 非空用户：authn 直接 403。

### 5.4 WSS `/ws/device`（P4）

- Header `Authorization: Bearer <access>`（JWT 里必须带 `device_id`）。
- L1 设备握手（JSON，非 Noise）：client→`{device_id,kind,protocol_version}`；
  relay→`{ok, paired_devices:[{id,kind,name,online}]}`。
- 之后每条消息 `{to_device_id, payload}`（payload 为二进制帧，base64 或 binary frame ——
  **v1 用 binary WS frame：前 16B `to_device_id`，余下为 E2E 密文**）。
- 路由：目标必须同 `user_id`、kind 互补（phone↔bridge）、未吊销、在线；否则 close code 4404。
- relay **不缓存** E2E 帧；对端不在线立即回 `{error:"peer_offline"}` 给发送方。
- ping/pong：relay 每 30s ping，10s 无 pong 判死并广播 `updated`（离线）给已配对端。
- 吊销生效：删 device 时主动 close 其 socket 并通知对端。

### 5.5 设备标识与 enroll/pairing（relay 侧）

**设备是一等身份**：任何参与方必须先是 `devices` 表里的一行（`device_id` + `kind` +
`pubkey` + `user_id`）。注册路径：

- **bridge**：`sidekick-bridge login`（§3.1 设备授权流）→ `POST /devices` → `device_id`。
  未注册的 bridge 无法 `enroll`/`serve`。
- **phone**：App 首次登录后 `POST /devices {kind:"phone", name:机型, pubkey}` → `device_id`。

enroll 流程（把 phone 绑到已登录 bridge）：

1. bridge（带设备凭证）`POST /devices/enroll` → `{enroll_id, user_code(6位), poll_token, expires}`，
   enrollment 绑定发起它的 `bridge device_id`；
2. bridge 轮询 `GET /devices/enroll/poll?token=` →
   `pending|approved{user_id, phone_device_id, phone_pubkey}|expired`；
3. phone `POST /devices/enroll/approve {enroll_id|user_code, device_id}` →
   enrollment 批准，双方互相可见对方 device + pubkey；
4. `user_code` 是 QR 扫码的降级路径：App 手动输入 6 位码找到 enrollment 再 approve。

### 5.5b 日志（`internal/logging`）

两个二进制都用 `slog`，默认 text/Info 到 stderr；`log_level` / `log_format`（或
`RELAY_LOG_LEVEL` / `RELAY_LOG_FORMAT`）可切 `debug|info|warn|error` 与 `text|json`。

- 访问日志：`method path status dur_ms ip rid bytes`，鉴权后追加 `user`/`device`；
  `rid` 写入响应头 `X-Request-Id`（可传入，用于把用户反馈对上日志行）。
- 脱敏：`/auth/*`、`/devices/enroll*`、`/admin/ui/*` 的 query 不落日志（`code`/`token` 在其中）。
- 分级：`>=500` → `error`，`>=400` → `warn`，静态资源成功请求 → `debug`（否则每次页面加载刷几十行）。
- `debug` 级别附带 `source`；panic 由 `recoveryMiddleware` 记 `slog` + 堆栈。
- WSS：设备上线/下线、握手失败（带声称的 `device`/`kind`/`version`）都记日志，`online` 是当前连接数。

### 5.6 管理控制台 `/admin/ui`

浏览器后台（用户禁用/恢复、审计日志）是 **Next.js 静态导出**，被 `go:embed` 打进
`sidekick-relay` 二进制，运行时不需要 Node.js，也没有额外容器。

```
_admin/                       # Next.js 项目（Go 默认忽略 `_` 前缀目录，不污染 go list ./...）
├── src/app/{page,login,callback,users,audit}
└── out/                      # next build 产物

internal/adminui/             # Go 侧
├── adminui.go                # //go:embed all:dist + SPA handler（SPA fallback、no-store、immutable 静态资源）
└── dist/                     # 由 make admin-ui 从 _admin/out 拷贝（只提交 .gitkeep）
```

- 挂载点是 `/admin/ui`，**不是** `/admin`：Gin 的 `/admin/*filepath` 会和 `/admin/users`
  这类静态路由冲突，所以 API 与 UI 分开两级前缀。
- `next.config.ts` 的 `basePath` 必须等于 `adminui.BasePath`；`trailingSlash = true`，
  页面导出为 `<page>/index.html`，handler 对无斜杠的页面路径发 301。
- 组件：shadcn/ui 的 `base-nova` 风格（Base UI 原语 + `cn` 包），`components.json` 已固化，
  加组件用 `npx shadcn@latest add <name>`；本机挂代理时该 CLI 会 `other side closed`，需直连运行。
- 构建：`make admin-ui`（`npm ci` + `next build --webpack` + 拷贝），`make build` 依赖它。
  Turbopack 在本机 fixture 下会卡在 "Creating an optimized production build"，因此固定在 webpack 上。
  Docker 侧在 `Dockerfile` 里用 `node:24-alpine` stage 产出 `out/` 再拷进 Go 构建上下文。
- 没有构建产物时 handler 返回 503 并提示 `make admin-ui`，不影响 relay 其余路由。

浏览器登录链路（与 App 的 `sidekick://` 回调并列）：

```
GET /admin/ui/login/  →  /auth/github/start?redirect_uri=https://<domain>/admin/ui/callback/
                      →  /auth/github/callback（GitHub）→ 302 /admin/ui/callback/?code=<one-time>
                      →  POST /auth/token/exchange {code} → tokens | {mfa_required, mfa_ticket}
                      →  POST /auth/totp/verify {mfa_ticket, code} → tokens
```

`allowedRedirectURI()` 放行 `public_url + "/admin/ui/"` 前缀；这类回调走 302 带 code
（不是 JSON token），由 `isBrowserRedirect()` 判定。token 存 `sessionStorage`（不落 cookie，
免 CSRF），401 时用 refresh token 自动续一次。

## 6. E2E 加密与断线重连（Go 侧）

- Noise：`noise.NewHandshakeState(noise.Config{Pattern: noise.HandshakeXX,
  PresharedKey: psk, PresharedKeyPlacement: 3, CipherSuite: noise.NewCipherSuite(
  noise.DH25519, noise.CipherChaChaPoly, noise.HashBLAKE2s)})`。
  首连 phone=initiator XXpsk3（3 条握手消息）；复连 KK（双方已知静态公钥）。
- 握手后 `cs1/cs2` transport；每条 `Frame` proto.Marshal → 分片（总纲 §3.4 帧格式）→
  `EncryptWithAd(nil)` → WS binary frame。
- pin：bridge 把 phone `remote_static` 写 `~/.local/share/sidekick-bridge/peers.json`（0600）；
  KK 握手后校验 `remote_static == pinned`，不匹配 → 断开 + audit `pin_mismatch`。
- psk：`crypto/rand` 32B，内存持有，首次成功 handshake 或 enroll 过期即清零。
- 重连：指数退避 1s→2s→…→60s，±20% jitter；每次新连接重做一次 handshake（新会话密钥）。
- `presence`：bridge 检测 pane 输入（capture diff/键盘事件不可得 → 用"非本端输入引起的屏变"近似）
  发 `Presence{LOCAL}`；phone 端输入框活跃发 `REMOTE`。

## 7. 部署

`deploy/`：

```yaml
# docker-compose.yml
services:
  relay:
    build: ..
    restart: unless-stopped
    volumes:
      - relay-data:/data
      - ./relay.toml:/etc/sidekick-relay/relay.toml:ro
    environment:
      RELAY_GH_CLIENT_ID: ${RELAY_GH_CLIENT_ID}
      RELAY_GH_CLIENT_SECRET: ${RELAY_GH_CLIENT_SECRET}
      RELAY_JWT_KEY_PATH: /data/jwt-ed25519.pem
      RELAY_DB_PATH: /data/relay.db
    expose: ["8080"]

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports: ["443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
    depends_on: [relay]

volumes:
  relay-data:
  caddy-data:
```

```caddyfile
relay.example.com {
    reverse_proxy relay:8080
}
```

```toml
# relay.toml
listen = "0.0.0.0:8080"
public_url = "https://relay.example.com"
gh_allowed_logins = ["DDGRCF"]
admin_logins = ["DDGRCF"]
require_totp = true
access_ttl = "15m"
refresh_ttl = "720h"
```

- GitHub OAuth App：callback 白名单加 `https://<domain>/auth/github/callback` 与
  `sidekick://auth/callback`（GitHub 支持自定义 scheme 回调，需在 App 设置里注册该 URL）。
- Dockerfile：multi-stage（`node:24-alpine` 构建管理后台 → `golang:1.26` build →
  `gcr.io/distroless/static` run），CGO_ENABLED=0。管理后台在镜像里只是静态文件，
  运行时没有 Node。
- 管理后台不需要额外的 GitHub App 配置：GitHub 始终只回调
  `https://<domain>/auth/github/callback`，再由 relay 302 到 `public_url + /admin/ui/callback/`
  （该前缀由 `public_url` 拼出，无独立配置项）。
- 备份：`relay.db` + `jwt-ed25519.pem`；丢 key 只意味全员重新登录，对话内容不在 relay。

## 8. 分阶段验收

> 阶段目标见总纲 §6；此处是可执行验收清单。

### P1（mux + launch + audit + ctl）

- [x] `go test -race ./internal/...` 全绿；mux 测试用**隔离 socket**：`tmux -L sidekick-test -f /dev/null`，
  绝不动用户日常 tmux server（fixture 起 `tmux -L test new-session -d` 再跑）。
- [x] 本地 ctl + mux/state/audit 单测与命令验证（`internal/mux`, `internal/launch`, `internal/audit`, `internal/bridge`）：
  ```bash
  sidekick-bridge ctl start --tool codex --cwd ~/Scripts/sidekick.nvim
  tmux ls                        # 应见 "codex <hash> <iid>"
  sidekick-bridge ctl sessions   # internal/mux.List 输出一致
  sidekick-bridge ctl capture --id 'codex ...' | less -R   # 带颜色的 TUI
  sidekick-bridge ctl input --id 'codex ...' --text 'hello' --submit
  sidekick-bridge ctl keys --id 'codex ...' --key ctrl_c
  sidekick-bridge ctl stop --id 'codex ...'
  ```
- [x] `nvim --headless -u NONE --cmd 'set rtp^=…' -l sk/cli/remote.lua codex $PWD`
  → 合法 JSON 且 `~/.local/state/nvim/sidekick/<sid>.json` 存在；
  `internal/state.List` 能读到（`tests/remote_spec.lua` + `internal/launch` 覆盖）。
- [x] `workspaces` 外 cwd start → FORBIDDEN + audit 有记录（`internal/config` + `internal/bridge` 单测覆盖）。

### P2（history）

- [x] 每 provider：table-driven 单测 + `testdata/` 脱敏样本；`Messages` 输出与 `jq` 手解一致。
- [x] pi/devin：fork 后 `seq` 仍单调；`parentId`/`main_chain_id` 树正确展平。
- [x] watch：追加 jsonl → 事件 <200ms；truncate → `reset`。
- [x] `ctl messages --tool codex --conv <id> --after 0` 输出完整主链（`internal/bridge` RPC + `ctl` 命令已实现并测试）。

### P3（auth）

- [x] store：空库 migrate → 逐表 CRUD；重复 migrate 幂等（`schema_migrations`）。
- [x] auth：`gin.CreateTestContext` + `httptest` fake GitHub（`/login/oauth/access_token`、
  `/api/v3/user`）跑通全登录；白名单外 login → 403 + audit。
- [x] 设备授权流：`POST /auth/device/code` → 模拟浏览器 approve → `POST /auth/device/token`
  返回 tokens；`POST /devices` 注册得 `device_id`；过期/重复 approve 拒绝。
  未 login 的 bridge 调 `enroll` → 401/403。
- [x] TOTP：`pquerna/otp` 已知 secret 生成 code 通过/失败/重放拒绝；recovery code 用后作废。
- [x] token：refresh 旋转发新对；旧 refresh 重用 → family 全吊销。
- [x] admin：非 admin 访问 `/admin/*` → 403。

### P4（路由 + E2E）

- [x] Noise 单测：XXpsk3/KK 双端互操作；错 psk/静态钥 → 握手失败；分片重组 8MiB 边界。
- [x] `internal/e2etest`：in-process relay + bridge + fake phone（goroutine），
  `Hello → ListSessions → Subscribe(screen) → Input → Screen` 全链路（含断线重连测试）。
- [ ] 真实链路：`make e2e`（compose 起 relay，本地 bridge serve，脚本化 fake phone client — 需真实 Docker Compose 环境手动实测）。
- [x] 断线：kill 一端 → 5s 内另一端检测 + 指数退避重连成功（in-process `e2etest` 已覆盖）。

## 9. 工程约定

- `make generate`（`go tool -modfile=tools/go.mod buf generate`）、`build`、
  `test`（`-race`）、`lint`（golangci + buf lint）、`tidy`（主 module + `cd tools`）。
- **go.mod 只留运行时依赖**；codegen 工具全部在 `tools/go.mod`（历史教训：buf 入主 module
  会拖入 90+ 间接依赖并把 protobuf 钉到 pseudo-version）。
- `tools` 模块 tidy 必须 `cd tools && go mod tidy`（`go mod tidy -modfile` 会解析错 module 路径）。
- 生成代码提交入库；CI 检查 `make generate` 后 `git diff --exit-code -- gen/`。
- commit 风格：`feat|fix|chore|docs(bridge|relay|proto|mux|history|auth): ...`。
- 每个阶段完成 → 更新总纲状态行 + 本文件验收清单勾选。
