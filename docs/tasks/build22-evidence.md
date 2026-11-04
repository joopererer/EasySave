# Build 22 交接与证据

范围：build 21 真机反馈中的缩略图卡顿、残图缓存、悬浮球选择列表滚动、后台预取和 LIVE 标记。
本记录区分源码/离线测试/APK 检查与真机复测；没有任何项目标记为“已真机验证”。

## 1. App 预览卡顿

已确认的根因：build 21 的 Dart `File.readAsBytes()` 本身是异步，但 Android
`SharedPreviewBridge.register` 使用默认平台主线程，`ThumbnailFiles.read/write` 的文件检查、
目录枚举、文件写入都在 Android UI 线程执行。Dart 与 Android 两侧各有 UI 线程，
只检查 Dart 是否使用 Sync API 会漏掉这个阻塞点。

同时，旧 CdnImage 绕过 Flutter 注入的 decoder；预览页虽然已经传 400px，其他调用点不一定传尺寸，
也没有限制帧解码并发。不能把“所有预览都按原图解码”作为已证实的结论。

改动：

- 两个引擎的共享通道均使用 `makeBackgroundTaskQueue`，缓存目录扫描、校验和读写离开 Android 主线程。
- Dart 读缓存继续使用异步 `readAsBytes`。CoverImage 从实际 LayoutBuilder 显示宽度乘 DPR 计算像素宽度；
  CdnImage 使用 Flutter 注入的 decoder 与 `getTargetSize`，不放大原图。
- 原图浏览明确使用 `fullResolution: true`；普通封面默认使用显示尺寸。
- 真实 PreviewPage 保持 GridView.builder，cacheExtent 为 100 逻辑像素。像素解码槽位每引擎最多 2 个，
  包含首帧与后续动画帧；不是仅限制轻量的 codec 创建。
- ThumbLoad 日志提供 cache_read/network/decode 的毫秒耗时与稳定 platform:post:index:variant 键，
  非法标签散列；不添加 URL、query、cookie 或账号值。

测试：`thumbnail_first_frame_test.dart` 挂载真实 PreviewPage 的 20 张图，阻塞全部图片读取，
检查首帧网格已经绘制、只创建部分图片 widget、图片尚未完成时仍能滚动；另挂载真实 CoverImage，
验证 100 逻辑像素 × DPR 3 = 300 像素，以及仅显式原图请求使用无限制解码尺寸。

## 2. 残图缓存与重试

根因：旧下载入口只检查 HTTP 200、非空和大小上限，没有检查 Content-Length 或图片解码；
原生虽有临时文件 rename，但没有验证临时文件。Dart `_pending` 仅在单引擎内合并请求，不能互斥两个引擎。
缓存读取也没有图片验证与损坏淘汰。

改动：

- 下载先完整收集受限字节流，检查 Content-Length（存在时）、JPEG/PNG/WebP 容器完整性、图片尺寸和实际采样帧解码。
  部分 JPEG 解码器容忍残图，因此不能仅以 codec 创建成功判断完整。
- 原生在同一个 `easysave_thumbnails` 目录写 `.tmp`，通过尺寸/采样解码验证后 rename；finally 删除未提交的临时文件。
  不再提前删除同 key 的有效正式文件，失败替换保留旧文件。
- 进程内 ThumbnailFlights 仲裁两个引擎，同 key 仅一个下载者；等待者读取已提交文件，失败后重新竞争所有权。
  悬浮球注册句柄和 App CdnImage 都调用 SharedThumbnailCache.load。
- 缓存校验失败删除该 key 并重新下载；显示尺寸的首帧解码失败也会删除缓存并重新下载一次。
- 下载失败最多重试 2 次，间隔 250/500ms；失败 Future 从 pending 移除。
  App 和悬浮球最终都显示“加载失败，点击重试”，点击发起新请求。
- 首次缓存读取在后台清理本 App 专用缩略图目录内过期、残缺、不能解码的文件及遗留临时文件；不扫描相册或其他目录。
  64 MiB 总上限、10 MiB 单文件上限和 10 分钟 TTL 保留。

测试：`thumbnail_integrity_test.dart` 覆盖截断下载不提交、无 Content-Length 的残图拒绝、
两个独立缓存消费者只下载一次、损坏缓存删除重下、失败后可重试、显示尺寸解码失败后删除重下。
`SharedPreviewCacheTest.kt` 验证正式进程仲裁器的单所有者语义、无效写入没有正式/临时文件、
失败替换保留旧文件、首次清理局限于缓存目录，以及容器截断检查。

## 3. 悬浮球选择列表滚动

根因：真实 SelectPanelView 将 GridLayout 直接放在高度受限的 LinearLayout 中，没有滚动容器。
外层 addView 还以 WRAP_CONTENT 覆盖 buildSheet 的预设高度。

改动：中部 GridLayout 放入 ScrollView，占剩余高度；外层面板明确使用屏幕高度的 72%。
标题、编号输入和底部下载按钮仍位于滚动容器外。保留全部编号和选择逻辑，滑动触发触摸取消时撤销长按。
缩略图只在实际可见时开始加载，线程池最多 2 个任务；完成或移除的控件撤销滚动监听。

历史核查：`git show v1.9.0:app/android/app/src/main/kotlin/com/james/easysave/SelectPanelView.kt`
中同样是 `grid = GridLayout` 后直接 `sheet.addView(grid, ... weight=1f)`，没有 ScrollView。
因此 **v1.9.0 已存在这个布局缺陷**。这是历史源码结论，不是对旧 APK 的真机复现声明。

## 4. 后台缩略图预取

根因：原先仅显示缩略图的消费者按需取图，解析成功没有低优先级预取队列。

改动：所有正常 parsePostOutcome 成功返回（包括共享解析命中）后，不等待预取即返回结果。
每引擎单预取 worker（正常两个引擎合计最多 2），每帖子最多 30 项；逐项让出 300ms，
先等当前可见请求完成再发下一项，前台仍保留下载槽位。预取复用同一授权、single-flight 和缓存入口。
每项开始前检查 Android 实际网络：Wi-Fi 或系统未开启 Data Saver 才允许；补充 ACCESS_NETWORK_STATE 权限。
被省流模式阻止时允许后续解析重新尝试，不永久记住失败。

测试验证 35 项仅预取 30 项、单 worker 最大并发 1、省流模式阻止请求、之后允许重新预取，以及可见请求优先。

## 5. 悬浮球 LIVE 标记

根因：Cell 已携带 live 字段，原生 render 只绘制视频播放标识和编号，没有使用该字段绘制 LIVE。

改动：真实 SelectPanelView 的 Live 缩略图左下角添加 LIVE，采用 App 预览 badge 的白色 11sp 字体、
黑色 54% 背景、6dp 圆角、水平 6dp/垂直 2dp 内边距；不与右下角编号重叠。
APK 检查会核实真实 SelectPanelView 的 LIVE 常量、ScrollView 构建与可见性调用进入最终 DEX。

## 测试门禁与交付

版本：App **1.10.0+22**；解析编排增加成功后的预取，按要求 parser 升至 **1.4.4**。
未修改提取算法；spec fixtures/测试向量未修改，provenance-spec/provenance_dart 未修改。

提交前门禁全部通过：

- Flutter 全量 **703 passed**，退出 0，`app/build/build22-flutter-verified.log`；相比 build 21 新增 11 项。
- Android 全量 **90 tests / 0 failures / 0 errors**，21 个 JUnit suites，退出 0；
  `app/build/build22-android-delivery.log` 与 `app/build/app/test-results/testDebugUnitTest/TEST-*.xml`。
- Extension **159 Vitest + 21 构建检查**，含 typecheck；生产构建通过。
  `app/build/build22-extension-test.log`、`app/build/build22-extension-build.log`。
- QR 脚本 **4 passed**：`node --test tools/xhs_qr_login.test.cjs`。
- Flutter analyze 使用 `--no-pub --no-fatal-infos --no-fatal-warnings`，退出 0，无 error；
  84 条 warning/info（包含现有 build 目录诊断文件），`app/build/build22-analyze-final.log`。
- `git diff --check` 通过。早期新增测试的 mock 参数错误和本机 JAVA_HOME/Gradle 参数问题均已修正后重跑；
  没有在失败门禁状态提交。

实现提交：`76bd3459df24916d1fc143b58566c2ef00afa37f`。上述门禁通过后先提交，再运行
`flutter build apk --debug --no-pub --build-name=1.10.0 --build-number=22`，assembleDebug 51.1 秒，退出 0。

- APK：`app/build/app/outputs/flutter-apk/EasySave-1.10.0-build22-debug.apk`（173,555,585 bytes）。
- SHA-256：`0428ba2e0725448476841d189604b1e0409b5e1102cb0b9df502eced72107295`。
- aapt：`com.james.easysave`，versionName **1.10.0**，versionCode **22**；
  ACCESS_NETWORK_STATE 权限存在。内置 parserVersion **1.4.4**，parser.js SHA-256 与 manifest 一致。
- 构建日志：`app/build/build22-apk-build.log`；包信息：`app/build/build22-apk-badging.log`。
- 最终命名 APK 与构建原始 `app-debug.apk` 的 SHA-256 完全一致。

APK 检查脚本为 `tools/verify_build22_apk.py`，
保留提取的 DEX 在 `app/build/build22-apk-dex`，不自动清理目录。
界面证据由真实 widget 测试与最终 APK 的 kernel/DEX 调用共同构成，不等同于设备上的流畅度或完整交互验证。

最终命名 APK 的核查日志：`app/build/build22-delivery-apk-evidence.log`，退出 0：

- kernel 包含真实 PreviewPage/CoverImage/CdnImage，及 `_LimitedCodec`、ThumbnailSlots、
  fullResolution、getTargetSize、ThumbLoad、失败点击重试文案和各共享缓存消息。
- `classes19.dex`：真实 SelectPanelView 在 `0257b6` 构造 ScrollView、`0257f0` 添加网格；
  `027a22` 调用 getGlobalVisibleRect，`028074` 包含 LIVE 标记。
- 同一 DEX：`02a0ca` 调用 makeBackgroundTaskQueue；`029d6e/029e7a/029dc0` 分别调用缓存读、写、删除；
  `0299f4` 调用容器完整性检查，`029a1c/029a6c` 调用采样校验的 BitmapFactory.decodeFile。
- HostService `0139d4` 与 MainActivity `016e2e` 均调用 SharedPreviewBridge.register，两个引擎都注册同一入口。
- 核查最终输出 `PASS: compiled real preview widgets, native scroll/LIVE, background I/O and shared cache entry points`。

复核命令（仓库根目录）：

```powershell
rtk proxy python tools/verify_build22_apk.py app/build/app/outputs/flutter-apk/EasySave-1.10.0-build22-debug.apk --dexdump D:/Android/Sdk/build-tools/35.0.1/dexdump.exe
rtk proxy D:/Android/Sdk/build-tools/35.0.1/aapt.exe dump badging app/build/app/outputs/flutter-apk/EasySave-1.10.0-build22-debug.apk
```

待用户真机复测：四种顺序的解析/缩略图复用、18/20 图首屏与连续滚动、损坏项点击重试、
第 16–18 项可见可选及固定按钮、Live 原图、Wi-Fi/Data Saver 条件变化。
性能日志只提供离线通过后的诊断基础，不作设备耗时结论。

没有请求断点/debug 会话；没有卸载、pm clear、run-as、读取设备私有目录或删除相册文件；没有 push/merge/tag。
