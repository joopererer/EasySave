# Build 36 — 相册本地读取卡死的根因、改动与交接记录

版本：`1.10.0+36`（versionCode 36）
分支：`feature/v1.10`
本轮不合并、不推送其他分支或 tag。

---

## 1. 根因（有日志与代码证据）

### 1.1 build 35 真机日志给出的定位

| 证据 | 说明 |
| --- | --- |
| `[HistoryTiming] step=refresh-media-failed` 19 次，每次 5005–5037ms | 历史页刷新本地媒体（`GalleryLocatorService.preloadMediaIds` → `AssetEntity.fromId`）19 次全部等满 5 秒预算后放弃，说明底层调用**既不成功也不失败**。 |
| 成功的 `refresh-media` 平均 294ms（最长 4195ms） | 同一段代码在插件不被卡住时很快，说明不是算法慢，而是**排在某个永不结束的调用后面**。 |
| `[ThumbLoad]` network 下载平均排队 556ms、decode 平均 234ms，cache_read 4–16ms | 网络缩略图缓存流水线正常，卡顿不在网络/解码层。 |
| 日志中**没有** `[PreviewImage]`/`[PreviewPlayer]`，也**没有**任何 photo_manager 读取日志 | 大图、视频、Live、本地封面的整条本地相册路径此前完全没有诊断，因此“看不见”的正是这一段。 |

结论：卡死发生在 **photo_manager / MediaStore 本地读取路径**，不是网络缩略图缓存。

### 1.2 机制解释（为什么一个帖子会拖垮全部帖子）

* `photo_manager` 在固定大小的执行器上跑所有原生调用，队列是无界 FIFO：一个调用不返回，就永久占用一个工作线程；后续所有缩略图/原图/封面请求都在同一个队列里排队。
* build 22 起加的“解码/读取并发上限 + 跨引擎 single-flight”**只覆盖网络缩略图**（`SharedThumbnailCache` / `CdnImage`）。本地相册路径**没有超时、没有页级取消、没有分池**。
* build 32 又让本地原图在解码期间不显示任何占位 → 原图一旦卡住，画面长期灰屏/空白，缩略图条只能偶尔出来一两张。
* 页面关闭时不取消进行中的请求，名额（此时等于插件线程）在页面退出后继续被占用 → 换到别的帖子也加载不出来，只有重启进程（插件队列重建）才恢复。

### 1.3 会“整文件复制”的调用点（Android 10 的 file/originFile/originBytes）

| 位置（build 35 代码） | 是否触发整文件复制 | 处理 |
| --- | --- | --- |
| `VerifiedAssetImage` → `AssetEntityImageProvider(isOriginal: true)` → `asset.loadFile` | 是（原图整份读入） | 改为 `LocalMedia.originalBytes`（有按文件大小的超时、独立名额、可取消） |
| `gallery_browser.dart` `_initVideo()` → `asset.file` + `exists()` | **是**：播放前先把整段视频复制到插件缓存目录；1GB 的 X 视频会长时间占用插件线程 | 改为 `LocalMedia.mediaUri`（`getMediaUrl` → `content://`），交给播放器流式读取，不再复制 |
| `gallery_browser.dart` `_startLiveMotion()` → `liveVideoAsset.file` | 是（Live 的运动片段） | 同上，走 `content://` |
| `gallery_browser.dart` `_shareCurrent()`、`history_page.dart` `_shareRecords/_shareMedia()` | 是（分享必须给真实路径） | 保留，但统一走 `LocalMedia.file`（有超时、独立名额、`[MediaLoad]` 记录），只在用户主动分享时发生 |
| `history_backfill_service.dart` `_resolveAssetFile()` → `asset.file` | 是（改写 provenance 需要真实路径） | 保留但加 128MB 上限 + `LocalMedia.file`（超时/名额/日志），大视频不再进入这条路 |
| `download_manager.dart` 相册校验/补全 | 否：只用 `MediaStore` 的 SIZE / provenance 头字节（`MediaHeaderService`，只读文件头） | 不变 |
| `history_page.dart` 封面、`gallery_browser` 缩略图条、`parse_page.dart` 48px 缩略图 | 否：只用 `thumbnailDataWithSize` | 现在全部经过 `LocalMedia` 名额与超时（`parse_page` 的 `AssetEntityImageProvider` 也改为经 `VerifiedAssetImage.providerFor`） |

---

## 2. build 22 以来的并发机制改了什么（回答“为什么以前只治了网络”）

* **build 22**：为网络缩略图加了下载/解码的并发上限和跨引擎 single-flight（`SharedThumbnailCache`、`CdnImage`），避免同一 URL 被多个引擎重复下载。范围仅网络。
* **build 32**：本地原图在解码期间不再显示占位（“不留假画面”），但也没有为原图加超时/取消 → 原图卡住时变成长期灰屏。
* **build 34**：改动被撤回；因为根因（本地相册路径无超时/无取消/无分池）在 22 之后一直存在，回退 34 对现象没有影响 —— 与 build 35 真机复测一致。

---

## 3. build 36 的改动

### 3.1 统一入口与诊断：`MediaLoadGate`（`app/lib/services/media_load_gate.dart`）

每一次图片/视频请求都写一条 `[MediaLoad]`，字段固定：

```
[MediaLoad] id=8123 kind=cover source=thumbnailDataWithSize event=completed
  pool=thumb waitMs=12 ioMs=48 ms=60 active=2/3 queued=5 abandoned=0
  pools=[lookup=1/4q0 thumb=2/3q5 original=1/1q0 video=0/1q0]
```

* `kind`：cover / thumb / original / video / live / lookup
* `source`：`getAssetPathList`、`getAssetListRange`、`thumbnailDataWithSize`、`getMediaUrl`、`getFullFile`、`exists`、`fromId`、`network`、`networkPreview`
* `event`：requested / slotAcquired / started / completed / failed / cancelled / timeout
* `waitMs`（排队+总耗时基线）、`ioMs`（底层调用耗时）、`ms`（总耗时）
* 每次记录都带当前四类池的 `active/limit/queued/abandoned`
* 日志不含 cookie、账号、完整 URL 或 query；网络侧只用哈希 identity。

### 3.2 没有永不结束的请求

| 请求类型 | 超时 |
| --- | --- |
| 封面 / 缩略图 | 5s |
| 原图 | 8s + 每 10MB 1s，上限 90s（按 MediaStore SIZE） |
| 视频准备 / Live 运动片段 | 15s |
| MediaStore 元数据查询（fromId/exists/assetCount/…） | 3s（相册列表 20s） |

* 超时或被取消 → **立刻释放名额**（`event=timeout` / `event=cancelled`），底层调用即使还在跑也不占名额，晚到的结果直接丢弃（计入 `abandoned`）。
* 排队本身也有时限：等待者在同一个 deadline 内拿不到名额同样 `timeout`，不会因为第一个请求卡住而全部挂起。
* 同 key 的重复解码由 `ImageCache` 合并（等价 single-flight），其 deadline 由底层请求继承，因此等待者不会无限等待。

### 3.3 页级取消

* `MediaLoadScope`：每个大图条目、缩略图条、每个本地缩略图行各有一个 scope，`dispose` 时取消本页/本行发起且未完成的请求并释放名额。
* 已发出、无法真正中止的底层调用只会留下一个“晚到结果”，不再占用任何名额。

### 3.4 分池（互不阻塞，缩略图优先）

| 池 | 名额 |
| --- | --- |
| lookup（MediaStore 元数据） | 4 |
| thumb（封面 + 网格/缩略图条） | 3（前台优先，预解码让位） |
| original（大图原图） | 1 |
| video（视频/Live 准备） | 1 |

一个卡住的大图原图只占 original 的 1 个名额，缩略图池始终可用（见测试 `a stuck original does not slow down thumbnails of other posts`）。

### 3.5 视频与本地大文件不再整文件复制

* 视频/Live 播放统一使用 `LocalMedia.mediaUri`（`getMediaUrl`）拿到的 `content://` URI，交给 `VideoPlayerController.contentUri` 流式读取。
* 仅需文件头的地方（provenance / XMP）继续只读头部字节（`MediaHeaderService`）。
* 回填（backfill）改写 provenance 需要真实路径，超过 128MB 直接跳过并记录，避免 1GB 视频进入整文件复制。
* 分享是唯一仍有整文件复制的路径（用户主动操作），已加超时、独立名额与日志。

### 3.6 大图浏览：先系统缩略图，再无声替换

* `VerifiedAssetImage(isOriginal: true)` 现在先画 `LocalThumbImageProvider` 的系统缩略图（不显示任何 loading），原图解码完成后叠加显示（`frameBuilder` 在拿到帧之前不绘制），**没有闪烁、没有灰屏**。
* 原图失败/超时：保留缩略图并显示“原图加载失败，点击重试”，点击重试原图；不回退到网络。
* 不恢复 build 34 的“读取全部字节再缩小”。

### 3.7 本地存在性改为三态，网络封面只用于“确实没有本地文件”

* `mediaExistence` 返回 `present / absent / unknown`。
* 只有 `absent`（MediaStore 明确回答没有）才使用网络封面；`unknown`（超时/插件繁忙/查询失败）**保持本地缩略图**，不再回退网络 —— 这是 build 35 日志里 173 次 `xhs:thumb` 等网络封面下载的直接来源之一。
* 历史页封面若本地索引未解析出 `AssetEntity`，会用已记录的 `mediaId` 直接向 MediaStore 查询，而不是立刻走网络。
* `preloadMediaIds` 增加上限（每次刷新最多 12 个 id）、失败 id 本次会话不再重试，避免 `refresh-media` 每次刷新重排队 19 个卡住的查询。

---

## 4. 全量测试结果

```
flutter test            ->  938 tests, all passed
flutter analyze lib test ->  0 errors
```

本轮新增/更新的关键测试：

* `test/build36_media_load_gate_test.dart`（新增 7 个）
  * 卡住的原图超时后归还名额
  * 卡住的原图不影响其他帖子缩略图（分池）
  * 卡住的缩略图超时后释放缩略图池
  * 排队本身有 deadline，等待者也会 timeout
  * 页面关闭取消未完成请求并释放名额
  * 视频只取 `content://`（断言从未调用 `getFullFile`/`getFullFile(origin)`）
  * 存在性检查不读取原图字节
* `test/build32_local_gallery_viewing_test.dart`：改为新契约（先缩略图、无 loading、原图无声替换；原图失败保留缩略图 + 可重试）
* `test/history_thumbnail_stability_test.dart`、`test/preview_refresh_test.dart`、`test/preview_media_roundtrip_test.dart`、`test/thumbnail_first_frame_test.dart`：适配新的 provider 与“unknown 不回退网络”语义，并为 photo_manager 通道提供测试替身，确保没有测试留下悬挂的 deadline 计时器。

---

## 5. 构建产物

| 项 | 值 |
| --- | --- |
| 版本号 | `1.10.0+36`（versionCode 36，versionName 1.10.0） |
| APK 路径 | `app/build/app/outputs/flutter-apk/app-release.apk` |
| 大小 | 63,960,902 字节 |
| SHA-256 | `c22297a2cd28ded3fc1761199e7f2dbb0f1fca38c5fa8252454b97274148b642` |

请以交付消息中的 SHA-256 为准复核（`Get-FileHash -Algorithm SHA256` 或
`sha256sum`）。

### APK 层面的证据

界面改动全部落在真实渲染的 widget 上（`VerifiedAssetImage` 的 `Image`/`RawImage`，
`_BrowserItemView` 的 video/live 分支），并有 widget 测试断言实际绘制的帧；APK 内
可核对到对应代码与文案：

| 检查项 | 结果 |
| --- | --- |
| `lib/arm64-v8a/libapp.so` 含 `MediaLoad` 日志标签与 `abandoned=` 字段 | 是（诊断随 build 交付） |
| 含 `LOCAL_VIDEO_URI_MISSING` / `LOCAL_LIVE_URI_MISSING` | 是（视频/Live 走 content:// 的分支已编译进包） |
| 含 `原图加载失败，点击重试` | 是（大图重试入口的真实文案） |
| 含 `视频准备超时，点击重试` | 是（视频准备超时的真实文案） |

---

## 6. 真机验证步骤（尚未验证，请勿视为已验证）

1. **卡死扩散回归**：打开一个含大视频（例如约 1GB 的 X 视频）的帖子 → 进入大图浏览让它加载一会儿 → 返回历史页 → 连续打开 3–5 个图片帖子的大图。
   * 期望：其他帖子的大图、底部缩略图条、历史页封面都能正常/快速出现；视频帖子之外的浏览不再被拖垮。
2. **快速滑动大图**：在有多图的帖子中快速左右滑动并双指缩放。
   * 期望：先出现系统缩略图，随后无声替换为原图；原图未完成时不会灰屏，也不会出现 loading。
3. **历史页滚动**：在历史页上下快速滚动，再进入大图返回。
   * 期望：已显示的缩略图不再消失重载；网络封面只出现在本地确实没有文件的帖子上。
4. **日志核对**（用于确认根因已被覆盖）：
   * 过滤 `[MediaLoad]`：每次请求都应有 `requested → started → completed|failed|timeout|cancelled`；
   * 出现 `event=timeout` 后 `active` 必须立即下降；
   * 打开大视频帖子后不应再出现 `source=getFullFile` 的长时间 `ioMs`（视频走 `source=getMediaUrl`）；
   * `[HistoryTiming] step=refresh-media-failed` 不应再成批出现（19 次那种情况）。