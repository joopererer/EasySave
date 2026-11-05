# Build 25 / Parser 1.4.8

## 范围和更新顺序

本轮修复小红书最终导航域名选择、配置一致性/拒绝与激活日志，并加入 Instagram AI 字段诊断。
目标 App **1.10.0+25**，解析模块 **1.4.8 / manifestVersion 4**。
真机验证状态：**待用户复测**。用户反馈的 1.4.7 热更新、重启保持及 IG/X/TikTok 下载结果属于上一轮现场反馈。

**必须先覆盖安装 build 25 APK。** 小红书修复涉及 Dart，单独热更新解析模块无法修复 build 24。
build 25 已内置完整 1.4.8，可直接测试；随后点“我的 → 解析器版本”刷新，验证云端 1.4.8 激活及重启保持。
旧 APK 的严格 schema 不认识新增短链字段，会保留原版本，不能据此判断 1.4.8 无效。
安装使用同一调试签名；不卸载、不清数据。

## 问题 1：小红书

根因：旧代码只在 `_parsePostOutcomeUncached` 的短链展开之前调用 `selectXhsPostUrl`。
HTTP 展开结果直接进入 `_run`，所以无 cookie 跳到 rednote 后绕过原有大陆/海外会话选择。
WebView 自身跳转以及 parser `navigate` 要求的再次加载也没有共同边界。

改动：`chooseFinalParseUrl` 在最终解析入口、初始 WebView 请求、主框架导航、`loadStop`
（兼容 Android 不回调跳转拦截的情况）以及 parser 再次导航统一选域。分享、手动输入、悬浮球、
历史重新解析、缓存过期/强制刷新均经过这一入口；有效解析缓存命中不创建 WebView。
导航仍受现有整次解析超时预算约束；不因重复 WebView 回调推断账号登录失效。

`config/sites.json` 的小红书三条短链规则增加 `stopAtPost: true`，schema 声明布尔字段。
通用 HTTP resolver 在 Location 属于同站、受支持且能提取帖子 ID 时停止，不再请求该帖子。
保留帖子地址中的 query，选域时沿用原有 `xsec_token` / `xsec_source` 保留规则。
Dart resolver 没有新增小红书专用的提前停止分支。

新增 `[XhsDomain] event=choose from=... to=... reason=original_valid|alias_valid|none_valid entry=...`。
只输出已知域名和入口标签，不记录地址、cookie 或 query 值。两边无有效会话时保留原域，
到登录终止页即返回 `LOGIN_REQUIRED`；直接 rednote 地址继续遵循原域有效优先、另一域有效才切换。

回归覆盖：首个帖子 Location 提前停止、下一跳将去 rednote 的链路、仅大陆/仅海外/两边无效/两边有效、
direct rednote、token/source 保留及 app/share/bubble/history/cache/WebView 入口。

## 问题 2：1.4.7 与内置 1.4.5 对比及配置契约

实际下载 `parser-v1.4.7` Release 的 `manifest.json` 和 `parser.js`，以 App 公钥独立验签通过。
对比对象为交付的 `EasySave-1.10.0-build24-debug.apk`，直接解 ZIP 读取公开 assets。

| 项目 | 结果 |
| --- | --- |
| parser.js | 字节完全相同，SHA-256 `5bef41b77695ea5858e040cc8cf1cfe41343b43e9e472d4a93ba4077748bed8c` |
| sites（等价 sites.json） | 所有字段相同 |
| platforms / headers / parserAbi / minAppVersion | 全部相同 |
| link-recognition.json | APK 表与云端 sites 投影完全相同 |
| schema | Release 不单发 schema；发布 tag 的 schema 与 APK schema 一致 |
| parserVersion | 1.4.5 → 1.4.7 |
| manifestVersion | 1 → 3 |
| parserUrl | 仅下载地址中的版本段从 1.4.5 变为 1.4.7 |

Release 仅包含两个资产；sites、platforms、headers 等配置在签名 manifest 的 payload 中。
**除版本元数据及其派生下载地址外没有代码/生效配置差异。**
完整比对证据保留于 `app/build/v148/version-comparison.json`。

配置来源：远端激活时，`SiteRegistry.activate(manifest.sitesFor(appVersion))` 使用云端包的站点配置，
不整体合并内置 sites。内置 schema 始终负责验证。原有 `SiteDefinition.terminalPages` 和
`shortLinkFallback` 对旧配置存在内置默认兜底，兼容 getter 保留；build 25 对当前小红书导航
所需字段在激活前明确检查，缺失配置不会依靠兜底激活。Android 识别表是生效 manifest 的投影；
无远端时使用 APK 表。

发布前 `assertBuiltinParity` 比对全部 manifest 生效配置（只排除 parserVersion/manifestVersion）、
内置 schema、生成 Dart sites、Android recognition 表；有差异则构建失败，不生成发布资产。
CI 在签名前额外执行 unsigned candidate 检查；签名构建也重复同一检查。
CI 另执行 `flutter test --no-pub test/parser_config_contract_test.dart`，拒绝一致但缺少当前必需字段的配置。
测试覆盖四类产物不一致时失败，以及仅版本元数据不同可通过。

App 的 `validateAppParserConfig` 检查当前小红书所需 openDomains、probeUrls、sessionCookieNames、
terminalPages 和 stopAtPost；schema 的 required 缺失也产生字段路径。
网络激活前和本地重载时检查，拒绝后使用内置版本，记录
`[ParserUpdate] event=rejected reason=<字段路径>`，不降低既有防回滚水位。
激活/切换记录版本、`source=builtin|remote`、manifestVersion 和 SHA-256 `configHash`；
hash 覆盖去掉版本、下载地址与 parser hash 后的配置 JSON，不记录配置内容。

## 问题 3：Instagram

离线 fixture 对 `/reel/` 和 `/p/` 分别加入 dlrf、vrfl、两者组合，解析 ID、媒体与规范地址一致；
Dart 使用用户两条链接验证识别、canonical 和最终解析入口。未发现分享参数处理缺陷。
连续 `PRIVATE_OR_UNAVAILABLE` 后成功的现场原因仍未确定，不能据离线结果归因于参数或 AI 标记。

`buildPostFromProduct` 对 HTML、DOM、网络缓存等共用帖子对象入口增加诊断。
`probeInstagramAiFields` 遍历匹配 ai/gen_ai/genai/label/disclosure/c2pa 的字段，输出路径、名称、类型；
布尔、有限数字、仅字母数字下划线且 1–40 字符的枚举可带值。正文/URL/账号及 cookie/token/session
等凭据相关子树只带类型；
动态不安全字段名不输出。带循环检测、深度/节点/行数上限。
App 控制台桥再次白名单验证后写 `[IgAiProbe]`，不转储普通控制台输出。
本轮没有新增 AI 内容识别或展示判定。

## 门禁与产物

| 门禁 | 结果 / 证据 |
| --- | --- |
| Flutter 全量 | 最终冻结源码 **737 passed / 0 failures**，85s；`flutter-publish-gate.log` |
| Extension | 177 Vitest + 27 发布构建检查，typecheck 通过；`extension-final.log` |
| Android 全量 | 96 tests / 0 failures / 0 errors，23 suites；`android-final-dtemp.log` / `android-summary.json` |
| QR | 4 passed |
| Extension 生产构建 | exit 0，`extension-build.log` |
| Flutter analyze lib test | exit 0，无 error；修正本轮多行 if 风格后余 89 项 warning/info，`analyze-final.log` |
| APK 构建 | exit 0，最终隐私过滤代码 assembleDebug 137.6s；`build25-privacy-final.log` |
| 回归变异检查 | stopAtPost 条件反转后测试失败，finally 恢复原始字节；`mutation-red.log` |

上述日志均位于 `app/build/v148/`。未跳过测试、未降低阈值；已有主机性能用例的准备和计时边界修正见下。
Android 首轮和单 worker 复测均在既有缩略图读队列性能断言失败（最大等待 143ms / 227ms）；
单独跑该 suite 通过。最终用本机临时 Gradle init 脚本，仅将 JVM `java.io.tmpdir` 指向
`app/build/v148/android-tmp` 后全量通过，实测最大等待 **83ms < 100ms**。
临时目录和首轮/主要失败日志保留；未清理全局缓存、未修改系统环境，也未终止他人进程。

- APK：`app/build/app/outputs/flutter-apk/EasySave-1.10.0-build25-debug.apk`
- 大小：**202,027,640 bytes**。
- SHA-256：`3e4768daa99d5fd72c30c7c368c68f9cdb425dfb041751a85b89788a20705605`。
- aapt：`com.james.easysave`，versionName **1.10.0**，versionCode **25**。
- APK 内置 parser **1.4.8 / manifestVersion 4**，parser SHA-256 与 manifest 相符：
  `bb3364a1d2a3406bca3ef22c4eb5b0bd90b6fb416b7cd7f196eed0e07ac19004`。
- 直接检查 APK kernel 中包含 XhsDomain、ParserUpdate、IgAiProbe、chooseFinalParseUrl、
  stopAtPost、configHash。没有界面布局改动，不以源码截图充当渲染证据。
- 公开签名证书 SHA-256 与 build 24 相同：
  `7ec6c14f1c8c9fff6de9a31fda73150c12db7c81c98ee8017960d838aecb3484`，支持覆盖安装。

既有 `thumbnail_read_contention_test` 在并行和串行运行均曾超时，保留 `flutter-frozen.log`、
`flutter-serial-final.log`。分段测量 `header-cost.log` 得到首次 Dart 文件读取 **426ms**，
直接头检查 **8.6ms**，worker 校验 **43ms**；后续读取 **7.8–12ms**，worker **1–1.8ms**。
先前归因于 worker 的判断被该证据纠正，尝试的 4KiB 生产快路径已完整撤回，
`shared_preview_cache.dart` 与基线相同，没有把校验或写入挪到 UI 线程。

测试准备仅增加一次独立文件 API 读取以排除宿主 VM 初始化，不调用/预热缓存对象；
计时器在缓存操作完成时停止，排除 matcher/JIT 的断言处理时间。
**首次缓存查询、实际文件读取、完整头校验仍在计时范围，100ms timeout 和小于 100ms 断言均保留**，
下载和解码阻塞断言不变。14 项缓存/头完整性专项通过（`contention-warmup.log`），
随后标准参数全量 737 项通过；未以隔离单项通过代替最终全量门禁。

CI 与发布后校验结果在发布完成后追加。
首轮失败保留在 `app/build/v148/flutter-tests.log`；旧测试数据契约及缺省 console.info 问题已修复，
定向重测 45 项通过。Android 首次因机器 JAVA_HOME 错误未启动，后续命令内指定现有 JDK。
既有用户工作区修改（v1.11 的 Gradle 修复记录、未跟踪构建脚本和 .claude）保留，不混入本次代码提交。

## 真机复测步骤

1. 覆盖安装 build 25，保留现有账号和历史；确认 App 1.10.0+25、解析器 1.4.8（内置）。
2. 仅大陆账号有效时，用两条报告的小红书短链分别从 App 与悬浮球解析；检查
   `[XhsDomain]` 选择 xiaohongshu.com、短链命中帖子后不继续无 cookie 跳转，并验证下载。
3. 若具备海外账号，仅 rednote 有效时重复，确认选择 rednote；两边都无效时确认保留原域、
   登录页快速返回 LOGIN_REQUIRED。直接 rednote 分享链接也重复测。不要清 App 数据。
4. 对同一帖子从历史重新解析及强制刷新，检查选域日志；普通缓存命中没有 WebView 加载属于预期。
5. 解析两条报告的 Instagram 帖子（reel 与 p），各测原地址及带分享参数地址，导出用户日志中的
   `[IgAiProbe]`、`ParseWebView validate`；确认是否正是先前连续四次失败的两条地址。
6. 点“我的 → 解析器版本”刷新，确认 1.4.8（云端），日志 `source=remote manifestVersion=4`；
   重启后再次检查版本与来源，解析一个新帖子。复测 IG/X/TikTok 下载。
7. 导出 App 用户日志交回，不提供 cookie、账号信息或私有目录文件。
