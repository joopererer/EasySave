# 交接文档（HANDOFF）

> 给接手的 agent 会话：先读这一页，再读 `docs/roadmap.md` 与对应版本的
> `docs/tasks/*-evidence.md`。这里的约定与约束优先级高于任何“看起来更快”的做法。

## 1. 当前状态（截至 parser 1.4.17 发布）

- **App**：仓库内 `pubspec.yaml` 为 `1.11.0+59`（v1.11.0，versionCode 59）。
- **用户设备**：装的是验证包 **versionCode 61**（`versionName=1.11.0`，
  内置 parser 1.4.17 / manifestVersion 14），已通过真机验证。
- **内置 parser**：仓库 `app/assets/parser/` 为 **1.4.17 / manifestVersion 14**，
  bundle sha256 `f49a8928542842b2f6c1d1730c61815500d8c4ce790e50f4dc8be1bbd207eca1`。
- **parser 发布状态**：已发布。`master` 上的 merge commit
  `fdc9386` 打了 annotated tag `parser-v1.4.17`，Release 资产与
  `spec/v2/manifest.json` 已由 CI 更新，`tools/verify_v2_channel.mjs` 校验通过。
- **versionCode 规则**：验证包占用了 **60、61**，**正式 App 的下一个版本
  versionCode 必须 ≥ 62**（已写在 `docs/roadmap.md` 顶部）。
- **App 发布状态**：v1.11.0 之后没有再发正式版本；下一次发版就是 v1.12（或
  v1.11.1 修订），versionCode ≥ 62。

## 2. 分支与发布流程

### 2.1 分支

- `master`：随时可发版。所有变更都要经过分支 + **merge commit**。
- `feature/<名字>`：新功能；`hotfix/<名字>`：线上问题。
- 本次是 `fix/parser-1.4.17`（留档，不要删除）。

### 2.2 合并与 tag 规则

- 合并一律 `git merge --no-ff`，**不 squash、不 rebase、不 force push**，
  保证 tag 落在有完整上下文的 merge commit 上。
- 合并后在 `master` 上重跑全部测试；绿了才 push。
- App 版本 tag（`v1.11.0` 这类）只在真正发版时打；parser 走自己的
  `parser-vX.Y.Z`。
- **不改写历史**：已推送的提交、已打的 tag 一律不动。

### 2.3 parser 发布通道

1. parser 代码全在 `extension/src/`，用 `npm run build:parser` 生成
   `app/assets/parser/parser.js` 与 `builtin-manifest.json`。
2. `manifestVersion`（`config/parser-release.json`）**每次 bundle 内容变化都要 +1**；
   App 用它决定是否接受热更新，并与内置版本比较。
3. `spec/PARSER_VERSION` 与 `app/lib/generated/parser_version.dart` 由脚本同步，
   `npm test` 里的 freshness 检查会拦住不一致。
4. 发版：在 merge commit 上打 annotated tag `parser-vX.Y.Z` 并推送 →
   CI `release_parser.yml` 跑测试、构建、签名、上传 Release、回写
   `spec/v2/manifest.json`（该回写是一个 `chore(release)` 提交）。
5. 发布后校验：`node tools/verify_v2_channel.mjs <release-dir> spec/v2/manifest.json <parserVersion> <manifestVersion>`
   （先把 Release 的 `manifest.json` 与 `parser.js` 下载到一个目录）。

### 2.4 旧 App 兼容证明（worktree 做法）

改动 parser 后要证明旧 App 仍可用：

1. `git worktree add ../EasySave-wt/<tag> <tag>` 拉出每个要支持的旧版本
   （如 `v1.10.2`、`v1.10.3`、`v1.11.0`）。
2. 把**未跟踪**的新测试、harness 与新 fixture 拷进去（不修改任何已跟踪文件），
   再拷入新 bundle。
3. 在 worktree 里 `flutter test test/parser_1417_compat_test.dart`。
4. 用完 `git worktree remove --force` + `git worktree prune`。

### 2.5 验证包做法

- 只改 versionCode：`flutter build apk --release --build-number <N> --target-platform android-arm64`
  （不动 `pubspec.yaml` 的版本号，避免污染仓库）。
- 报告里给出 `versionCode`、`versionName`、bundle sha256、包内
  `builtin-manifest.json` 的 `manifestVersion`/`sha256`、证书 SHA-256 指纹。
- 验证包**不得**推送、不得打 tag，等真机验证通过再发布。

## 3. 环境注意事项（Windows + PowerShell 7）

- Node 由 fnm 管理；每条命令先执行：
  `fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression`
  （`fnm` 在 `%LOCALAPPDATA%\Microsoft\WinGet\Links`，不在默认 PATH 时先补上）。
- `JAVA_HOME` 只在需要时**进程内**指向 `D:\Program Files\Java\jdk-21`，
  不要写进用户环境变量。
- **所有文本文件必须 LF**（`.gitattributes` 为 `* text=auto eol=lf`）。
  PowerShell 的 `Set-Content`/`Add-Content`/`Out-File` 可能写成 CRLF，
  写完要检查并转换，否则 `git status` 会出现大量噪音。
- Windows 文件偶发被占用：`flutter test` / `gradlew` / 删除目录可能失败，
  重试或等进程退出；**不要强行结束不是你启动的进程**。
- 测试启动慢是常态（`flutter test` 约 2–6 分钟，`gradlew` 约 1–3 分钟）。

## 4. 安全与流程约束（硬性）

- **签名密钥**（APK keystore、parser 签名私钥）不得读取、打印或复制；
  需要指纹时只读 APK 内的公钥证书。
- **不得读取、输出或记录任何 cookie 值**；日志与报告都要脱敏。
- **不得使用现有登录会话抓取页面**；fixture 只能依据公开匿名页面结构重写，
  并在文件头注明来源方式。
- **fixtures 只增不改**：既有 fixture 输入文件一个字节都不能动。
- 禁止的设备操作：卸载 App、清数据、删相册文件。
- 未经明确授权：不合并、不推送、不打 tag、不发 Release。
- **不改写历史**（不 amend 已推送提交、不 force push）。
- **测试不过不 commit**；不得以“环境缺失”为由跳过测试。
- 截止时间只用于本应很快的步骤，不能拿它当降级测试的理由。

## 5. 真机回归清单

- 清单位于 **`docs/tasks/v1.11.md`**；每个验证包都按它走一遍，额外项目写进
  当次的 evidence 文档。

## 6. 待办

### 6.1 下一版 App（必须在 App 侧修，parser 兜不住）

- **XhsDomain 反复切换**：日志里 `xiaohongshu.com` 与 `rednote.com` 在
  `event=choose … reason=alias_valid` 之间来回切换 15–17 次（ParseWebView
  导航 15–17 次、8.4–8.8s）。要设切换上限，并在检测到未登录重定向
  （`/explore`、`/login`）时立即停止导航。
- **不显示原始异常文案**：界面曾出现 `FormatException: Invalid parser hook
  result`。所有未识别异常都要折成可读文案；已知站点可能需要登录时提供
  「去登录」，不要只给「重试」。
- **TikTok `REGION_RESTRICTED`**：文案要说明是地区限制，登录无法解决。
- 细节见 `docs/tasks/parser-1.4.17-evidence.md` §12 与 `docs/roadmap.md`
  「v1.11 之后的待办」。

### 6.2 后续版本

- **v1.12**：本地缩略图原生按缩小比例解码（独立线程池、可取消）、断点续传
  （`Range` + `If-Range`，ETag / Last-Modified 校验）、后台
  `downloads-init` 4–8 秒的缩短（见 `docs/tasks/v1.12.md`）、缩略图内存与落盘缓存。
- **v1.13**：实况合成为系统动态照片（先小米 MicroVideo）。
- 完整列表见 `docs/roadmap.md`。
