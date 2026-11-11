# Build 21 交接与证据

范围：修复 build 20 共享缓存的入口不对称、缩略图身份不稳定，以及历史平台别名重复。用户提供的 build 20 反馈作为输入保留；本轮只记录离线测试和 APK 检查，不标记任何项目为已真机验证。

## 1. 所有入口共用解析缓存

根因：build 20 的 `parsePostOutcome` 明确只在 `source != background` 时读取原生中转，只在 `source == background` 时向它写入。前台结果留在独立 Dart 引擎的本地静态缓存中；45 秒 TTL 也容易在手动切换路径时过期。即使命中，界面也会先显示解析 loading。RAM 快照还使用了旧 `toJson`，其按设计排除了请求声明，不能用于长期缓存时的过期检查。

改动：

- `CachedPostParser` 是统一入口：App 输入、分享、批量、悬浮球选择下载、悬浮球打开 App 和普通历史/自动解析都先读原生 `ParsedHandoff.lookup`，成功后均写 `putParsed`，不再按 source 限制方向。原生进程内存是两个引擎共同的权威缓存；没有新增帖子磁盘缓存。
- 主键为 `SiteRegistry.canonicalId(platform):postId`；保留不透明的输入别名，重新写入相同帖子时更新结果并合并已知别名。TTL **10 分钟**、容量 **8 帖**；命中不延长期限。未见过的 HTTP 短链可先展开以获得 canonical ID，再查缓存，不必重新运行解析器。保留 TikTok 等 WebView 短链的原有加载策略。
- RAM 信封单独保留 `requestResources`、fallbacks、rawImages；不改变 parser fixture/backup JSON。复用前检查当前站点策略、显式 `expiresAt` 及常见 URL 期限字段（expires/expire/expiration/x-expires、IG oe），失效即重新解析。
- 主动历史“重新解析”、首页重试和下载资源刷新传 `forceRefresh=true`；它们跳过读取并在成功后更新共享结果。普通再次输入相同链接仍可命中。
- App 与悬浮球的解析 loading 仅在 `onCacheMiss` 时显示；已有独立防重入标记，不用可见 loading 代替请求互斥。

诊断（仅入口和帖子 ID，不包含 URL/query/cookie/账号）：

```text
[INFO] [ParseCache] event=miss entry=input post=abc123
[INFO] [ParseCache] event=store entry=input post=abc123
[INFO] [ParseCache] event=hit entry=bubble_select post=abc123
[INFO] [ParseCache] event=expired entry=share post=abc123
```

## 2. 缩略图按稳定媒体身份共享

根因：build 20 的目录缓存键包含完整资源 URL、请求声明及期限。每次解析生成新的签名或过期参数时，同一媒体会变成另一键；全屏 `GalleryBrowserItem.toMediaItem` 也会丢失原帖/序号。

改动：

- 逻辑键为 **canonical platform:postId:itemIndex:variant**，如 `xhs:abc123:0:thumb`、`instagram:AbCd:1:poster`。目录只保存其 SHA-256；URL 仅供策略检查和实际下载，不参与缓存键。Native 请求句柄是单独的不透明注册 token，避免多个 fallback 覆盖同一登记项。
- `ParsedPost` 为 MediaItem 绑定运行时 postId/index；这些字段不写 parser/backup JSON。全屏浏览器、历史稀疏 itemIndex、最近记录和下载队列均保留/恢复此身份。CdnImage 的解码缓存也使用同一身份；移除旧 URL 字节缓存。
- App `CoverImage/CdnImage` 和原生面板按需读取同一 `SharedThumbnailCache`，实际下载仍经 Dart 请求策略和逐跳授权。原生只拿键/本地缓存路径，不读取 cookie。文件缓存仍有 **64 MiB 总上限、10 MiB 单文件上限**，文件 TTL 与共享窗口对齐为 **10 分钟**。
- 已下载的位图字节不会因旧下载 URL 的签名期限而重新命名或提前淘汰；复用前仍验证当前资源。新的有效 URL 可以复用相同媒体的已存字节。资源实际过期则解析层先获取新声明。

日志示例：

```text
[INFO] [ThumbCache] event=miss key=xhs:abc123:0:thumb
[INFO] [ThumbCache] event=store key=xhs:abc123:0:thumb
[INFO] [ThumbCache] event=hit key=xhs:abc123:0:thumb
```

不合法的诊断标签被哈希，不会把 URL/query 改写成仍可辨认的日志文本。

测试 `shared_cache_orders_test.dart`：四个顺序分别创建独立的 Dart 消费者、共用模拟原生进程缓存；App 侧运行实际 CdnImage 解码，悬浮球侧调用实际 inbound `fetchThumbnail` handler。每个顺序第二次打开均要求 **解析总调用数仍为 1、图片下载总调用数仍为 1、第二次直接命中文件缓存、不触发 loading 回调**：

| 第一次 | 第二次 | 测试 |
| --- | --- | --- |
| App 输入 | 悬浮球选择下载 | 已通过 |
| 悬浮球选择下载 | App 输入 | 已通过 |
| 悬浮球选择下载 | 悬浮球打开 App | 已通过 |
| 悬浮球打开 App | 悬浮球选择下载 | 已通过 |

同文件还覆盖：分享/普通历史/批量入口、10 分钟 TTL、媒体 URL 提前过期、请求声明过期与快照保留、强制刷新后 URL 改变而缩略图仍命中、新短链别名、全屏身份转换、诊断标签隐私。`media_image_policy_test.dart` 使用实际 Flutter ImageCache 条目验证过期声明仍不能绕过 obtainKey 检查。原生 `SharedPreviewCacheTest.kt` 验证 10 分钟 TTL、hit/expired/miss、canonical 更新与旧别名保留，以及既有容量/路径限制。

## 3. 历史平台别名只在读取时统一

根因：真实 `HistoryPage._platformMenu` 将启用站点 ID 与 `_records.platform` 原样放入 Set，因此 xhs 与 xiaohongshu 是两个键、却显示同一个名称；过滤又直接用字符串相等，只能命中其中一个值。

改动：

- `SiteRegistry.byId` 按 id、platform、声明 aliases 的顺序解析，已知历史站点可用 builtin 身份兜底；未知站点继续独立。新增 `canonicalId` / `sameSite`，配置补充 rednote→xhs、twitter→x，schema 接受有界别名数组。
- 实际菜单先按 canonical ID 去重，过滤用 sameSite；标题/图标/颜色也按同一站点读取。真实按钮增加编译后可检查的 `canonical-platform-filter` 标记。
- 作者分组使用 canonical 站点 + 作者名，旧别名不拆桶，不同平台同名作者不混桶。下载队列按帖查询/统计、已保存来源比较、历史短链匹配也使用同一身份比较。
- 备份的 toSpecPlatform/toAppPlatform 已基于 Registry，本轮补齐别名和已下架已知站点的身份兜底。备份导出测试确认两种旧值均输出规范 xiaohongshu。
- **没有数据库迁移，也不重写历史 platform 字段**。总记录数仍按真实记录计数；不因修复平台标签而删除/合并帖子或文件。

`history_platform_alias_test.dart` 挂载真实 HistoryPage：SQLite 中同时有 xhs、xiaohongshu 和另一平台记录；菜单仅一个“小红书”，选中后同时显示前两条且隐藏第三条；备份映射正确，交互前后原始平台值保持不变。也覆盖声明 aliases、下架已知站点和未知站点隔离。

## 4. 版本、门禁和交付

解析编排/配置已更新，parser 升至 **1.4.3**；App 为 **1.10.0+21**。TS 提取算法未改，现有 spec fixtures/测试向量未改，provenance-spec 与 provenance_dart 只读。未进行设备自动化、私有目录读取、run-as、卸载、清除数据或相册删除；未 push、merge、tag 或发布远程 parser。

- Flutter 最终全量：**692 passed**，日志 `app/build/build21-flutter-final.log`。相比 build 20 的 679 项，新增顺序/缓存/过期/身份/隐私 11 项、历史别名 2 项。
- Android 全量：**85 passed，0 failures/errors**，日志 `app/build/build21-android-full.log`；相比 83 项增加中央 lookup 期限和 canonical 更新/别名保留 2 项。
- Extension：**159 Vitest + 21 构建检查**，含 typecheck；生产构建通过。日志 `app/build/build21-extension-test.log`、`build21-extension-build.log`。
- 扫码脚本：4 项通过。Flutter analyze 使用 `--no-pub --no-fatal-infos --no-fatal-warnings`，退出 0，无 error，81 条 warning/info；日志 `app/build/build21-analyze-final.log`。
- 本轮定向与最终全量测试均通过，没有在门禁失败状态提交。

实现 commit：`930c169bbc42b1339149572f5c3b446bb3a54bb9`。上述门禁通过后提交，再执行 `flutter build apk --debug --no-pub --build-name=1.10.0 --build-number=21`；assembleDebug 85.0 秒，构建成功。Kotlin daemon 首次启动退出后由构建自动恢复，最终没有编译错误。

- APK：`app/build/app/outputs/flutter-apk/EasySave-1.10.0-build21-debug.apk`（173,529,281 bytes）。
- SHA-256：`76fd3b5a530950ec778ca4c20c43e722e7598d7e28a451a619bfc2e6fede7093`。
- aapt：`package: name='com.james.easysave' versionCode='21' versionName='1.10.0'`；APK 内置 parserVersion 为 `1.4.3`。

编译后证据（`app/build/build21-apk-evidence.log`，复核脚本退出 0）：

- `kernel_blob.bin` 中真实 HistoryPage 按钮标记 `canonical-platform-filter` 位于 offset **86221121**；`canonicalId` / `sameSite` 均存在。真实菜单 widget 的行为另由上述 SQLite widget 测试覆盖。
- `lookupParsed` 位于 offset **86768156**；`ParseCache` / `ThumbCache` 位于 **86767780 / 86865453**；稳定身份字段 `cachePostId` / `cacheItemIndex` 位于 **86092514 / 86063720**。
- `classes19.dex`：HostService 地址 `013330` 与 MainActivity 地址 `01678a` 均调用 `SharedPreviewBridge.register`（后者为 Kotlin default 包装），证明两个引擎均登记同一桥。
- 同一 DEX 的桥在 `028f42` 调用 `ParsedHandoff.lookup`，`028f66` 调用 `ParsedHandoff.put`；在 `028e2e / 028ec0` 调用 `ThumbnailFiles.read / write`。这核实读取、写入和共享文件通道均进入最终 APK。
- APK 内站点别名 xhs/rednote、x/twitter 均存在；四个品牌 SVG 与源文件完全一致。校验最终输出 `PASS: actual history menu marker, stable identities, bidirectional native RAM cache and shared thumbnails`。

APK 复核命令（仓库根目录）：

```powershell
$env:PYTHONIOENCODING = 'utf-8'
rtk proxy python tools/verify_build21_apk.py app/build/app/outputs/flutter-apk/app-debug.apk --dexdump D:/Android/Sdk/build-tools/35.0.1/dexdump.exe
rtk proxy D:/Android/Sdk/build-tools/35.0.1/aapt.exe dump badging app/build/app/outputs/flutter-apk/app-debug.apk
```

复测时可用“我的 → 清空日志”生成新记录，然后在十分钟内复现四种顺序，检查第二次的 ParseCache/ThumbCache hit；主动重新解析应出现 miss/store。历史帖子模式打开平台菜单检查单一“小红书”及两类旧记录的筛选。本轮不以离线测试代替设备时延或交互验证。
