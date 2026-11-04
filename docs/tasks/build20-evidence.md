# Build 20 交接与证据

范围：本轮 Live 悬浮预览、C2/C3、D/E 和 XhsLogin 降噪。用户提供的 build 19 复测反馈作为输入保留；下述改动仅记录本机测试，不标记为已真机验证。本轮没有执行设备自动化、私有目录读取、run-as、卸载、清除应用数据、相册删除、push、merge 或 tag；没有操作断点、IDE 运行配置或 debug 会话。

## 1. Live 预览：Media3、会话隔离与封面比例

根因边界：设备日志中的 `media_100_1` 能证明系统 MediaPlayer 服务死亡；HEVC 是待新日志确认的候选原因。旧实现实际会创建新 MediaPlayer，但旧 SurfaceTexture 回调和部分错误回调未按播放器实例隔离，释放后没有清除 listener/矩阵，因此不能把所有残留归因为 Java 对象被直接复用。

改动：

- `SelectPanelView` 使用 Media3 ExoPlayer；`DefaultRenderersFactory.setEnableDecoderFallback(true)` 开启初始化阶段的候选解码器回退。保留已有策略校验下载到私有临时 MP4、随后本地播放的路径；ExoPlayer 只接收 `Uri.fromFile`，不负责远程 HTTP，也不读取 cookie。下载仍由 `NativeMediaRequest` 校验 HTTPS、请求头白名单、资源期限及每一跳重定向。
- `PreviewSessions<ExoPlayer>` 每次创建独立实例。所有格式、尺寸、解码器、首帧和致命错误回调均同时检查预览代次与实例 token。致命 `onPlayerError` 立即使 token 失效、清除 video surface、释放实例；后续操作不能继续使用它。内部可恢复的解码器候选尝试由 Media3 回退处理，不能把启用回退误报为已经发生回退。
- 每次释放时清除 TextureView listener/矩阵并隐藏旧纹理；只有新实例的首帧事件才显示视频。封面清除旧 bitmap，按它自己的像素尺寸调用 `stillLetterbox`，使用 FIT_CENTER 和居中尺寸；不沿用视频尺寸。普通视频出错回退 poster，Live 出错回退静态图。
- `[PreviewPlayer]` 增加 `generation`、`mime`、`width`、`height`、`decoder`、`decoderFallback`、`fallbackEnabled`；通过包装 Media3 的默认 MediaCodecAdapter factory 记录真实的视频 decoder 初始化失败，只有失败后另一个 decoder 成功，或实际 codec 错误后切换 decoder，才标记回退。正常格式匹配选中另一候选、原 decoder 重试成功不误报。致命错误使用 `PlaybackException.errorCodeName`，不记录异常原文。

依赖版本：`video_player_android 2.9.5/android/build.gradle.kts` 已声明 Media3 **1.9.2**。应用直接依赖相同的 `media3-exoplayer:1.9.2`，没有升级 video_player。`build20-native-test.log` 中的 `dependencyInsight --configuration debugRuntimeClasspath --dependency media3-exoplayer` 显示 ExoPlayer/common/HLS 等均解析为 **1.9.2**。参考 [Media3 DefaultRenderersFactory](https://developer.android.com/reference/androidx/media3/exoplayer/DefaultRenderersFactory)；开启 fallback 不代表设备一定存在可用的软件解码器。

测试：`PreviewSessionsTest.kt` 覆盖错误释放后得到不同实例、替换/关闭后忽略旧 token、封面按自身比例 letterbox、倒计时 3/2/1、减少动画时三个点静止，以及真实失败后切换 decoder 才标记回退、正常选择和同 decoder 重试不误报。

新日志字段示例（非设备实测）：

```text
[INFO] [PreviewPlayer] event=decoderInitialized generation=4 host=sns-video-zl.xhscdn.com mime=video/hevc width=1080 height=1440 decoder=c2.android.hevc.decoder decoderFallback=true fallbackEnabled=true errorCode=none
[INFO] [PreviewPlayer] event=error generation=4 host=sns-video-zl.xhscdn.com mime=video/hevc width=1080 height=1440 decoder=c2.android.hevc.decoder decoderFallback=true fallbackEnabled=true errorCode=ERROR_CODE_DECODING_FAILED
```

## 2. C2：解析结果共享

根因：悬浮球 HostService 与前台 Activity 是不同 Flutter 引擎，Dart 静态字段不共享；原先进入 App 会再次调用解析 WebView。

改动：Dart `SharedParseCache` 按 `siteId:canonicalPostId` 缓存，保留短链/原始输入的不透明别名，**45 秒、最多 8 帖**。RAM 中保留 post 与原有 rawImages 诊断快照，不向新磁盘缓存写入帖子数据。后台把内存信封交给 `SharedPreviewBridge` 的进程内存中转，前台直接取回；中转同样有 TTL/容量限制。命中后不调用解析 WebView；资源仍须通过当前站点策略及过期检查，过期则重新解析。消费中转不延长原始期限。

诊断：前台命中时应看到 `[SharedParse] event=hit source=app`，不含链接或账号字段。

测试：`shared_preview_cache_test.dart` 验证 canonical/别名、TTL、容量和实际 `parsePostOutcome` 通过 channel 取回信封而不打开 WebView；`SharedPreviewCacheTest.kt` 验证跨引擎中转的 TTL/容量。

## 3. C3：缩略图共享

根因：App 的 CdnImage 字节内存缓存与原生悬浮面板各自下载、不能跨引擎复用。

改动：Dart `SharedThumbnailCache` 统一通过 `sendAuthorizedMediaGet` 执行站点策略和每跳授权。缓存键为策略与资源声明的 SHA-256，不把 URL/query 或 cookie 值写入文件名。后台先注册不透明资源键，面板只有在用户打开缩略图或预览时才请求 Dart 下载，保持默认不自动加载缩略图的行为。

Android 文件操作经 `SharedPreviewBridge` 串行进入同一个 `ThumbnailFiles`，目录为应用 cache 下的 `easysave_thumbnails`，**64 MiB 总上限、单文件 10 MiB、至多 5 分钟且不超过资源过期时间**。完整临时文件写完后才重命名；过期和容量淘汰均在同一锁下。App CdnImage 与原生面板读取同一缓存；原生只获得键/经目录校验的本地路径，不获取 cookie、账号或受保护网络请求头。需要会话的授权仍只在 Dart 的既有请求策略内执行。

测试：`shared_thumbnail_cache_test.dart` 验证两个 Dart 消费者复用同一文件、只下载一次、携带声明的 Referer、未声明 cookie 不读取/发送 cookie、未经授权主机在联网前被拒绝。`SharedPreviewCacheTest.kt` 验证磁盘容量淘汰、过期、完整内容及目录越界拒绝。

## 4. D / E：真实渲染入口

- TikTok 长按提示由原生 `SelectPanelView.HoldProgressView` 绘制，圆圈中间显示 3、2、1，背后为半透明深色圆角方形。50 ms 时钟更新而非动画时长计算，按满三秒才触发，取消会停止 ticker。真实 onDraw 使用受测 `holdCountdown`。
- 设置入口由 `MinePage` 渲染，新增“清空日志”，确认后调用现有 `DevLog.clear -> easysave/dev_log -> NativeLogFileWriter.clear`，与 append/rotation/export 使用同一锁；取消不调用 clear。没有新增私有目录或设备清理命令。
- 主页输入由 `ParsePage` 渲染，ValueListenableBuilder 跟随真实 controller；输入非空显示“清空链接”图标，清空后图标消失，粘贴按钮保留。
- 平台标记由真实 `PlatformTag -> PlatformIcon -> SvgPicture.asset` 渲染四个本地 Simple Icons logo，未知图标仍使用通用 globe。图标固定取自 **Simple Icons 13.21.0**，原始 SVG 未修改；来源、逐文件 SHA-256 和 CC0-1.0 说明在 `app/assets/brands/PROVENANCE.md`，上游许可证同目录打包。SVG 渲染库 flutter_svg 2.3.2 为 MIT；没有升级 video_player。参考 [Simple Icons 来源与许可证](https://github.com/simple-icons/simple-icons/tree/13.21.0)。
- 解析中的三个跳动点由实际 `BubbleView` 绘制；现代 Android 检查 areAnimatorsEnabled，API 24/25 检查动画缩放设置。系统关闭动画时绘制静止三点，不安排连续刷新。

测试：`build20_widgets_test.dart` 挂载真实 ParsePage、MinePage 和 PlatformTag，覆盖清空图标出现/消失、确认/取消、实际四个 SVG 加载；原有 `site_presentation_test.dart` 保留新站点映射到本地图标及未知回退断言。计数/减少动画的原生辅助函数同时由真实 onDraw 调用及单元测试覆盖。

## 5. XhsLogin 降噪与解析器版本

`logXhsWebViewCookies` 在同一 Dart 引擎生命周期内，按域名比较上一次固定 cookie 名称的 present/absent/unknown 分类；分类未变化不重复记录，不保存或记录 cookie 值。`shared_preview_cache_test.dart` 验证同域重复抑制、状态变化及两个域的独立性。

解析编排增加缓存，因此保守将 parser 版本从 **1.4.1 升为 1.4.2**，运行 `npm run build:parser` 更新内置 manifest 和生成版本。TS 提取算法未改变，没有改动现有 spec fixtures/测试向量，provenance-spec 与 provenance_dart 保持只读。未发布远程 parser，也未变更签名/防回滚规则。

## 6. 门禁与 APK

- Android 最终全量 `:app:testDebugUnitTest`：**83 passed，0 failures/errors**；日志 `app/build/build20-native-final.log`。Media3 dependencyInsight 证据保留在 `app/build/build20-native-test.log`。
- Flutter 全量：**679 passed**；日志 `app/build/build20-flutter-full.log`。相比 build 19 的 671 项，新增缓存/降噪 3、缩略图 2、真实界面 3 项。
- 扩展：159 项 Vitest + 21 项构建检查、typecheck、生产构建均通过；日志 `app/build/build20-extension-test.log` 与 `build20-extension-build.log`。
- Flutter analyze：`--no-pub --no-fatal-infos --no-fatal-warnings` 退出 0，无 error，78 条 warning/info；日志 `app/build/build20-analyze-final.log`。
- 早期失败已修复：缓存 flutter_svg 2.0.10 与 xml 7 冲突，改用兼容的 2.3.2；随之修复第一次未解析依赖导致的编译失败。首次设置 widget 测试点击了视口外控件，增加滚动后的布局等待，重新验证了真实确认弹窗。没有在失败状态下提交。

- 既有扫码脚本回归：`rtk proxy node --test tools/xhs_qr_login.test.cjs`，4 项通过。
- 主实现提交：`e1036e7b9e1e1bacca77ffe06445f0b62b11fc73`；精确 decoder 回退判定提交：`ea863649e20d155d15691ba3ecdbe1ffd60c9963`。最终 APK 从后者构建。
- 构建：`rtk proxy flutter build apk --debug --no-pub --build-name=1.10.0 --build-number=20`，退出 0；日志 `app/build/build20-apk-final.log`。
- APK：`app/build/app/outputs/flutter-apk/app-debug.apk`；交付副本 `app/build/app/outputs/flutter-apk/EasySave-1.10.0-build20-debug.apk`。
- 版本 **1.10.0+20**，包名 **com.james.easysave**，minSdk 24；大小 **201917382 字节**。
- 两个 APK 的 SHA-256：**`a94755af272a30a20ae7e4a4901495c35bd8de43bfa9293ad03a2adee6eb1a3b`**。

APK 复核命令（仓库根目录）：

```powershell
$env:PYTHONIOENCODING = 'utf-8'
rtk proxy python tools/verify_build20_apk.py app/build/app/outputs/flutter-apk/app-debug.apk --dexdump D:/Android/Sdk/build-tools/35.0.1/dexdump.exe
rtk proxy D:/Android/Sdk/build-tools/35.0.1/aapt.exe dump badging app/build/app/outputs/flutter-apk/app-debug.apk
```

上述命令均退出 0。aapt 输出 `package: name='com.james.easysave' versionCode='20' versionName='1.10.0'`。校验脚本第一轮对继承方法的 DEX 所属类名检查过严，已修正为兼容真实匿名子类调用并重新通过；没有修改 APK 内容。完整包内证据保存在 `app/build/build20-apk-evidence.log`。

Flutter **编译后快照**的 UTF-8 搜索结果（不是搜索源码或未引用资源）：

```text
kernel_blob.bin UTF-8 '清空日志': FOUND offset=5450899
kernel_blob.bin UTF-8 '确认清空': FOUND offset=5451304
kernel_blob.bin UTF-8 '清空链接': FOUND offset=5498922
kernel_blob.bin UTF-8 'clear-link-input': FOUND offset=5498857
kernel_blob.bin UTF-8 'easysave/shared_preview': FOUND offset=6005892
kernel_blob.bin UTF-8 'assets/brands/': FOUND offset=6179865
kernel_blob.bin UTF-8 'SharedParse': FOUND offset=5914615
builtin parserVersion=1.4.2; brand license bundled
```

四个 SVG 在 APK 内的 `assets/flutter_assets/assets/brands/` 下均逐字节匹配源文件，分别为 3584、2101、252、707 字节；SHA-256 与同目录 PROVENANCE.md 中的四项一致。许可证也已打包。

**同一 APK 的 classes19.dex 实际指令**摘要（完整类名/签名见原始证据日志）：

```text
HostService     0131fc: SharedPreviewBridge.register(Context, BinaryMessenger, boolean)
MainActivity    016656: SharedPreviewBridge.register$default(...)
SelectPanelView 024bcc: renderers$1.setEnableDecoderFallback(boolean)
SelectPanelView 024bf8: ExoPlayer$Builder.build()
SelectPanelView 024e68: PreviewSessions.accepts(long, Object)
SelectPanelView 02557e: ExoPlayer.clearVideoSurface()
SelectPanelView 025584: ExoPlayer.release()
SelectPanelView 026746: Uri.fromFile(File)
SelectPanelView 02697c: PreviewSessions.close()
renderers$1     02321e: MediaCodecAdapter$Factory.createAdapter(Configuration)
renderers$1     023266: DecoderFallbackTrace.initializationFailed(String)
SharedPreviewBridge 02890a: ThumbnailFiles.write(String, byte[], long)
HoldProgressView 022ac6: Canvas.drawRoundRect(...)
HoldProgressView 022b18: PreviewSessionsKt.holdCountdown(float)
BubbleView$1    00dc5c: PreviewSessionsKt.parsingDotOffsets(long, boolean)
PASS: compiled UI, four exact brand assets, Media3 fallback/session cleanup, cache bridge, countdown and dots
```

脚本同时确认 SelectPanelView 内没有任何调用系统 MediaPlayer 的指令。用于解包的 `app/build/build20-apk-dex-*` 目录在提前说明后，由脚本校验其绝对路径仍在 app/build 内，并仅移除本次创建的目录；未清理其他临时目录。

复测建议：安装 build 20 后，用“我的 → 清空日志”确认清空，然后重启 App 保留 NativeLog 启动标记。依次长按不同 Live、切换封面、取消/重开预览；观察 ExoPlayer 错误码、mime、decoder 和回退标记。悬浮球打开 App 应在 45 秒内出现 SharedParse 命中；打开缩略图后再在 App 查看相同内容应复用缓存。检验倒计时、取消、系统减少动画、清空日志确认/取消、输入清空和四个平台 logo。本轮不声称这些设备行为已验证。
