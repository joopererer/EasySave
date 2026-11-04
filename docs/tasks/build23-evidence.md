# Build 23 交接与证据

输入：build 22 真机反馈中，所有入口 ParseCache 已命中，第 1/4 种顺序正常；其余顺序出现
ThumbCache 命中但 cache_read/decode 数秒、悬浮球下载较慢及下载期间滚动卡顿。
用户给出的耗时统计作为现场证据；本轮离线测试不替代真机复测。

## 1. 缓存命中读取的排队链路

已确认的源码根因有多层：

- build 22 的每引擎共享通道默认串行；进程共享 ThumbnailFiles 又用同一把 synchronized 锁包住
  read/readPath/write/clean。read 首次同步遍历清理全部目录，每次命中还重新做完整容器检查和采样解码。
- Dart 的 `_read` 读完文件后，再用与显示帧解码共用的两个 decodeSlots 验证图片；
  因此旧 `cache_read ms` 包含等待解码名额及重复校验，不能直接解释为闪存读取耗时。
- NativeLog 的原生日志和 Dart append 通道在调用线程执行文件锁、写入与每行 fsync；
  Dart 通道默认是 Android 主线程。大量缩略图日志会阻塞 UI，并可能反过来放大 channel 等待时间。

改动：

- 共享通道使用非串行 TaskQueue，处理器只做短控制操作或派发任务。
- 进程级 ThumbnailQueues：可见读取独立 **4 线程**，写入/完整校验/首次目录清理独立串行队列，
  预取命中检查独立串行读取队列。读取方法不再持有写入锁，也不调用 clean 或图片解码。
- 正式缓存依然只在完整校验后原子发布。Dart 命中仅异步读字节并检查容器完整性；
  新下载校验使用独立验证槽位，不占显示解码名额。损坏容器与显示解码失败仍删除并重新下载。
- 命中检查放在 single-flight/下载等待之前；其他下载的写入、扫描、网络和校验不会占用可见读取队列。
- 网络 socket 只在 Dart 授权下载流程运行，不占任何原生磁盘线程。
- NativeLog 写盘放入独立单线程队列；append 入队后即响应。clear/export 仍保持串行屏障。
  取消诊断日志每行强制 fsync，关闭文件后数据可供导出读取，避免日志形成强制刷盘风暴。

测试：`ThumbnailQueuesTest.committedReadsStayUnder100msWhileDownloadsPrefetchAndValidationAreBlocked`
阻塞实际写入校验、排队目录扫描、独立预取读取，并同时阻塞下载/预取工作线程；
对生产 ThumbnailFiles/ThumbnailQueues 发起 24 次命中读取，要求每次排队 waitMs < 100。
`thumbnail_read_contention_test.dart` 同时占满 4 个可见下载名额、1 个预取名额和 2 个显示解码名额，
真实磁盘命中读取仍要求在 100ms 内返回。这些是主机隔离/竞争测试，不承诺设备闪存的实际 ioMs。

## 2. 预取优先级与并发名额

根因：旧预取虽然单 worker、分项让出 300ms，但与可见请求共用 `_downloadSlots` 和 decodeSlots，
只观察本引擎 `_pending`，不能感知另一引擎的可见工作。

改动：可见下载每引擎 **4 个名额**；预取每引擎独立 **1 个名额**，不借用前者。
显示帧解码 2 个、新下载验证 2 个、预取验证 1 个，三者分离。
全进程 ThumbnailVisibility 记录两个引擎的可见请求，其他条目预取暂停，空闲后继续；
已经开始的一个预取可以完成，不中断已下载字节。等待中的同 key 预取若被用户请求，提升为可见下载，避免互相等待。
原有 Wi-Fi/Data Saver、每帖最多 30 项与跨引擎 single-flight 约束保留。
引擎 detach 清除该引擎的可见标记，不影响另一引擎，也不会永久暂停预取。

测试：`thumbnail_prefetch_priority_test.dart` 验证跨消费者暂停后恢复，以及同 key 可见订阅者提升等待中的预取且不死锁。
生产 ThumbnailVisibility 的 JVM 测试验证跨引擎引用计数、同 key 优先与引擎 detach。
负载测试还验证一个预取在途时，4 个可见下载可同时进入，其他可见请求等待其自身名额。

## 3. 悬浮球列表的网络等待与解码

根因：build 22 已在后台线程解码，并非所有位图都在主线程解码。
但两个 panel pool 线程同时负责同步等待 Dart channel（最长 20 秒）和位图解码，
因此两个网络请求就能挡住后续磁盘命中与解码；主线程日志 fsync 是另一个已确认的 UI 阻塞点。

改动：真实 SelectPanelView 通过 NativeMediaRequest.imageAsync 请求图片。
命中磁盘直接在独立读取池读字节；缺失时异步请求 Dart，等待网络不占线程。
字节到达后才进入进程级两个位图解码线程，按实际 ImageView 显示像素宽度计算 inSampleSize，
不再一律使用 dp(TARGET_PX)。主线程只处理视图、内存命中和 setImageBitmap，不读文件或解码。
原有 ScrollView、固定标题/输入/下载按钮与 LIVE 标记保留。

证据：修改的是实际 render/loadThumb/imageAsync 调用链，不是单独演示布局；
最终 APK 核查真实 SelectPanelView 对 LRU、异步读取、解码 executor、ScrollView 和 setImageBitmap 的调用。
实际设备连续滚动的流畅度仍待用户复测。

## 4. 悬浮球已解码位图 LRU

根因：旧原生面板每次创建都重新读文件、重新解码，没有跨面板保留的位图缓存。

改动：NativeThumbBitmaps 持有进程级 ThumbnailMemory<Bitmap>，按 allocationByteCount 计费，
预算为 ActivityManager.memoryClass 的 **1/16**，限制在 **2–32 MiB**；支持 LRU 淘汰和最多 10 分钟期限。
键是稳定缓存 SHA-256 加实际显示像素宽度，跨面板注册 token 改变仍可复用。
检查声明的资源期限；解码失败使文件失效时同时删除位图缓存。淘汰不 recycle 仍可能被 ImageView 引用的位图。
真实 render 在创建 shimmer 前查内存，命中直接设置图片、不启动 shimmer、不读文件，也不请求 channel。

测试：生产 ThumbnailMemory 第二次打开同一 20 项/相同尺寸的帖子，20 项全部命中，读取和解码计数均为 0；
另验证字节上限、LRU 最近访问次序、超大位图拒绝和到期。
这是位图缓存机制的 JVM 测试，实际 Android Bitmap/视图接入由 APK 调用证据核实。
超出预算、换尺寸、已过期或首次未显示过的条目可能被淘汰/尚未缓存，不声称无限容量下的全部命中。

## 5. App 与悬浮球下载路径对照

| 路径 | build 22 | build 23 |
| --- | --- | --- |
| App 冷缩略图 | CdnImage → SharedThumbnailCache.load → 每引擎 4 个共享下载槽位 → 写缓存 → Flutter 解码 | 同一 load/授权 HTTP，4 个可见下载槽位，验证与解码分离 |
| 悬浮球冷缩略图 | 两个 panel 线程阻塞等 fetchThumbnail channel → 同一个 Dart load，实际最多约 2 个同时到达；回调后又读/校验文件并解码 | imageAsync 不阻塞等待线程 → fetchThumbnail → 同一 Dart load/授权 HTTP，同样 4 个可见下载槽位；字节就绪才进解码池 |
| 悬浮球磁盘命中 | 经 Dart 读/验证，再回 native readPath 重读/重验，受串行队列和大锁影响 | native 独立读取池直接读，不往返 Dart 下载通道 |
| 悬浮球内存命中 | 无 | 真实 render 直接 LRU → setImageBitmap，无 shimmer |
| 后台预取 | 借用可见下载/解码名额，不能观察另一引擎 | 独立名额、跨引擎可见性暂停、同 key 提升 |

“4 个”是每引擎的可见下载上限，不虚称为两个引擎合计 4 个；跨引擎同 key 仍只允许一个下载。
两边网络入口、鉴权、超时、完整性检查、原子缓存提交和重试规则一致。

## 6. 日志口径

ThumbLoad 保留 ms，新增 waitMs/ioMs/queue：

```text
[ThumbLoad] event=cache_read layer=native queue=read waitMs=1 ioMs=2 ms=3 key=instagram:synthetic:0:thumb
[ThumbLoad] event=network layer=dart queue=download waitMs=0 ioMs=80 ms=80 key=instagram:synthetic:0:thumb
[ThumbLoad] event=validate layer=dart queue=write waitMs=0 ioMs=3 ms=3 key=instagram:synthetic:0:thumb
[ThumbLoad] event=decode queue=read worker=bitmap waitMs=0 ioMs=7 ms=7 key=instagram:synthetic:0:thumb
[ThumbLoad] event=memory_hit queue=read waitMs=0 ioMs=0 ms=0 key=instagram:synthetic:0:thumb
```

queue 为 read/write/download/prefetch；decode 是显示读取路径的独立解码 executor，不是文件 I/O 线程。
waitMs 为本实现排队/桥接等待，ioMs 为操作体执行的实测墙钟时间（异步 codec 自身耗时包含在执行阶段）。
原生读/写 executor 直接计时；Dart 读取通过 native 回传 ioMs 扣除 native 执行时间后计桥接等待，
再单独计异步文件读取。layer/worker 用于区分两端日志，不应把 native 与 Dart 的嵌套读事件相加。
正式缓存写入/验证事件只在对应执行器记录，网络槽位在网络字节完成后释放，不把验证/写入时间算进网络 ioMs。
新日志只使用稳定媒体身份或散列，不包含 cookie 值、账号信息、完整 URL 或 query。

## 7. 测试门禁、版本与 APK

App **1.10.0+23**。没有修改解析器、解析编排或 manifest，因此 parser 保持 **1.4.4**；
不触发“改动解析模块才升至 1.4.5”的条件。
spec fixtures/测试向量、provenance-spec 和 provenance_dart 均未修改。

提交前门禁全部通过：

- Flutter 全量 **706 passed**，退出 0，`app/build/build23-flutter-final.log`；相比 build 22 新增 3 项。
- Android 全量 **94 tests / 0 failures / 0 errors**，22 个 suites，退出 0，
  `app/build/build23-android-delivery.log` 与 `app/build/app/test-results/testDebugUnitTest/TEST-*.xml`。
  生产队列负载测试的 24 次命中读取最大 **waitMs=31**，小于 100ms；
  第二次打开缓存测试 **20 hits / 0 disk reads / 0 decodes**，结果在 ThumbnailQueuesTest 的 XML system-out 中。
- Extension **159 Vitest + 21 构建检查**，含 typecheck；生产构建通过。
  `app/build/build23-extension-test.log`、`app/build/build23-extension-build.log`。
- QR 脚本 **4 passed**，`app/build/build23-qr-test.log`。
- Flutter analyze 使用 `--no-pub --no-fatal-infos --no-fatal-warnings`，退出 0，无 error；
  85 条 warning/info（包含现有 build 诊断文件），`app/build/build23-analyze-final.log`。
- `git diff --check` 通过。

实现提交、APK 与 SHA-256 在构建完成后补充。
APK 核查脚本：`tools/verify_build23_apk.py`，提取的 DEX 保留于 `app/build/build23-apk-dex`，不自动删除目录。

未使用断点/debug 会话；没有卸载、pm clear、run-as、读取设备私有目录或删除相册文件。
未 push/merge/tag；不将任何修复标记为已真机验证。
