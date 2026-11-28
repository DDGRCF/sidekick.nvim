# App & Server 更新与发布流程

本流程统一规范 **Android 客户端**、**本机 `sidekick-bridge`** 与 **`jdserver` 生产环境 `sidekick-relay`** 的构建、校验、部署与提交顺序。统一入口脚本为根目录下的 `./scripts/update`。

---

## 1. 一键更新命令总览

```bash
./scripts/update relay      # 更新 jdserver 生产环境 sidekick-relay
./scripts/update bridge     # 更新并重启本机 sidekick-bridge
./scripts/update server     # 同时更新 relay + bridge（Go 单测与 lint 只跑一次）
./scripts/update android    # 检查 proto/UI、跑单测并构建安装 app-debug.apk
./scripts/update android --release  # 检查 proto/UI、跑单测并构建已签名的 app-release.apk
./scripts/update all        # 全量更新（relay + bridge + android）
```

常用参数：
- `--release`：构建已签名的 Android Release APK（`assembleRelease`，并自动调用 `apksigner verify` 验签），默认打 `debug` 包
- `--skip-tests`：跳过 Go / Gradle 单测与 `golangci-lint`（仍保留 proto 同步校验、构建与服务健康检查）
- `--no-install`：仅构建 Android APK，不执行 ADB 安装/推送
- `--host <ssh_host>`：指定 Relay 部署主机（默认 `jdserver`）
- `--device <pattern>`：按机型或序列号筛选 ADB 设备（如 `--device V2419A`）

> 也可以在 `app/server` 下单独执行 `make deploy-relay RELAY_HOST=jdserver` 进行纯 Relay 原子部署。

---

## 2. 各端更新细节与校验标准

### 2.1 `jdserver` 生产 Relay（`./scripts/update relay`）

`jdserver`（`117.72.202.164`，Ubuntu 24.04 systemd，无 Docker）由 Caddy 监听 `80/443` 反代到本机 `127.0.0.1:8080`：

1. **Proto 一致性校验**：执行 `app/android/scripts/sync-proto.sh --check`，确保 Android 与 Server 协议未漂移。
2. **Go 验证**：`cd app/server && go test -race -p 2 ./... && golangci-lint run`。
3. **静态构建**：先通过 `make admin-ui` 生成管理后台静态资源（写入 `internal/adminui/dist` 供 `go:embed`），再用 `CGO_ENABLED=0 GOOS=linux GOARCH=amd64` 交叉编译静态二进制至 `/tmp/sidekick-deploy/sidekick-relay`（临时文件统一放 `/tmp`，不污染 `$HOME`）。
4. **原子替换并重启**：上传为 `/usr/local/bin/.sidekick-relay.new`，`chmod 755` 后 `mv -f` 覆盖运行中二进制（避免直接 `scp` 报错 `Text file busy`），随后执行 `systemctl restart sidekick-relay && systemctl is-active sidekick-relay`。
5. **公网探测**：读取 `jdserver:/etc/sidekick-relay/relay.toml` 中的 `public_url`，请求 `${public_url}/auth/relay` 确认接口正常返回 JSON。

#### `jdserver` HTTPS 与 GitHub OAuth 注意事项
- **纯 IP HTTPS（无需备案域名）**：`/etc/caddy/Caddyfile` 使用 Let's Encrypt `shortlived` IP 证书（`default_sni 117.72.202.164`）；请勿改用 `sslip.io` / `nip.io`（边缘会按未备案域名 403 拦截）。
- **`github.com` 解析固定**：`/etc/hosts` 已保留 `github.com` 固定 IP 映射，确保 OAuth token 交换不因 DNS 异常失败。
- **GitHub OAuth 凭据区分**：`relay.toml` 的 `gh_client_secret` 需要的是 GitHub 页面点击 **`Generate a new client secret`** 生成的 **OAuth Client Secret**（而不是 `.private-key.pem` RSA 私钥）；正式开启公网 GitHub 登录后，应关闭 `dev_login = false`。

### 2.2 本机 `sidekick-bridge`（`./scripts/update bridge`）

1. 执行 Go 测试与 lint（若与 `relay` 同次运行则自动复用本次通过结果）。
2. 执行 `cd app/server && make build`，产出 `bin/sidekick-bridge` 与 `bin/sidekick-relay`。
3. 重启本机用户态 systemd 守护进程（优先匹配已有的 `sidekick-bridge.service` 或 `sidekick-local-bridge.service`，均不存在时通过 `systemd-run --user` 拉起并日志落盘到 `~/.local/state/sidekick-bridge/bridge.log`），校验 `ActiveState=active`。

#### 切换本机 Bridge 到公网 Relay vs 本地调试 Relay
- Bridge 配置文件：`~/.config/sidekick-bridge/config.toml`（其中 `relay_url = "https://117.72.202.164"` 走公网；`relay_url = "http://127.0.0.1:18090"` 走本地 USB 调试 Relay）。
- 修改 `relay_url` 后需重新运行 `app/server/bin/sidekick-bridge login` + `enroll` 绑定公网账号与新配对码，并重启 Bridge；若仍用本地调试口，仅需保持 `adb reverse tcp:18090 tcp:18090`。

### 2.3 Android 客户端（`./scripts/update android`）

1. 执行 `app/android/scripts/sync-proto.sh --check`。
2. 若存在 `.agents/skills/unslop-anything/scripts/detect.js`，对 `app/android/app/src/main/kotlin/dev/ddgrcf/sidekick/ui/` 执行静态扫描，确认 **0 findings**。
3. 使用 `JAVA_HOME=/opt/android-studio/jbr`（或当前 `JAVA_HOME`）执行 `./gradlew test assembleDebug --no-daemon`（加 `--release` 时改为 `assembleRelease`）。
4. `--release` 模式下会自动调用 Android SDK `apksigner verify --print-certs` 对 `app-release.apk` 验签。
5. 自动检测在线 ADB 设备：仅当本机 `~/.config/sidekick-bridge/config.toml` 的 `relay_url` 指向 `127.0.0.1` / `localhost` 时配置 `adb reverse tcp:18090 tcp:18090`；执行 `adb -t <tid> install -r`（Debug 为 `app-debug.apk`，Release 为 `app-release.apk`）。若设备安装权限弹窗未放行或发生签名冲突，自动回退 `adb push` 到 `/sdcard/Download/sidekick-debug.apk` 或 `/sdcard/Download/sidekick-release.apk`，并检查 `dumpsys package dev.ddgrcf.sidekick` 更新时间。

#### Release 签名包打包、图标与体积裁剪

- **签名配置读取顺序**（均在 Git 忽略范围外或 `.gitignore` 忽略，严禁提交到仓库）：
  1. 环境变量：`SIDEKICK_KEYSTORE_PATH`、`SIDEKICK_KEYSTORE_PASSWORD`、`SIDEKICK_KEY_ALIAS`、`SIDEKICK_KEY_PASSWORD`（CI 推荐）
  2. 环境变量 `SIDEKICK_SIGNING_PROPS` 指定的 properties 文件
  3. 工程内被 `.gitignore` 忽略的 `app/android/keystore.properties`
  4. 本机持久化签名文件：`~/.config/sidekick-android/signing.properties` 与 `~/.config/sidekick-android/release.jks`（权限 `0600`）
- **首次初始化新签名库（若本机尚未创建）**：
  ```bash
  mkdir -p ~/.config/sidekick-android && chmod 700 ~/.config/sidekick-android
  keytool -genkeypair -keystore ~/.config/sidekick-android/release.jks -storetype PKCS12 \
    -keyalg RSA -keysize 2048 -validity 10000 -alias sidekick-release \
    -dname "CN=DDGRCF, OU=Sidekick, O=Sidekick, L=Local, ST=Local, C=CN"
  ```
  同时创建 `~/.config/sidekick-android/signing.properties`（`chmod 600`），写入 `storeFile`、`storePassword`、`keyAlias=sidekick-release`、`keyPassword`。**请妥善备份 `~/.config/sidekick-android/`**：一旦丢失签名证书，后续所有 Release 包都无法在同一包名下覆盖升级安装。
- **Release 体积裁剪与图标**：
  - Release 构建默认开启 **R8 代码裁剪（`isMinifyEnabled = true`）+ 资源压缩（`isShrinkResources = true`）**，规则维护在 `app/android/app/proguard-rules.pro`（保留 `kotlinx.serialization`、Wire Proto、Room 3、WorkManager）。
  - 仅打包真机 `arm64-v8a` ABI 与 `zh`/`en` 语言资源，并排除 `DebugProbesKt.bin`、多余证书与 BouncyCastle PQC 静态资源。
  - 桌面图标采用纯矢量 Adaptive Icon（`ic_launcher_background` / `ic_launcher_foreground` / `ic_launcher_monochrome`）。
- **Debug 与 Release 行为差异**：
  - Release 构建 `BuildConfig.DEBUG = false`，会自动隐藏 Dev Login / Demo Preview 调试入口并禁用明文 HTTP（仅走 HTTPS `jdserver`）。
  - 从旧的 Debug 包首次切换安装 Release 包时，Android 会因签名证书不同报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`，需先卸载手机上的旧版包（`adb uninstall dev.ddgrcf.sidekick`）后再装 Release 包。
  - 若需临时指定版本号，可在 `app/android` 下配合 `-PversionCode=<int> -PversionName=<str>` 或修改 `app/android/app/build.gradle.kts` 中的默认版本。

---

## 3. Git 提交与推送顺序

由于 `app/server` 和 `app/android` 是独立 Git 子模块，更新代码后必须**先子模块、后主仓库**：

1. **有改动的子模块先提交推送**：
   - `git -C app/server add ... && git -C app/server commit -m "..." && git -C app/server push origin master`
   - `git -C app/android add ... && git -C app/android commit -m "..." && git -C app/android push origin master`
2. **主仓库更新记录、CHANGELOG 与子模块指针**：
   - 在根目录 `CHANGELOG.md` 的 `## [Unreleased]` 补充一条对应 `### Features` / `### Bug Fixes` / `### Docs` 记录。
   - `git add CHANGELOG.md app/server app/android ... && git commit -m "..." && git push origin main`
3. **Android Release 发布到 GitHub Releases（如发版）**：
   - 确认已用 `./scripts/update android --release --no-install` 生成并验签 `app-release.apk`。
   - 给 `app/android` 打版本 tag 并推送：`git -C app/android tag -a v<ver> -m "Sidekick Android v<ver>" && git -C app/android push origin v<ver>`。
   - 重命名并生成校验和：`cp app/android/app/build/outputs/apk/release/app-release.apk /tmp/sidekick-deploy/sidekick-v<ver>-arm64-v8a-release.apk && (cd /tmp/sidekick-deploy && sha256sum sidekick-v<ver>-arm64-v8a-release.apk > sidekick-v<ver>-arm64-v8a-release.apk.sha256)`。
   - 发布 Release：`gh release create v<ver> /tmp/sidekick-deploy/sidekick-v<ver>-arm64-v8a-release.apk /tmp/sidekick-deploy/sidekick-v<ver>-arm64-v8a-release.apk.sha256 -R DDGRCF/sidekick.android --title "Sidekick Android v<ver>"`。
