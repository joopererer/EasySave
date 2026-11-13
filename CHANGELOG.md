# Changelog / 更新日志

本文按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 整理面向用户的主要变化，中英文逐条对应。
This file documents notable user-facing changes following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with matching Chinese and English entries.

本稿依据 `docs/tasks/` 的任务文档与交接记录回顾整理；v1.10 已按用户确认的代码版本 0e367c1 定稿并随本节发布。

## [Unreleased]

## [1.10.3] - 2026-11-12

### 修复 / Fixed

- 启动时比较 App 内置的 parser 清单与已下载的在线版本，启用 `manifestVersion` 较高的一份：此前只要设备下载过在线 parser 就永远使用它，APK 里更新的解析器永远不会生效（真机日志 `activeVersion=1.4.15 activeManifest=11` 而 `builtinManifest=12`）。内置版本同样经过校验（APK 签名 + 清单结构与 parser 哈希），选择结果写入一行 `[ParserUpdate] event=select builtin=… stored=… chosen=… reason=…`。
  Startup now compares the parser manifest bundled in the App with the downloaded one and uses whichever has the higher `manifestVersion`: a device that had ever downloaded a parser kept using it forever, so a newer parser inside the APK never took effect (device log showed `activeVersion=1.4.15 activeManifest=11` while `builtinManifest=12`). The bundled manifest is verified the same way (APK signature plus manifest structure and parser hash), and the choice is logged as one `[ParserUpdate] event=select builtin=… stored=… chosen=… reason=…` line.
- 选中内置 parser 时防回滚水位线同步提升到该版本，之后在线通道发来同号同内容的版本按「相同」处理（`result=same reason=same_as_builtin`），不再报冲突；同号但内容不同时保持现状并记录 `reason=same_sequence_different_content`，不启用另一份。
  When the bundled parser wins, the anti-rollback watermark rises with it, so a later online release with the same sequence and the same signed content counts as a match (`result=same reason=same_as_builtin`) instead of a conflict; a same-sequence release with different content keeps the current source and is logged as `reason=same_sequence_different_content`.
- 某站点的登录状态变化（登录成功、退出、检测到会话失效）时清除该站点的解析缓存，日志 `[ParseCache] event=cleared site=… reason=login|logout|session_invalid`；此前 Instagram 登录后仍会命中登录前的封面结果，需要悬浮球重新解析才正确。
  A site's parsed cache is now cleared whenever its login state changes — a confirmed login, a logout, or a detected expired session — logged as `[ParseCache] event=cleared site=… reason=login|logout|session_invalid`. Before this, Instagram kept answering with the cover parsed before login, and only a manual re-parse from the floating ball got the real media.
- 解析失败与降级结果（例如登录墙上仅有的封面图）不再写入解析缓存（`[ParseCache] event=degraded reason=og_cover_only`）；解析过程中若登录状态变化，这一次的结果照常显示但不会写入缓存。
  A failed parse and a degraded answer (for example the only cover a login wall exposes) are no longer written to the parse cache (`[ParseCache] event=degraded reason=og_cover_only`); a parse whose site changed login state while the page was loading is still shown but never published to the cache.
- 历史页与首页的「刷新」一定重新解析：强制刷新不再并入正在进行的缓存命中请求；命中缓存的日志仍为 `ParseCache event=hit`。
  「刷新」 in history and on the home page always re-parses: a forced refresh no longer joins an in-flight task that is about to answer from the cache. A cached answer still logs `ParseCache event=hit`.

- 保存时不接受本机无法显示的 HEIC / AVIF 原图：iPhone 写的带透明通道的 HEIC（alpha 辅助图）在 Android 9–12L（SDK 28–32）上无法显示，这类原图不再保存进相册，改为优先使用 jpg 全质量转码（`imageView2/format/jpg/q/100`，原尺寸），全部原图候选都不可用时才退回预览图并标「非原图」。HEIC 的判定改为只读文件头（`ftyp` / `meta` / `iinf` / `iref` / `auxC`），不调用系统解码器，因此不会把解码通道占住；Android 13 及以上交给本机解码器判断，独立线程、带超时，超时按「未知」处理（既不拒收也不判为缺失）。AVIF 仍走原生解码自检（BitmapFactory / ImageDecoder，只取边界并小尺寸采样）。日志 `result=rejected:undecodable_on_device`。
  A HEIC / AVIF original this device cannot display is no longer saved: an iPhone HEIC that carries an alpha auxiliary image cannot be shown on Android 9–12L (SDK 28–32), so such an original no longer reaches the album and the Xiaohongshu CDN's full-quality jpg transcode (`imageView2/format/jpg/q/100`, original pixel size) is preferred instead; only when every original candidate fails does the item fall back to the preview still, marked 「非原图」. A HEIC is now decided by reading its container header (`ftyp` / `meta` / `iinf` / `iref` / `auxC`) and never by calling the platform decoder, so nothing can hold the decode channel; Android 13 and later ask the device decoder instead, on its own thread under a timeout, and a timeout counts as "unknown" — the file is neither rejected nor treated as missing. AVIF still goes through the native decode check (BitmapFactory / ImageDecoder, bounds plus a small sampled decode only). Logged as `result=rejected:undecodable_on_device`.
- jpg 原图优先，并新增小红书 CDN 的 JPEG 原图候选（`imageView2/format/jpg/q/100`，原尺寸），排在 HEIC 原图之前；实测 `format/jpeg` 与 `format/jpg` 字节一致，仅 `format/jpg` 会把 1290×1608 的图压到约 245KB，加 `/q/100` 后回到约 1.03MB，与 1.01MB 的原始字节接近。
  JPEG originals are preferred, with an extra Xiaohongshu CDN JPEG original candidate (`imageView2/format/jpg/q/100`, original pixel size) ranked before the HEIC original: `format/jpeg` and `format/jpg` return identical bytes, while plain `format/jpg` re-encodes 1290x1608 down to about 245KB and adding `/q/100` restores about 1.03MB against the 1.01MB stored original.
- 对连接重置与超时的重试由 1 次提高到最多 3 次指数退避（0.6s、1.2s、2.4s）再换下一个候选；预检改用与正式下载相同的 GET + Range 请求、同一套请求头（浏览器 UA、`Accept-Encoding: identity`），使预检与下载在 CDN 侧不再像两个不同客户端。
  Retries on a connection reset or timeout went from one to up to three exponential backoffs (0.6s, 1.2s, 2.4s) before switching candidates. The preflight now uses the same GET + Range request and the same headers as the download (browser User-Agent, `Accept-Encoding: identity`), so the CDN no longer sees the preflight and the transfer as two different clients.
- 修复同一帖子序号下旧封面图与新下载视频被当成一张实况的问题：图片与视频只有在双方 pair_id 一致、或由同一次下载写入时才配对，扩展名不同的旧文件不再顶替新文件的 assetId。
  Fixed an old cover still and a freshly downloaded video of the same post sequence being treated as one Live photo: a still and a clip only pair when both carry the same pair_id or were written by one download, and an older file of another extension no longer answers the new file's assetId lookup.
- 视频写入相册时显式写入时长与像素尺寸，写入后读回 DURATION 并在仍为 0 时触发一次扫描，日志打印导入前后的时长，避免相册显示 0 秒。
  A saved video now carries its duration and pixel size from the start; after publishing, DURATION is read back, a rescan is triggered when it is still 0, and the duration before/after is logged, so the album no longer shows a 0-second entry.
- 视频与实况播放失败时记录播放器错误类型（不含 URL），静态图不会再被当作视频交给播放器。
  Player failures now log the player error type (never the URL), and a still is never handed to the player as a video.
- 本地缩略图增加每项独立超时：单个文件解码失败或超时不再留白，回退到网络封面或占位图并记录 `[ThumbLoad] event=local_decode_failed`；不使用共享加载闸门，也不读取整份原图。
  Local thumbnails now have a per-item deadline: a file that fails or stalls falls back to the network cover or a placeholder and logs `[ThumbLoad] event=local_decode_failed`, without a shared gate and without reading a whole original.
- 已保存但本机无法解码的 HEIC 会在历史卡片上标注「本机无法显示此格式」，点开后可「重新下载」：先确认再删除相册中的旧文件，并按新规则替换该项；检测为后台只读、带超时、一次一个文件。此前这类旧帖子会让历史页卡死：缩略图排在一个永不返回的解码后面一直等待。
  A saved HEIC this device cannot decode is marked 「本机无法显示此格式」 on its history card, and opening it offers 「重新下载」: the old album file is deleted only after the user confirms, and the item is replaced under the new rules. The detection is a background, read-only, one-file-at-a-time pass with a timeout. Such a post used to stall the history page: every thumbnail behind a decode that never returned waited for it.
- 登录成功后错误卡片自动消失并重新解析当前链接，无需再点一次「解析」；`MEDIA_UNAVAILABLE`（解析器要求 App 具备相应能力）与 `LOGIN_REQUIRED`（会话失效）两种卡片都按此处理。
  A successful login now clears its error card and re-parses the current link on its own, with no second tap on 「解析」; this holds for both `MEDIA_UNAVAILABLE` (the parser needs a capability this App lacks) and `LOGIN_REQUIRED` (expired session).
- 删除帖子按真实文件数统计、先把相册 id 解析出来再请求删除，部分失败如实报告，删除后列表不再残留该帖。
  Deleting a post now counts its real files, resolves the album ids before requesting deletion, reports a partial failure as such, and leaves no stale post behind in the list.
- 尝试次数显示文件真实的预算，被自身策略拒绝即视为最终结果，不再出现 `attempt=5/3` 这类越界计数或同一条 220 次重复拒绝。
  The attempt counter now reports the file's real budget, and a rejection by the request policy is final, so `attempt=5/3` style overruns and the 220 repeated rejections of one item cannot recur.

- Instagram：当页面未返回完整媒体（登录失效或被限制）时，解析不再把网页分享封面（og:image）当作帖子媒体交出；reel/电视页或 /p/ 页仅拿到封面时返回错误，提示在“我的”页检查 Instagram 登录后重试；只有确认公开单图只能通过 og_meta 获取的情况才会先停止并报告，再决定是否标注“非原图”。
  When Instagram returns no complete media (login expired or limited), the parser no longer hands out the OpenGraph share cover (og:image) as the post media: a reel/video page or /p/ page with only a cover now fails and prompts the user to re-check Instagram login in "My", instead of presenting one cover as the whole post. Public single-image posts that can only be obtained through og_meta are reported first for a decision on keeping them marked as "non-original".
- 新增解析诊断日志 `[IgParse] source=api|graphql|embedded_json|og_meta mediaType=image|video|carousel items=N loginWall=0|1`，可区分数据来自接口、嵌入 JSON 还是 OpenGraph 元数据；`hook=probe` 对 Instagram 是无效探针，已改为空探针，不再把它当成 mismatch 记录。
  Adds parse diagnostics `[IgParse] ...` telling whether Instagram data came from the API/GraphQL, embedded JSON or OpenGraph meta; `hook=probe` is an invalid probe for Instagram and is now a null probe, no longer recorded as a mismatch.

## [1.10.2] - 2026-11-12

### 修复 / Fixed

- 修复小红书 jpg 候选连接失败后回退到 HEIC 原图时写入相册失败的问题：协议栈、HTTP 方法与预检请求的差异导致原生下载连接被重置，现重置与超时时先在同一候选上做一次短暂退避重试，仍失败再换下一个候选，每次尝试写一条日志；重试成功后立即清除旧批次的失败标记，无需离开页面或重新进入。
  Fixed saving to the gallery after a Xiaohongshu jpg candidate connection failure falls back to the HEIC original: after a stack/method difference against the preflight HEAD request caused the native download connection to be reset, a reset or timeout now retries the same candidate once after a short backoff, then moves on; one log line is written per attempt. A successful retry clears the stale batch failure immediately, without leaving the page.
- HEIC / HEIF / AVIF / GIF 原图按原格式写入相册：当 `provenance=skipped` 时，原生导入链路不再执行任何依赖内嵌来源信息或限定容器格式的检查（inspectTarget、pair 校验、来源验证等），直接按文件真实 MIME 写入；实况 HEIC 静态图的配对只依赖历史行的 pair_id，不依赖文件内 XMP。
  Originals kept in their own format (HEIC / HEIF / AVIF / GIF): when provenance is skipped, the native import chain runs no check that depends on embedded provenance or restricts container format (inspectTarget, pair validation, provenance verification), and imports straight by the file's real MIME type. A Live photo's HEIC still pairs only through its history-row pairId, not through XMP in the file.
- 扩展原生导入链路的容器白名单：`ExportNames`、`PublicMediaWriter`、`ProvenancePairWriter` 均接受 gif、heic、heif、avif；来源信息可嵌入的容器集合保持不变。
  Extended the native import container whitelist: `ExportNames`, `PublicMediaWriter` and `ProvenancePairWriter` now accept gif, heic, heif, avif; the set of containers that can carry provenance is unchanged.

### 安装 / Install

- 与 v1.10.1 使用同一签名密钥，可直接覆盖安装，不必卸载旧版或清数据。Same signing key as v1.10.1, so this installs over it without uninstalling or clearing data.

## [1.10.1] - 2026-11-12

### 修复 / Fixed

- 修复小红书 Live 图的动态部分被存成无法播放的 .mp4（实际是 HEIC 图片）的问题：动态视频只使用视频地址，下载完成后按文件头确认实际类型，与预期不符的文件会被丢弃并换用下一个候选，扩展名与 MIME 类型按实际内容写入，图片不再被追加 MP4 的来源信息。
  Fixed Xiaohongshu Live photos saving the dynamic portion as an unplayable .mp4 (it is actually a HEIC image): the motion part now uses video URLs only, the downloaded file's real type is confirmed from its header, a file that does not match is discarded in favour of the next candidate, the extension and MIME type follow the actual content, and images no longer receive MP4 provenance.
- 修复 Live 图被当成两个文件的问题：图片与动态视频在下载写入历史时就带上配对标识，帖子卡片、首页“最近保存”和全屏查看器统一按同一规则配对，一对 Live 图计为 1 个条目、显示为 1 张（LIVE 标记，长按播放）。
  Fixed Live photos being shown as two files: the still and the motion clip now carry their pairing identity as soon as the download writes history, and the post card, the home "recently saved" list and the fullscreen viewer all pair with one shared rule, so a Live photo counts as one entry, shown as one still with the LIVE badge and long-press playback.
- 修复混合帖中实况静态图下载失败的问题：静态图取到 HEIC / AVIF 时不再被当作失败，按原格式保存并跳过来源信息，仍与动态视频配对；图片任务收到视频文件时改判该候选不合格并换下一个候选，而不是报“不支持的格式”。失败提示改为逐条可读文案（如“第3项实况的静态图保存失败”），通知、历史卡片和下载队列中不再出现原始异常（包括“Bad state: …”）。
  Fixed Live stills failing to download in mixed posts: a still that arrives as HEIC / AVIF is no longer treated as a failure — it is saved in its own format with provenance skipped and still pairs with its motion clip, and an image job that receives a movie now rejects that candidate in favour of the next one instead of reporting an unsupported format. Failures are reported as readable per-item text (e.g. "第3项实况的静态图保存失败") instead of raw exceptions (including "Bad state: …") in notifications, history cards and the download queue.
- 修复覆盖安装后自动备份设置丢失的问题：保存设置时不再移除备份文件夹，也不会用尚未加载完成的默认值把自动备份关掉；文件夹授权确实失效时保留开关与文件夹名，设置页与首页提示“备份文件夹授权已失效，点此重新授权”，重新授权仍打开原来那个文件夹，只有系统确认持久授权已消失才判定文件夹丢失。
  Fixed auto-backup settings being lost after a covered install: saving settings no longer drops the backup folder or switches auto-backup off from a snapshot that had not finished loading, and when the folder grant really is gone the switch and folder name are kept while the settings page and the home page show "备份文件夹授权已失效，点此重新授权" (backup folder permission expired, tap to re-authorize), re-authorizing the same directory; a lost folder is only declared once the system confirms the persisted grant is gone.
- 修复图片与 Live 静态图取到低清预览图的问题：画质优先，原图地址（ci / img / ci:jpg）按顺序尝试，HEIC / AVIF 原图按原格式保存（不写入来源信息，仍与动态视频配对），只有全部原图地址都失败时才使用预览图并标记“非原图”。
  Fixed stills (including a Live photo's still) being saved from a low-resolution preview: quality now comes first, original candidates (ci / img / ci:jpg) are tried in order, a HEIC / AVIF original is saved in its own format (without embedded provenance and still paired with its motion clip), and a preview is only used once every original candidate failed, keeping the "非原图" mark.
- 改进候选地址失败后的快速切换：一个候选失败后立刻换下一个，同一候选不会重复请求，每个候选只尝试一次（仍受全局尝试次数上限约束），失败项不再拖住其他项的下载。
  Improved fast failover when a candidate address fails: a failed candidate immediately moves on to the next one, the same candidate is never requested again, each candidate is tried once (still bounded by the overall attempt cap), and one failing item no longer holds up the others.
- 下载日志补充候选地址的主机类别（站点媒体 / CDN / 其他）与连接失败原因，不记录网址、主机名或查询参数。
  The download log now records the candidate host class (site media / CDN / other) and the connection failure cause, without writing the URL, host name or query string.

### 已有错误文件的处理 / Files already saved wrongly

- 本版本不会自动处理已经保存的错误文件，请在相册中手动删除。识别方法：文件名以 `.mp4` 结尾、在相册中显示为 0 秒、点开后无法播放。删除后重新下载该帖子即可得到正常的 Live 图与动态部分。
  This version does not touch files that are already saved; please delete them in your gallery yourself. How to recognise them: the name ends in `.mp4`, the gallery shows a 0-second video, and it does not play. Downloading the post again afterwards gives a correct Live photo and motion part.

## [1.10.0] - 2026-11-11

### 新增 / Added

- 增加小红书中国大陆与海外账号登录入口，并分别显示已验证的登录状态。
  Added separate login entry points for Xiaohongshu mainland China and overseas accounts, each displaying its verified login status.
- 增加 Instagram 帖子 AI 标注识别与显示。
  Added recognition and display of AI labels on Instagram posts.
- 增加 TikTok 视频封面及悬浮球 Live 预览，支持从悬浮球打开 App 观看受限视频。
  Added TikTok video covers and Live Photo previews in the floating overlay, with an option to open restricted videos in the app.

### 修改 / Changed

- 改进解析规则在线更新，兼容性检查或更新失败时继续使用可用规则。
  Improved online parser updates, retaining working rules when compatibility checks or updates fail.
- 改进备份格式，保留原帖链接与失败状态、不再保存易失效的媒体链接，并兼容恢复旧备份。
  Improved backups to retain original post links and failure states without storing short-lived media links, while keeping older backups restorable.
- 恢复备份时显示处理进度，并更谨慎地匹配本机相册文件。
  Added restore progress and more cautious matching of files in the local gallery.
- 改进多入口共享预览与缩略图加载，减少重复解析和滚动等待。
  Improved shared previews and thumbnail loading across entry points to reduce repeated parsing and scrolling delays.
- 改进小红书原图选择，对未达到原帖声明尺寸的图片提示“非原图”。
  Improved original-image selection on Xiaohongshu and added a warning when images are smaller than the dimensions declared by the post.
- Instagram 来源信息不再将可变的用户名作为稳定作者标识。
  Instagram provenance information no longer treats mutable usernames as stable author identifiers.

### 修复 / Fixed

- 修复小红书及 TikTok 部分短链解析失败、小红书缺少分享凭据时提示不明确的问题。
  Fixed parsing failures for some Xiaohongshu and TikTok short links and unclear messages when Xiaohongshu share credentials are missing.
- 修复部分受限 X 帖子未使用已有登录状态，以及部分小红书视频下载后缺少音轨的问题。
  Fixed some restricted X posts not using the existing login session and some downloaded Xiaohongshu videos missing audio.
- 修复历史文件重复计数、扫描覆盖新下载文件，以及删除后重新保存仍显示旧文件的问题。
  Fixed duplicate history file counts, scans overwriting newly downloaded file records, and stale files appearing after deletion and re-saving.
- 修复历史分组标题叠加、排序后布局异常及部分读取或刷新卡顿问题。
  Fixed overlapping history group headers, layout issues after sorting, and some stalls during reading or refreshing.
- 修复已保存媒体预览误走网络、默认误选图片及部分视频画面拉伸问题。
  Fixed saved-media previews unnecessarily accessing the network, incorrect default image selection, and stretching in some video previews.
- 修复悬浮球横屏贴边、已保存文件识别及大图预览异常。
  Fixed floating-overlay edge positioning in landscape, saved-file detection, and large-image preview issues.
- 修复大文件下载时存储不足提示、失败记录展示及备份恢复状态不准确的问题。
  Fixed insufficient-storage messages for large downloads, failed-record display, and inaccurate backup restore status.

### 已知问题 / Known issues

- 下载带 Live 图的小红书帖子时，动态部分可能被存成无法播放的 .mp4（实际是 HEIC 图片）；已在 1.10.1 修复。
  Posts with Live images downloaded from Xiaohongshu may save the dynamic portion as an unplayable .mp4 (it is actually a HEIC image); fixed in 1.10.1.

### 签名密钥变更 / Signing key change

- 本版本更换了签名密钥。从旧版本升级，需要先导出备份、卸载旧版、安装新版后恢复备份，再重新授权和登录。
  This release uses a new signing key. Upgrading from an older version requires exporting a backup, uninstalling the old version, installing the new version, restoring the backup, then re-authorizing and logging in.

## [1.9.0]

### 新增 / Added

- 支持 TikTok 视频和图集的解析、下载、预览及历史记录。
  Added parsing, downloading, previews, and history for TikTok videos and photo posts.
- 增加帖子 AI 标注识别、展示，并将标注写入媒体来源信息。
  Added recognition and display of post AI labels, including preservation in media provenance information.
- 增加 C2PA 媒体的安全保存与来源边车文件处理。
  Added safe saving of C2PA media with provenance sidecar files.

### 修改 / Changed

- 统一媒体文件命名并改进相册重建、来源信息回填和下载冲突处理。
  Standardized media filenames and improved gallery-based history rebuilding, provenance backfilling, and download conflict handling.
- 改进历史缩略图加载、下载任务状态反馈及媒体预览体验。
  Improved history thumbnail loading, download status feedback, and media previews.

### 修复 / Fixed

- 修复 TikTok 移动页面解析、短链识别及会话视频下载问题。
  Fixed TikTok mobile-page parsing, short-link recognition, and session-authenticated video downloads.
- 修复历史删除与下载并发、重复保存及相册文件重新定位问题。
  Fixed conflicts between history deletion and active downloads, duplicate saves, and gallery file relocation.
- 修复 Live Photo、媒体来源信息和多入口下载中的若干兼容问题。
  Fixed compatibility issues affecting Live Photos, media provenance information, and downloads from different entry points.

## [1.8.3]

### 新增 / Added

- 悬浮球选择面板支持长按预览大图和视频，并提供预览常驻、滑动切换及播放控制。
  Added long-press image and video previews to the floating selection panel, with persistent previews, swipe navigation, and playback controls.
- 支持直接输入媒体编号批量选择，缩略图默认关闭并可按需加载。
  Added batch selection by typing media numbers, with thumbnails disabled by default and loaded on demand.
- 增加下载队列页面，支持逐项取消、重试和批量删除，并在历史及预览页显示下载进度。
  Added a download queue with per-item cancellation, retries, and batch deletion, plus download progress in history and previews.

### 修改 / Changed

- 备份恢复遇到未完成下载时，可选择前往下载队列或取消全部后继续。
  Backup restoration now offers to open the download queue or cancel all unfinished downloads and continue.

### 修复 / Fixed

- 修复单项入队失败拖住其他下载及下载或相册导入长期停滞的问题。
  Fixed individual enqueue failures blocking other downloads and prolonged stalls during downloading or gallery import.
- 修复历史浏览器默认误选媒体的问题。
  Fixed incorrect default media selection in the history viewer.
- 改进 Instagram 敏感内容、年龄限制及动态加载帖子的解析，减少错误的登录失效提示。
  Improved parsing of sensitive, age-restricted, and dynamically loaded Instagram posts to reduce incorrect session-expired messages.

## [1.8.2]

### 新增 / Added

- 支持 MP4 和 MOV 视频的来源信息保存、读取与旧文件补写。
  Added provenance writing and reading for MP4 and MOV videos, including backfilling existing files.
- 支持 Live Photo 图片与视频配对，并在相册重建时合并为同一项。
  Added pairing of Live Photo images and videos into a single item when rebuilding history from the gallery.

### 修复 / Fixed

- 修复历史中已拆开的 Live Photo 记录无法正确合并的问题。
  Fixed previously split Live Photo history records not merging correctly.

## [1.8.1]

### 修改 / Changed

- 统一图片来源信息的读写规则，改善旧文件补写及 PNG 相册重建兼容性。
  Unified image provenance reading and writing rules to improve backfilling and gallery-based history rebuilding for PNG files.

### 修复 / Fixed

- 修复备份轮转与去重行为，保留最近七份备份且不影响同文件夹内的其他文件。
  Fixed backup rotation and deduplication to retain the latest seven backups without affecting other files in the same folder.

## [1.8.0]

### 新增 / Added

- 增加本地与用户指定文件夹的自动备份、备份预览及历史恢复功能。
  Added automatic backups to local storage and a user-selected folder, backup previews, and history restoration.
- 增加从相册重建历史、跨设备定位媒体文件和恢复设置的支持。
  Added gallery-based history rebuilding, media file relocation across devices, and settings restoration.

### 修改 / Changed

- 备份恢复支持合并历史与相册信息，并在恢复后重新定位本机文件。
  Backup restoration now merges history and gallery information and relocates local files after restoration.

### 修复 / Fixed

- 修复空历史自动备份覆盖现有备份、软删除记录被导出及重复恢复等问题。
  Fixed empty-history automatic backups overwriting existing backups, export of soft-deleted records, and duplicate restoration issues.
- 修复恢复时悬浮球权限、相册路径和历史文件匹配方面的问题。
  Fixed floating-overlay permission handling, album paths, and history file matching during restoration.

## [1.7.0] - 2026-10-22

- 新增 JPEG、PNG 和 WebP 图片来源元数据的写入与保留。
  Added provenance metadata writing and preservation for JPEG, PNG, and WebP images.
- 新增 C2PA 检测与安全跳过行为，不生成边车文件。
  Added C2PA detection and safe skip behavior without generating sidecars.
- 新增链接规范化、从相册重建历史、取消操作、相册选择及旧文件补写流程。
  Added URL normalization, gallery history rebuild, cancellation support, album selection, and legacy backfill flows.
- 完成单元与规范一致性测试覆盖，并完成小红书、Instagram 和 X 的 JPEG 下载真机验证。
  Completed unit/conformance coverage and device verification for JPEG downloads from Xiaohongshu, Instagram, and X.
- 记录已知限制及 AI 元数据验证流程。
  Documented known limitations and the AI metadata verification procedure.
