# 交接文档（HANDOFF）

> 给接手的 agent 会话：先读这一页，再读 `docs/roadmap.md` 与对应版本的
> `docs/tasks/*-evidence.md`。这里的约定与约束优先级高于任何“看起来更快”的做法。

## 1. 当前状态（截至 v1.13.0 发布）

- **App**：仓库内 `pubspec.yaml` 为 `1.13.0+101`（v1.13.0，versionCode 101）。
- **包名（applicationId）**：`com.joopererer.easysave`（`app/android/app/build.gradle.kts` 中 `namespace` 与 Kotlin 源码包路径仍保持 `com.james.easysave`，原因：Android 构建中 `applicationId` 与代码 `namespace` 相互独立，保持 Kotlin 包名不变可避免大量类引用、ProGuard 规则与既有测试路径改动）。
- **下载链路**：新传输链路（`TransferService`）设为默认，「开发者选项」保留「使用旧下载链路（回退用）」开关（默认关闭）。
- **内置 parser**：仓库 `app/assets/parser/` 为 **1.4.17 / manifestVersion 14**，
  bundle sha256 `f49a8928542842b2f6c1d1730c61815500d8c4ce790e50f4dc8be1bbd207eca1`。
- **parser 发布状态**：已发布。`master` 上的 merge commit
  `fdc9386` 打了 annotated tag `parser-v1.4.17`，Release 资产与
  `spec/v2/manifest.json` 已由 CI 更新，`tools/verify_v2_channel.mjs` 校验通过。
- **versionCode 规则**：v1.13.0 正式包使用 **versionCode 101**。**下一个正式 versionCode 必须 ≥ 102**。
- **App 发布状态**：v1.13.0 准备就绪（versionCode 101，待真机验证正式包后再打 tag 推送）。

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

### 2.5 验证包与正式包构建规则

- 测试包 / 验证包：可只构建单架构，如 `flutter build apk --release --build-number <N> --target-platform android-arm64`（体积约 23MB）。
- 正式发布包：必须与以往一致构建通用包（`flutter build apk --release`，体积约 65MB，支持全部目标平台与 ABI）；若改变打包方式或只发布特定架构，必须说明改变的理由并等用户确认。
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

## 6. 经验教训与下一步

### 6.1 v1.12 教训（简要）

1. **保护性阻塞条件必须有真机耗时数据**：不能凭主观假设在关键路径设置过紧的超时或阻塞限制，保护性逻辑必须结合真机真实网络与不同机型实测耗时。
2. **续传起点只能取磁盘上临时文件的实际长度**：续传起点与已下载字节严格以磁盘上实际落盘的物理临时文件长度为准，彻底废除「只增不减」与「取较大者」的假设。
3. **暂停后继续必须恢复同一个任务**：用户暂停后点击继续，必须直接恢复原已暂停的原生任务（保持同一 taskId），绝不能开启新轮次取消旧任务，避免误删 ResumeData 与临时文件。
4. **续传测试必须包含首轮任务**：断点续传测试必须覆盖从头开始下载的首轮任务在暂停与断网时的断点保留与恢复，不能只测试断网重入队后的后续轮次。
5. **不要在插件之上叠加自己的状态机**：充分复用原生与成熟插件（如 `background_downloader`）自身的状态管理机制，避免在其之上重复构建容易产生并发竞态的外部状态机。

### 6.2 v1.13（阶段 0）新传输链路交接说明

1. **新链路架构概览**：
   - **唯一驱动者**：Android 原生前台服务 `TransferService`（`app/android/app/src/main/kotlin/com/james/easysave/transfer/`）持有单一串行调度器 `TransferScheduler`（单线程 Actor）、SQLite 持久化存储 `TransferStore`（`transfer.db`）、`HttpWorker`（OkHttp 断点续传，写入 `filesDir/transfers/<jobId>.part` 与 `<jobId>.meta`）与原生 `TransferFinalizer`（XMP 来源信息注入、C2PA 边车成对原子写入、Live 图双 `IS_PENDING` 原子发布、MediaStore 入库与 MD5 计算）。
   - **双引擎客户端**：主界面与悬浮球引擎（`HostService`）均只作为客户端，通过 `TransferClient`（MethodChannel `easysave/transfer` + EventChannel `easysave/transfer/events`）下发指令与订阅事件，不再各自持有独立下载状态机；历史记录通过 `claimHistoryWrite` 原子抢占保证单次写入。
   - **默认与回退**：自 v1.13 P0-5（dev15）起，`useNewTransferPipeline` 默认为 `true`；「开发者选项」提供「使用旧下载链路（回退用）」开关（默认关闭）。升级时在 `_loadAndReconcile()` 自动执行一次旧任务迁移（仅新链路开启时执行）。

2. **关键日志前缀**：
   - **`[XFER]`**：`TransferService` / `TransferScheduler` / `HttpWorker` / `TransferFinalizer` 的原生传输日志（状态转移、206/200 续传、退避重试、网络监听、锁竞争、收尾耗时与入库结果）。
   - **`[V16BUBBLE]`**：悬浮球原生端（`OverlayService`）及悬浮球与传输服务联动日志（双环进度、状态文案、收尾/失败/空间不足展示）。
   - **`[V16DL]`**：Dart 侧 `DownloadManager` 调度、旧任务迁移（`legacy_migrated`）与结算日志。

3. **下一个版本（v1.14 / 阶段 1 后）待删除的旧代码清单**：
   - `pubspec.yaml` 中的 `background_downloader` 依赖及其原生初始化/权限/数据库调用（`FileDownloader()`）；
   - `DownloadManager` 中的旧链路轮次（`round`）、轮次抢占（`round_preempt`）、过期任务采纳（`adopt_stale_complete`）、僵尸任务二次取消（`zombie_task`）、`auto_resume` 退避定时器、`ResumableDownloadStore` 临时文件接管与 `_cleanupTransferOrphanLegacyTasks`；
   - `DownloadManager` 中的 `_migrateLegacyBatchIfNeeded` 一次性迁移逻辑（确认所有存量用户升级完成后移除）；
   - 「开发者选项」中的「使用旧下载链路（回退用）」与「断网不自动续传（停在『点继续』）」开关及相关回退分支。

### 6.3 下一步

- **v2.0 阶段 1**：Google Drive 登录授权与云端备份队列（复用阶段 0 的 `TransferService`）。
- **v2.0 阶段 2–4**：备份清单同步、换机恢复、仅在云端与空间释放。
- **后续版本**：实况合成为系统动态照片（先小米 MicroVideo）。
- 完整列表见 `docs/roadmap.md`。
