# Build 27 / Parser 1.4.10

App **1.10.0+27**，内置解析器 **1.4.10 / manifestVersion 6**。本轮继续当前工作区的小红书下载 cookie、后台 SAF、解析响应及历史/预览复用修复，并在同一个 APK 中补齐 Instagram AI 文案和悬浮球选择下载标记。

## 更新顺序与范围

**必须先覆盖安装 build 27，再检查云端 1.4.10。** A 的新任务 cookie 配置可由模块更新生效，
但旧任务重试、B/C/D、日志与界面修复均包含 Dart/Kotlin，单独热更新不能完成本轮修复。
APK 已内置完整 1.4.10，可先用内置测试，随后在“我的 → 解析器版本”确认 remote 激活及重启保持。
保持相同调试签名覆盖安装，不卸载、不清数据。1.4.9 已发布，本轮不复用它的 tag。

## 问题 A：小红书 Cookie 拒绝

实际拒绝点是 `DownloadManager._enqueueAttemptOnce`：授权得到非空 cookie 后，后台传输分支直接抛出
`REQUEST_COOKIE_DOMAIN_REJECTED`，并非 ci 不属于媒体白名单。`ci.xiaohongshu.com` 实际匹配
父域 `xiaohongshu.com` 的 cookie scope；SNS CDN 不匹配。扫码登录后 CookieManager 能返回继承 cookie，
才暴露此前的冲突。

历史核对：拒绝守卫早在 `bbcef4c`（当时 build 9）存在；`14927de`（当时 build 17）将小红书
download.cookieDomains 从空数组改为双域，但 transport 仍是 background。build 23、24、25、26
相关代码与配置相同，**不是 build 25 新引入**。此前能下载取决于候选是否走 SNS CDN、ci 是否被尝试，
以及 jar 是否返回登录 cookie；不能从这次现场反馈推断某个 build 首次命中。

改动：

- 小红书 download.cookieDomains 恢复空数组，登录用 auth/session 配置保持不动。
- 每次授权只对“当前站点许可 cookie scope ∩ 当前资源声明 scope ∩ 实际目标域名”读取并发送 cookie。
  非匹配范围不读 jar、不发 Cookie，保留 HTTPS、mediaHosts、头白名单、过期和重定向校验。
  旧任务残留的有效域名声明也只被剥离，不因此拒绝整个请求；格式非法仍被安全校验拒绝。
- 可选配置 cookieRequiredHosts 明确声明必需 Cookie 的媒体目标，只有它匹配且没有合规 scope 时，
  才产生这类域规则拒绝。有效 cookie 请求留在 Dart 传输，逐跳重新授权，不把凭据持久化进原生任务。
- `[RequestPolicy] REQUEST_COOKIE_STRIPPED host=site_media|cdn_media` 只记录类别，不记录值、名称、地址或 query。

测试覆盖真实 startBatch → 原生 enqueue 边界的 ci/SNS 无 Cookie、ci→SNS→ci 每跳剥离、TikTok
域内读取/跨 CDN 剥离/回域重新读取，以及显式必需范围冲突。另补旧任务兼容测试，先失败后通过。

## 问题 B：部分下载与失败历史

根因：全失败终态仍保留全帖 itemsJson，files_json 为空；旧 `HistoryRecord.fromMap` 据全帖解析候选
推断 8 条文件。下一次 placeholder 合并这些推断行后，日志成为 count=8，fileCount 也被抬成 8。
下载队列又过滤所有终态批次，已有重试按钮对用户不可达。

现在显式 `files_json=[]` 是“没有成功保存文件”的权威状态，只有没有该字段的旧格式继续兼容推断。
占位记录不把媒体候选写成保存文件；仅选中的 jobs 出现在任务列表，成功的旧文件照常保留。
没有真实成功文件的占位卡点击进入选中任务列表，已有成功文件的记录仍进图库。
两种历史布局都显示下载中/下载失败；失败卡显示“下载失败，点击重试”，队列保留批量与单项重试入口。
全失败且没有已有文件的空占位可移除，失败任务仍留在队列；删除本地文件选项继续仅依真实定位文件决定。

发布前额外发现：retryJob 只替换 URL、不替换旧资源声明。已将 URL、角色、cookie 范围一起按新解析结果
刷新，Live 图片不混入 motion、视频不混入 poster，成功任务不修改；入队异常恢复 failed 状态可再次重试。
这 5 条新增测试均先复现失败，再通过。重试不会凭空获得新相册文件，也不会改写已下载文件的元数据。

回归覆盖：8 选 4、失败→再占位不膨胀、部分成功、旧成功保留、真实队列只列 2/4/6/8、两种真实历史卡路由、
失败语义与重试按钮、删除弹窗只计真实文件。也修复真实列表卡操作按钮在 76px 封面上的溢出。
不会通过此次更新猜测删除旧历史中不确定的 legacy 文件行；既有错误记录可只删除记录后重新解析，不必删相册。

## 问题 C：解析等待、重复页面及历史重试

原点击链先 await PreviewOpenGuard（短链展开、开库、按链接查询），之后才设置 busy/resolving。
连续点击可在此窗口多次越过检查；共享解析缓存位于这些等待之后，即使命中也不能立即显示。
悬浮球跳入还先做一轮 `_alreadyDownloaded` 的 DB/HTTP 查询。

现在在首个异步等待前同步占用任务并显示“解析中”；点击链只用已加载历史快照，不等待开库、历史修复、
队列恢复或 watchdog，也不预先重复展开短链。规范化链接在 CachedPostParser 中合并同一进行中的解析；
App 输入、分享和悬浮球进入统一入口。PreviewPage.open 查询真实路由栈，复用同帖已有页并带到前面，
包括其上还有其他页面的情况；近期重解析、历史重解析与批量结果打开也使用这个入口。

`[ParseFlow] event=tap/start/cacheHit/previewShown entry=... waitMs=... dedup=0|1 elapsedMs=...`：
waitMs 为点击到开始的等待，elapsedMs 为各事件相对点击耗时，不记录链接。缓存测试在历史永不回应时仍于
250ms 逻辑时间内打开一页；宿主机聚焦日志可见 cacheHit 约 4ms、previewShown 约 9ms，不能当作设备速度保证。
实际连续 5 次点击仅一次缓存解析和一次预览 push；网络解析同一 ID 的 5 个分享参数变体也仅调用一次。

历史读取发现并修复：正常 getByPostId/getByPostUrl 原先仍启动修复写事务，遇到写锁会排队；
按 LOWER(post_id) 查询和可见记录排序缺少对应索引；10,000 上限记录的 JSON 解码在 UI 线程进行。
现在正常行仅只读查询，增加 folded-ID 与可见时间排序索引，超过 100 行交由 compute 解码。
SQLite EXPLAIN 已确认索引使用；实际 WAL 第二连接持写锁时，正常读取无需等其提交，500 条记录内容/排序保持。

历史超时还有独立 UI 原因：silent 刷新成功不清 `_dbError`，所以重试读成功仍显示旧失败。
现在成功必清错误；开库失败不永久缓存其 Future，超时重试只释放未就绪的打开任务，保留健康连接。
`HistoryTiming step=recent` 增加 rows、queryMs、decodeMs、repairCount、repairMs、decodeMode，便于现场区分开库、
SQL 排队、解码与修复。原 2510–2861ms 日志没有这些分项，不能断言全部由某个因素造成；需用新日志确认现场占比。
watchdog 不再位于点击解析前等待链；原 native=null 重试不能单凭日志归因于移动网络。

## 问题 D：后台 SAF

根因：easysave/saf 原先只在 MainActivity 注册，自定义 channel 不会因创建后台 FlutterEngine 自动注册。
存储操作已提取到 SafStorageBridge，MainActivity 与 HostService 使用同一实现，后台注册在执行 Dart 入口之前。
目录选择保留前台 Activity，检查权限、写入、读取校验、列目录及轮换在后台 task queue 执行。
存储失败只记录类型，移除含目录 URI/文件名的原生错误日志。

两项 Robolectric 测试实际注册 MethodChannel 并调用存储方法；6 项 Dart 测试走真实
owner=background/startBatch → 完成写历史 → 默认 easysave/saf 通道，验证 check/list/write/read/校验后轮换，
及开关、无目录、无权限、空历史和节流。仅外部存储/插件 I/O 为合成替身，没有访问设备私有目录或用户备份。

## AI 标签文案规则

- **Instagram**：只依据帖子根级 `$.ai_label_info` 对象和非空字符串 `attribution_label_text` 识别；无论返回 `AI 内容`、`AI content`、`Contenu IA` 或其他语言，输出及新下载文件的 `prov:aiLabel` 固定为用户已确认的英文界面原文 **`AI content`**。`prov:aiLabelSource=platform` 保持不变。账号级标签、空值、错误类型和仅有 subtitle 的帖子不识别。
- **TikTok**：依据平台数据类型判定，写入英文界面原文：类型 1 为 `Contains AI-generated media` / `platform`，类型 2 为 `Creator labeled as AI-generated` / `author`。
- **小红书**：保持平台固定中文原文。平台识别的 `可能含AI生成内容` 为 `platform`，已支持的作者 AI 声明原样保留并使用 `author`。

**不自动迁移已有文件或历史记录。** 用户在 build 26 下载的两条 AI 帖仍保留 `AI 内容`，由用户删除后重新解析、下载。没有新增数据库升级、扫描改写或相册批量修改。

`[IgAiProbe]` 新增根级 `$.ai_label_info.subtitle_text` 平台说明文案，解析器与 Dart 日志桥接都去除 C0/C1 控制字符、先对完整清洗后文本应用既有 URL/query 过滤，再截取最多 **120 个 Unicode 码点**。原 attribution 日志仍最多 60 个码点。账号树与其他文本没有新增放行；subtitle 不用于改变识别或来源。

## 原生选择下载面板

真实入口为 `background_entry.dart` → `showSelectPanel` MethodChannel → `HostService` → `SelectPanelView`。传递当前帖子的 `postTitle` 和已识别的 `aiLabel`，没有按平台名称猜测 AI。

顶部标题旁使用透明底、橙色描边、白字 `AI` 标记，保持 App 预览页的视觉和披露内容。点击显示原文、平台识别/作者声明/来源未知及“来自平台标注，仅供参考”；服务上下文使用 overlay window 类型。普通、空标签帖子隐藏标记；重新绑定和释放面板清理详情弹窗。

`SelectPanelAiTest` 直接实例化、挂载、测量、布局和绘制真实 `SelectPanelView`，覆盖小红书、X、TikTok、Instagram；验证标题与 badge 同行、实际可见尺寸、点击详情、复用时隐藏和作者来源。图片由 Robolectric 原生图形模式输出到 `app/android/app/build/reports/ai-panel/`，属于宿主机实际 View 渲染，不等同于设备截图。

APK 检查工具 `tools/verify_build27_apk.py` 核对包内 parser/manifest 与本次源码产物完全一致、真实 Dart kernel 中的后台入口与日志桥接源码，并反汇编 APK DEX，检查 HostService 的参数读取及实际调用 `SelectPanelView.setPostMetadata` / `setItems`，保留原生类反汇编。

## 回归发现与修复

- 新 Instagram 测试先复现本地化输出及 subtitle 未记录：5 项失败，再修正实现；原始日志 `app/build/ai-label-red.log` 保留。
- 发布与 Flutter 更新恢复测试原先写死 manifestVersion 5，改为依据当前内置版本校验防回退水位，没有降低防回退要求。
- 上一轮小红书已改 cookieDomains 为空；更新旧预览测试的期待，并继续核对没有 Cookie 请求头。
- 单飞解析的 miss 日志仍等待落盘，导致快速重复请求测试不能及时进入网络解析；沿用 hit 日志的异步方式，保留诊断。
- 路由复用测试改为等待实际转场结束后检查旧页面已移除，保留深度及页面数量断言。
- 原生作者来源断言使用 `CharSequence.toString()` 比较实际文案；未删掉断言。缩略图性能阈值保持原值。

## 最终验证与 APK

- Flutter 最终全量 **815/815**（`app/build/v1410/flutter-publish.log`）；发布前新增的旧 Cookie scope/
  重试资源修复已包含其中，策略与重试定向验证 **28/28**。此前 809 项通过日志仍保留。
- Android 全量 **100/100**，新增真实原生面板 **2/2**，0 skipped。最终日志 `app/build/ai-android-local-temp.log`，JUnit XML 在 `app/build/app/test-results/testDebugUnitTest/`。
- 原生缩略图性能测试在 C 盘默认临时目录中独立复测仍超时（最大排队 134 ms），在工作区 JVM 临时目录中全量通过，最大排队 **30 ms**，原 **100 ms** 阈值及全部断言保持不变。通过仅设置本次命令的 `JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=D:\workspace\IdeaProjects\EasySave\app\build\jvm-temp` 实现；未修改系统环境或生产缓存逻辑。保留 `ai-android-tests.log`、`ai-android-final.log`、`ai-thumbnail-isolated.log` 失败证据。
- TypeScript 检查、Vitest **205/205**、Node 发布检查 **28/28**；parser、extension 及 unsigned candidate 构建通过。
  最终模块与配置记录在 `app/build/v1410/extension-final.log`、`candidate-publish.log`；候选不使用私钥。
- Dart 应用代码分析 `dart analyze --no-fatal-warnings lib` 退出 0，无 error，现有 warning/info 共 53 项。整项目 Flutter analyzer 长时间无输出，终止本任务的两个 analyzer 进程后改为限定 `lib` 分析；IDE analyzer 未终止。全量 Flutter 测试覆盖测试代码编译。
- `git diff --check` 通过。没有跳过测试、降低性能阈值或添加 lint suppressions。

APK：[EasySave-1.10.0-build27-debug.apk](../../app/build/app/outputs/flutter-apk/EasySave-1.10.0-build27-debug.apk)，**202,048,585 bytes**。
包名 `com.james.easysave`，versionName **1.10.0**，versionCode **27**。
SHA-256：`2deba30a57d771f1ff77bba7e7741e214d12c695a1f21bd956baa4dd7bcf2668`。
`apksigner verify` 通过，证书 SHA-256 `7ec6c14f1c8c9fff6de9a31fda73150c12db7c81c98ee8017960d838aecb3484`，与 build 26 相同。
内置 parser SHA-256：`b10fab6ebe6ef2ddcace7f2e59c82e2c32d9ab7dd4f7a64772ef4b65212cde0a`。

`tools/verify_build27_apk.py` 检查通过：包内 parser 和 manifest 字节/摘要一致，后台入口、日志桥接、解析服务及请求策略的真实 kernel 内嵌源码与当前源码逐字节匹配；DEX 中存在 `HostService` 的 `postTitle` / `aiLabel` 参数读取、`SelectPanelView.setPostMetadata` / `setItems` 调用，以及 `WindowManager.addView` 的真实窗口挂载。
最终检查包含 11 份真实 kernel 内嵌源文件，覆盖解析入口、历史、队列、卡片、下载与请求策略；
DEX 另确认 HostService → SafStorageBridge.register、MainActivity → SafStorageBridge.handle 及后台 task queue。
结果在 `app/build/v1410/apk-publish.log`；原生反汇编在 `native-panel-disassembly.txt`；
签名与包信息在同目录 `apk-signature.log`、`apk-badging.log`。较早 APK 证据保留但不作为本次交付摘要。
四个平台的渲染 PNG 在 `app/android/app/build/reports/ai-panel/`，已人工检查 Instagram 图像，AI 标记紧邻标题。以上均为宿主机测试和 APK 证据，不声称设备联网或相册保存已验证。

## 发布与发布后校验

源提交 `4318f1eb95e6846bcde9fe8b1785bc18670fcc9e` 已推送 feature/v1.10，新 tag 为 parser-v1.4.10。
没有复用/删除旧 tag、force push、merge 或手动修改 master；用户原有 51 行任务文档及未提交脚本保留。

- [CI 42210137913](https://github.com/joopererer/EasySave/actions/runs/42210137913)：**success，19/19 步，2m1s**。
  含扩展测试、配置一致性、当前 App 配置契约及扩展后的 16 个 App 回归测试文件门槛；
  签名、上传、回读和通道更新全部通过。只有托管 Node/Ubuntu 迁移提示，没有失败步骤。
- [Parser 1.4.10 正式 Release](https://github.com/joopererer/EasySave/releases/tag/parser-v1.4.10)：
  非 draft / prerelease，仅 parser.js（68,458 bytes）和 manifest.json（12,701 bytes）。
  manifest SHA-256：`92e853b12f468d04d6ed4fe56bb999b1709e0c9b3461e8f1f1d139395e84320f`。
- 使用固定 App 公钥独立校验 Release、master envelope 的原始 UTF-8 payload Ed25519 签名、版本、
  下载地址和 parser SHA-256；两份 envelope 逐字节相同。签名私钥没有在本地读取或使用。
- 匿名公开下载 parser 与 raw master 通道，分别与 Release 文件相同；完整 payload 与最终 APK 内置
  manifest 相同，parser 与 APK 内置 parser 字节相同。模块确为 **1.4.10 / manifestVersion 6**。
- 实际发布文件通过 App 的生产验签、配置契约、ParserReleaseStore 激活和全新 ParserManager 重载，
  两次均为 remote / 1.4.10 / 6，防回退水位 6。
  配置摘要：`89851b195ae8b34403ca57e6afb4fe38a56b7e4f168ce79875318021436beee1`。
- CI 自动更新 master 为 `5b5cc44a8608719371c5e85dffb917bc0e3594b8`，相对发布前
  `00f1d189c0aed954f3203a2ea80a6d44a55304c9` 仅修改 spec/v2/manifest.json；本地只 fetch 核对。

发布证据在 `app/build/v1410/release-readback.log`、`release-activation.log`，签名资产和匿名公开下载副本同目录保留。
宿主机生产路径测试、实际 widget 渲染和 APK 检查均不等同于设备联网、相册保存或后台实际备份结果。

## 设备复测

覆盖安装本轮 APK，先确认 build 27 和内置 1.4.10，再检查云端 1.4.10 激活与重启保持。
不卸载、不清数据、不用删除相册文件制造测试条件。

1. 保持小红书扫码登录，分别在 App 和悬浮球解析用户提供的三条短链，选择部分图片下载；
   检查 ci 与 SNS 候选均可继续请求，日志仅有 COOKIE_STRIPPED 的域名类别。同时回归 TikTok 需要会话的视频。
2. 8 张选择 4 张，检查占位卡为下载中，点击仅看到 4 个任务；成功后历史仅增加实际成功条目。
   解析后可手动暂时断网制造失败：失败任务保留单项/批量重试，恢复网络后点击重试；
   全失败无真实文件时，不应看起来已下载。删除弹窗仅在实际定位到相册文件时提供本地文件选项。
3. 在移动网络下从输入、分享及悬浮球跳入 App；点击立刻显示解析中。连续点 5 次应只有一个任务/预览页。
   同帖从已打开预览之上的页面再次进入，应返回已有预览。对同一已解析链接再次解析，核对 cacheHit 和
   previewShown 日志及实际页面响应；300ms 为目标，宿主机逻辑时间测试不能替代设备响应数据。
4. 历史页出现错误后点重试，读取恢复后应清除旧错误并显示记录；带回 HistoryTiming 的分阶段数量/耗时，
   用于确认现场 2.5 秒开销的组成。ParseFlow 日志不应包含链接、正文或账号。
5. 开启“自动备份到文件夹”并保持已授予的目录权限，通过悬浮球成功下载；检查文件夹按既有节流/去重/
   验证后轮换规则生成备份，无 MissingPluginException。关闭开关或权限不可用时应跳过，不弹后台目录选择器。

分别从四个平台打开悬浮球“选择下载”：有 AI 标签时标题旁显示 `AI` 并能披露原文和来源，普通帖子不显示；长标题不遮挡标记。Instagram 使用不同语言返回标签时，新下载元数据应为 `AI content` / `platform`。
继续复测小红书下载、失败重试、历史回退和后台 SAF。设备播放、相册写入及实际平台联网行为仍需设备验证。
