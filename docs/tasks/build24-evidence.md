# Build 24 交接与证据

输入：用户 build 23 真机复测确认重复打开与 App 第 2/3 种入口顺序已秒显示，cache_read 两端平均排队 0–4ms；下载期间悬浮球滚动卡顿、XHS 第 8/9 张方向异常仍待修复。本轮主机测试不能替代真机复测。

## 1. 下载期间卡顿：根因与缓存协议

源码确认 Dart `SharedThumbnailCache._load` 把整个图片 `Uint8List` 通过 `thumbnailWrite` 交给原生；Dart 校验调用 `instantiateCodec/getNextFrame`，原生写入又调用 BitmapFactory 做一次像素解码。原图级候选和重复解码会放大 CPU、内存复制及写队列耗时。

需要纠正的归因：build 23 的 `shared_preview` 已使用非串行后台 TaskQueue，写盘也有独立 executor，因此不能把该通道的接收处理认定为 Android 主线程。此前统计能证明排队/执行耗时，不能单独证明主线程拷贝。此次仍彻底移除跨 channel 图片字节，消除这项开销。

最终协议：

1. Dart 从 `thumbnailDirectory` 取得共享目录；返回排在启动清理之后，避免首次清理碰到刚发布的文件。
2. 授权 HTTP 下载仍保留状态码、超时、10MiB 上限和 Content-Length 字节数检查。
3. 后台 isolate 只解析 JPEG SOF、PNG IHDR、WebP VP8/VP8L/VP8X 尺寸及容器边界；检查 JPEG EOI、PNG IEND/固定 CRC、WebP RIFF 声明长度及 chunk 边界。WebP 没有 JPEG 式固定尾标记，检查的是其长度/结构。
4. Dart 写入同目录唯一 `.tmp` 文件、flush、轻量校验、设置 TTL，原子 rename 为 SHA-256 key。写入函数通过 isolate controlPort 比较拒绝在调用方 isolate 执行。失败时仅删除该函数自己创建的临时文件。
5. `thumbnailReady` **只传 key、path**。原生后台确认路径限定在缓存根目录，维护 TTL/64MiB 配额；原生消费者在读线程直接读文件。旧 `thumbnailWrite` channel 方法已删除。跨引擎 single-flight、独立读队列及显示解码池保留。
6. 命中检查也在后台 isolate 解析头，不重新解码像素。只有实际显示才做像素解码。

`cache_write` 现在是 Dart 实际字节写入事件：`waitMs` 是 isolate 调度/传递等候时间，`ioMs` 是 worker 内写文件、flush、校验、rename 的墙钟耗时，附 `bytes`、`thread=bg`。原生 TTL/清理等操作记为 `cache_control queue=write`，保留实测 waitMs/ioMs，避免把不再发生的原生字节写盘记为 cache_write。

示例（字段示意，非真机性能数据）：

```text
event=cache_write layer=dart queue=write waitMs=1 ioMs=3 bytes=2048 thread=bg key=xhs:synthetic:0:thumb
event=cache_control layer=native queue=write waitMs=0 ioMs=1 thread=bg key=opaque-sha256
```

测试：缓存协议相关 mocks 拒绝任何带 `bytes` 的调用，并检查 ready 前文件已存在；原有跨引擎单下载、失败重试、读队列竞争、前台优先和真实 widget 消费测试继续运行。新增 writer 测试验证调用方 isolate 被拒绝、worker 发布字节不变且没有残留 `.tmp`。新增三种真实合成图，对每个不完整前缀要求 FormatException。原生文件读取和解码入口带主线程拒绝检查，Robolectric 验证该检查在读取 EXIF/像素前生效。此证据证明线程约束，不宣称设备帧率已验证。

## 2. Channel 线程审计

以下为应用自有通道；第三方 Flutter 插件的内部方法不作为本轮审计结论。

仍在 Android 主线程接收的完整方法列表：

| 通道 | 方法 | 主线程工作 |
| --- | --- | --- |
| `easysave/seal` | `isInstalled`, `send` | 包状态查询、发送小型 Intent |
| `easysave/host` | `getPendingError`, `clearPendingError`, `getPendingOpen`, `clearPendingOpen` | 读取/清空内存状态 |
| `easysave/tile` | `addTile` | 调系统添加快捷磁贴 UI |
| `easysave/bubble` | `hasPermission`, `requestPermission`, `start`, `stop`, `isRunning`, `updateAutoHide`, `openAppSettings` | 权限/服务状态、UI/设置 Intent |
| `easysave/bgtask` | `ready`, `log`, `notify`, `error`, `historyChanged`, `openApp`, `toast`, `tile`, `bubble`, `clipboard`, `showSelectPanel`, `unmountSelectPanel`, `keepAlive`, `idle`, `stop` | 生命周期、内存状态、通知与真实视图调度；日志只入后台队列。面板参数是资源声明与状态，无图片字节 |

这些接收处理均是 UI、短控制消息或后台派发，不执行图片文件 I/O、像素解码或大块字节传输。创建/更新视图仍必须在主线程，不将其称为零耗时。

后台 TaskQueue：

- `shared_preview`：所有 parse handoff、缓存控制方法；出站 `fetchThumbnail` 主线程发送的仅是 opaque key，Dart 返回的仅是 path，文件读取由读 executor 执行。
- `media`：`readMediaHeader`, `queryMediaAlbum`, `scanFile`, `deleteMedia`, `requestWriteAccess`。媒体头可能是大字节响应，因此接收与结果编码都在后台；删除/写入授权只把 OS UI 步骤派发到主线程，sidecar 查询和 MediaStore 请求构建在工作线程。
- `saf`：`pickDirectory`, `pickBackupFile`, `checkDirectoryAccess`, `writeBackupToDirectory`, `readDocumentContent`, `listBackupDirectory`, `deleteDocuments`, `getDirectoryDisplayName`。保留已有备份文本传输兼容性，文本可能很大，必须后台编码/处理。两个系统选择器单独派发到主线程。
- `provenance_pair`：`savePair`, `saveMedia`, `inspectTarget`, `repairLegacyNames`, `readSidecar`, `readSidecarDetailed`, `queryFixedMedia`, `deletePair`, `setFixedTree`, `readFixedHeader`。header/sidecar/查询结果可能较大；结果直接从 worker 返回，不再投递主线程编码。
- `dev_log`：`append`, `clear`, `export`；接收后台，磁盘操作保持独立日志 executor。
- `download_control`：`reserve`, `release`, `cancelPost`, `isCancelled`；内存控制操作也移至后台，避免批次 key 列表在主线程解码。

## 3. 各平台缩略图结论

| 平台 | 原行为 | build 24 |
| --- | --- | --- |
| XHS | 原图/JPEG 转码及场景 fallback，未按 imageScene 明确选缩略图 | `config/sites.json` 声明 `download.thumbnailScenes=[WB_PRV,H5_PRV]`，只选 infoList 中已有对应地址，原样使用；缺失则保留原候选顺序 |
| Instagram | `image_versions2.candidates` 选最大面积图片；DOM 路径取页面现成地址 | 配置 `thumbnailVariant=smallestCandidate`；有带有效尺寸的 candidates 时选最小面积现成地址；无候选的 DOM/display_url 路径保持现状 |
| X | syndication 提供媒体地址，现有原图归一化 | 未发现该输入中逐图的小尺寸变体列表；保持原行为，不新增 CDN 参数 |
| TikTok | imagePost 图片地址列表是同资源候选；视频已有 cover，图集 cover 仅对应封面 | 没有确认到每张图片对应的小尺寸列表；保持现状，不拿首张 cover 替代整组图片 |

新字段 `thumbnailUrl` 持久化到历史 JSON，受同一 MediaRequestPolicy 校验并生成 poster 资源声明。App 真正渲染的 `CoverImage`/`CdnImage`、后台预取和原生面板均接入。存在小尺寸变体时，大图使用独立 `image` 缓存身份，避免误命中 `thumb`；原始下载 `url`/保存资源不变。无变体时继续复用既有身份。解析模块已修改，parser 升至 **1.4.5**，并重建内置脚本与 manifest/hash。

新增 TS 测试验证 XHS 场景配置、缺失回退、Instagram 最小候选及原图下载地址；旧 spec fixtures/测试向量均未修改。新增真实 widget 测试 pump `CoverImage`，确认缩略图与 fullResolution 大图实际产生不同 ImageProvider 身份并读取各自缓存。

## 4. EXIF 方向、尺寸与保存

源码根因：面板缩略图和大图都走 `decodeSampled`，原来只调用 BitmapFactory，未读取 EXIF。新 `OrientedBitmap` 使用 `androidx.exifinterface:exifinterface:1.4.1`，完整处理方向 1–8 的恒等、镜像、180°、垂直翻转、转置、90°、横向转置、270°。

缩略图/大图统一在解码 worker 读取方向，以旋转后宽高计算采样，再通过 Matrix 旋转/翻转。letterbox 使用返回 Bitmap 的最终宽高；网格仍是固定方格，按实际 Bitmap 填充，不采用未旋转的存储尺寸。原始字节和文件不被显示变换修改。

Robolectric native graphics 测试生成 8 个真实 JPEG 文件，分别写入方向 1–8：每个方向检查四角颜色、完整尺寸、采样后尺寸和缩略图/大图比例。通过真实 `PublicMediaWriter.save` 向主机模拟 MediaStore 保存每个文件，验证保存字节完全一致且 EXIF Orientation 不变。生产 writer 本来也只做文件流复制并校验 SHA-256，不重编码、不应用显示 Matrix，因此不会丢 EXIF 或重复旋转。元数据业务继续使用现有 provenance 流程，本轮没有修改 provenance_dart 或 provenance-spec。

新增诊断只记录安全 key、EXIF 方向、存储尺寸、显示尺寸、sample、thread；不记录图片 URL、query、cookie、账号。

```text
event=orientation orientation=6 storedWidth=160 storedHeight=80 shownWidth=20 shownHeight=40 sample=4 thread=bg key=xhs:synthetic:0:image
```

给定短链未能通过网页工具取得原图，所以用户反馈的第 8/9 张的具体 EXIF 值和实际设备显示仍待复测。此次确认的是缺失 EXIF 处理的生产代码路径及 8 方向可复现测试，不标记为已真机验证。

ExifInterface 依赖版本和能力参考 [Android 官方发布记录](https://developer.android.com/jetpack/androidx/releases/exifinterface#1.4.1)。

## 5. 门禁与交付

提交前门禁全部通过：

| 门禁 | 结果 | 日志 |
| --- | --- | --- |
| Flutter 全量 | **711 passed**，退出 0；比 build 23 新增 5 项 | `app/build/build24-flutter-gate.log` |
| Android 全量 | **96 tests / 0 failures / 0 errors**，23 suites，退出 0 | `app/build/build24-android-gate.log`；`app/build/app/test-results/testDebugUnitTest/TEST-*.xml` |
| Extension 全量 | **161 Vitest + 21 构建检查**，typecheck 通过，退出 0 | `app/build/build24-extension-gate.log` |
| Extension 生产构建 | 退出 0 | `app/build/build24-extension-build-gate.log` |
| parser/builtin 生成 | parser **1.4.5**，脚本 SHA-256 与 manifest 一致 | `app/build/build24-parser-gate.log` |
| QR | **4 passed**，退出 0 | `app/build/build24-qr.log` |
| Flutter analyze | 退出 0，无 error；91 条 warning/info，含已有 build 诊断文件 | `app/build/build24-analyze-gate.log` |
| 差异检查 | `git diff --check` 通过 | 提交前终端检查 |

APK 信息在提交后构建并追加。测试使用 D 盘 `app/build/build24-temp`；C 盘 ENOSPC 曾造成 Flutter 编译和 Vitest 临时文件失败，均改用 D 盘重跑，不把失败轮次计为通过。新增主机保存测试首次因测试文件名不符合既有导出命名规则失败，已修正测试输入，生产导出规则不变。

无断点/IDE debug 会话，无卸载/pm clear/run-as/读取设备私有目录/删除相册文件。仅中断了本轮自己启动、等待或受磁盘空间影响的命令。未删除临时目录；主机测试图、构建日志、APK/DEX 证据保留于 build 路径。未 push/merge/tag。
