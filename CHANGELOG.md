# Changelog / 更新日志

本文按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 整理面向用户的主要变化，中英文逐条对应。
This file documents notable user-facing changes following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with matching Chinese and English entries.

本稿依据 `docs/tasks/` 的任务文档与交接记录回顾整理；v1.10 已按用户确认的代码版本 0e367c1 定稿并随本节发布。

## [Unreleased]

## [1.10.1] - 2026-11-11

### 修复 / Fixed

- 修复小红书 Live 图的动态部分被存成无法播放的 .mp4（实际是 HEIC 图片）的问题：动态视频只使用视频地址，下载完成后按文件头确认实际类型，与预期不符的文件会被丢弃并换用下一个候选，扩展名与 MIME 类型按实际内容写入，图片不再被追加 MP4 的来源信息。
  Fixed Xiaohongshu Live photos saving the dynamic portion as an unplayable .mp4 (it is actually a HEIC image): the motion part now uses video URLs only, the downloaded file's real type is confirmed from its header, a file that does not match is discarded in favour of the next candidate, the extension and MIME type follow the actual content, and images no longer receive MP4 provenance.

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
