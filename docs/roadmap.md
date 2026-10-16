# EasySave Roadmap

> 版本完成后勾选对应项：把 `- [ ]` 改为 `- [x]`。
> 每次只实现指令中指定的版本功能，不要提前实现后续版本。

## v1.1a 界面与本地能力

- [x] `ui-spec` 中的全部 UI 调整（见 `docs/design/ui-spec.md`）
  - 验收：首页/预览页/下载面板/历史页/"我的"页与 ui-spec §2 一致；无"原型版本"文字；深色模式下所有文字与背景对比度符合 Material 3 深色规范（无浅色残留）
- [x] 下载历史：本地数据库记录平台、作者、标题、缩略图、原帖链接、时间、文件数
  - 验收：断网可打开历史页；每条记录字段齐全；点击卡片可打开预览页
- [x] 设置页：相册名称（默认使用 App 名称）、文件名格式、同时保存文案为 txt、自动检测剪贴板开关、清除缓存、版本号
  - 验收：每项设置重启后保持；相册名称修改后新下载落到新相册；关闭自动检测后打开 App 不弹确认卡片
- [x] 复制文案：预览页可折叠文案区 + "复制文案"按钮（复制标题 + 正文）
  - 验收：复制文本为"标题换行正文"；无标题或无正文时不产生多余空行
- [x] 诊断信息：解析失败时可以复制平台、错误码、链接、App 版本；不能包含 cookie 或任何账号信息
  - 验收：复制文本含且仅含四项；全局搜索代码确认无 cookie 写入剪贴板/日志

## v1.1b 后台与重试

- [x] 后台下载 + 失败重试，用 `background_downloader` 包（通知栏按批次合并进度，切到后台时不中断；单个文件失败时 Manager 层换备用地址共试 3 次；仍失败的标红并可以单独重试；单个文件失败不导致整批报错）
  - 验收：下载中按 Home 键，通知栏进度持续更新；返回 App 进度无丢失；拔网 1 张后恢复，该张自动重试成功；3 次全失败时仅该行标红，其余文件正常落盘
  - 方案评估（实施前写进 PR 描述）：`background_downloader` 与现有 `gal` 直存链路的衔接方式（下载到沙盒再 `Gal.putImage/putVideo` 落盘，还是直接下载到相册目录）；通知栏 channel 与 App 名称；iOS 后台模式是否需要额外配置

## v1.1c 视频与 Live 预览

- [x] 视频和 Live 图全屏预览（`video_player` + 平台 Referer；真机未发现编解码问题，未引入 `media_kit`）
  - 先用 `video_player` 实现，通过 `VideoPlayerController.networkUrl` 的 `httpHeaders` 传入对应平台的 Referer；只有在真机上测出 `video_player` 无法满足的问题（例如编码不支持）时，才评估 `media_kit`，并说明原因和 APK 体积影响
  - 视频：全屏播放，带控制条；切到后台时暂停，离开页面时释放播放器
  - Live 图：默认显示静态图，长按播放 motion（静音、循环），松手停止
  - 验收：小红书视频、IG Reel、小红书 Live 图都能在预览页播放；连续切换 10 个视频后内存没有明显增长

## v1.2 分享与批量

- [x] 分享：把下载结果通过 Android 分享发给其他 App，附带原帖链接、作者、文案，用于和 UniPost 衔接
  - 验收：下载面板的 [分享] 可用；目标 App 收到图片和文本，链接、作者、文案齐全
- [x] 批量解析：一次粘贴多个链接，逐个解析并生成下载任务
  - 验收：粘贴包含 3 个帖子链接的文本，一次生成 3 个下载任务
- [x] YouTube 交给 Seal：识别到 YouTube 链接（youtube.com/watch、youtu.be、/shorts/）时不解析，提示"YouTube 视频由 Seal 下载"，通过 Android 分享 intent 把链接发给 Seal（包名 com.junkfood.seal）；没安装 Seal 时显示下载指引（F-Droid / GitHub Releases）
  - 验收：已装 Seal 时一键跳转并自动填好链接；没装时显示指引，不报错

## v1.3a 解析器统一

- [x] 把 extension/src 的 TS 解析器打包成一个可注入 WebView 的独立 JS（输入：页面数据；输出：spec 中的统一模型 JSON 或错误模型）
- [x] App 在页面加载完成后注入这个 JS 执行，用它的结果替换 Dart 解析器；保留 Dart 的统一模型和错误模型定义，删除 Dart 的平台解析器；fixture 测试只在 TS 端运行
  - 验收：小红书和 IG 的全部真机测试流程与 v1.1 结果一致；以后新增平台只需要写 TS 一份

## v1.3b 解析器云端热更新

- [x] 发布物：manifest.json（parserVersion、minAppVersion、sha256、Ed25519 签名、各平台启用开关和维护提示、各平台请求头/UA）+ parser.js
- [x] App：启动时检查更新，最多每 6 小时一次；下载后校验签名和哈希，缓存为"最近一个可用版本"；任何一步失败都回退到 App 内置版本；parserVersion 显示在"我的"页和诊断信息中
- [x] 安全：公钥内置在 App 中，签名验证失败时拒绝加载；严禁执行未签名的代码
- [x] 远程开关：平台被关闭时，解析该平台的链接显示维护提示，不发起请求
- [x] 发布流程：GitHub Actions 在推送 parser-v* tag 时运行全部 fixture 测试，通过后打包、签名，发布到 GitHub Releases；私钥只存放在 GitHub Secrets 中
- [x] 插件：遵守 Chrome MV3 规定，不加载远程代码，只拉取 manifest 中的平台开关和请求头配置
  - 验收：故意把一个解析规则改错，发布修复版 parser-v*，手机 App 不重装即可恢复正常；把签名改坏，App 拒绝加载并回退到内置版本

## v1.4 X (Twitter)

- [x] 只使用公开嵌入接口 cdn.syndication.twimg.com/tweet-result；需要登录的推文（敏感内容、锁定账号）返回 LOGIN_REQUIRED，不做 WebView 兜底
- [x] 请求方式参考 Vercel 的 react-tweet（MIT）中 token 的计算方法，以及 yt-dlp 的 Twitter 提取器
- [x] 图片取原图（name=orig），视频取码率最高的 mp4，GIF 作为无声 mp4 视频提取，引用推文只下载被分享推文自身的媒体
- [x] 接口 URL 模板、token 算法参数和请求头纳入 manifest.json 云端热更新配置
- [x] 先采集 fixture（单图、多图、视频、GIF、引用推文、已删除），再写 spec，再实现；按 v1.3 架构只写 TS 一份，支持热更新
  - 验收：全部 X fixture 测试通过；真机上从 X App 分享链接能下载


## v1.5 TikTok

- [ ] 从页面的 \_\_UNIVERSAL_DATA_FOR_REHYDRATION\_\_ 取数据；视频用 playAddr（无水印），不用 downloadAddr（有水印）；同时支持图文帖子
- [ ] 下载时带上 WebView 的 cookie 和 Referer
- [ ] 参考 yt-dlp 的 TikTok 提取器
- [ ] 先采集 fixture（视频、图文），再写 spec，再实现；按 v1.3 架构只写 TS 一份，支持热更新
  - 验收：两种 fixture 测试通过；真机下载的视频没有水印

## v2

- [ ] Live 图保存为动态照片（Motion Photo）
  - 验收：相册中可播放动效；小米/OPPO/三星至少一台真机验证
- [ ] 平台改版维护脚本
  - 验收：`spec/fixtures` 新增改版后 HTML fixture 并通过；CHANGELOG 记录适配
- [ ] 插件功能与 App 对齐
  - 验收：同一 fixture，插件与 App 解析结果一致
- [ ] iOS 版本
  - 验收：TestFlight 可安装；保存到相册权限流程正常

## 明确不支持

- **微信视频号**：视频加密，只能在 PC 端通过代理实现，不符合本项目架构，**不要尝试实现**。
- **YouTube**：EasySave 不内置下载，统一交给 Seal 处理（见 v1.2）。原因：需要 JS 运行时和 PO Token，Seal 在 Android 上 2026 年仍频繁出现 403 和机器人验证；内置 yt-dlp 会让 APK 增加数十 MB；违反 YouTube 条款和应用商店政策。**不要尝试内置 yt-dlp 或 youtubedl-android**。
