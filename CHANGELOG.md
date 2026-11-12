# Changelog / 更新日志

本文按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 整理面向用户的主要变化，中英文逐条对应。
This file documents notable user-facing changes following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with matching Chinese and English entries.

本稿依据 `docs/tasks/` 的任务文档与交接记录回顾整理；v1.10 已按用户确认的代码版本 0e367c1 定稿并随本节发布。

## [Unreleased]

### 修复 / Fixed

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
