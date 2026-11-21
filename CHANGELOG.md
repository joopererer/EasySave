# Changelog / 更新日志

本文按 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 整理面向用户的主要变化，中英文逐条对应。
This file documents notable user-facing changes following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with matching Chinese and English entries.

本稿依据 `docs/tasks/` 的任务文档与交接记录回顾整理；v1.10 已按用户确认的代码版本 0e367c1 定稿并随本节发布。

## [Unreleased]

### 客户端 / App

- 网络切换中断保护与失败原因准确映射（build 78）：
  - 彻底修复首轮下载开始后网络切换（4G <-> Wi-Fi）导致任务被判失败并误记为 `CONTENT` 的问题：删除 `TaskStatus.canceled` 状态回调中误导性的 `cancel_call source=internal_interrupt` 日志，严格保持网络切换仅观察不打断（`network_change action=observe`）；
  - 确立 App 自身或原生层发起的非用户取消（`!userCancelRequested`）永远不能导致最终失败的规则：无已下载数据时自动从头重新入队并计入普通重试次数，有已下载数据时按插件 ResumeData 或物理临时文件断点续传，重试耗尽时转为「已中断，点继续」安全挂起，绝不执行 `temp_cleanup reason=final_fail`；
  - 纠正失败原因映射：未指定用户取消的 canceled 状态准确映射为 `reason=interrupted` 与 `cause=interrupted`；移除将「下载失败」误归类为内容错误的旧逻辑，`CONTENT` 分类严格限制为媒体容器与类型校验失败（如嗅探类型不符），普通下载失败如实记录为 `TRANSFER`。
  Network switch interrupt protection and accurate failure cause mapping (build 78):
  - Completely fixes an issue where network handover (4G <-> Wi-Fi) shortly after download start caused batch failure mistakenly classified as `CONTENT`: removes misleading `cancel_call source=internal_interrupt` log in the `TaskStatus.canceled` callback, strictly maintaining observation without interruption on network change (`network_change action=observe`);
  - Establishes the rule that internal or OS-initiated cancellations without user cancel request (`!userCancelRequested`) must never cause final failure: automatically re-enqueues from scratch when no data is downloaded counting towards regular retries, resumes from breakpoints using plugin ResumeData or physical temp file when partial data exists, and safely parks at "已中断，点继续" when retry caps are exhausted, never executing `temp_cleanup reason=final_fail`;
  - Accurately maps failure reasons: non-user cancellations are mapped to `reason=interrupted` and `cause=interrupted`; removes legacy mapping of generic download failures to content errors, strictly reserving `CONTENT` for actual media container and sniffing validation mismatches, while regular transport drops map to `TRANSFER`.

- 首轮任务暂停后继续恢复同一任务（build 77）：
  - 彻底修复从头开始下载的任务（首轮任务）暂停后点击继续从 0 重新开始的问题：首轮任务启动时，临时文件由插件自行命名和存放，插件暂停时生成并持久化包含临时文件实际路径的 ResumeData；App 在暂停回调中异步获取 ResumeData 并保存 `job.resumeTempPath` 与 `job.resumeStartByte`；
  - 用户点击继续时，若该 job 存在处于 paused 状态的插件任务，直接调用插件 resume 恢复同一个 taskId，跳过 preflight 检查，不开新一轮（保持单轮次任务不变）；
  - 断点续传起点与 preflight partial_bytes 计算均优先读取插件 ResumeData 中的物理临时文件大小作为唯一准则，消除因 App 无法获知插件内部临时文件路径而误判 partial_bytes=0 并误删 ResumeData 的问题；
  - 插件暂停时补充记录结构化诊断日志 `pause_resume_data taskId=... present=yes|no required_start_byte=... temp_exists=... temp_size=...`；App 重启或进程重建后根据持久化状态安全重建任务并恢复。
  First-round task pause and resume restoration (build 77):
  - Completely fixes an issue where tasks started from scratch (first-round tasks) restarted from 0 upon continue after user pause: for first-round tasks, temporary files are allocated and managed by the plugin; upon pause, the plugin generates and saves ResumeData with the actual temp file path; the App asynchronously fetches ResumeData and persists `job.resumeTempPath` and `job.resumeStartByte`;
  - When the user taps continue, if the job has a paused plugin task, directly invokes plugin resume for the exact same taskId, skipping preflight and avoiding initiating a new round;
  - Resumption start byte and preflight partial_bytes calculations prioritize reading the physical temp file size recorded in plugin ResumeData as the single source of truth, eliminating the issue where the App could not locate the plugin-managed temp file, mistakenly assumed partial_bytes=0, and cleared ResumeData;
  - Native plugin emits structured diagnostic log `pause_resume_data taskId=... present=yes|no required_start_byte=... temp_exists=... temp_size=...` upon pause; safely reconstructs and resumes paused tasks after app restart or process death.

- 断点以磁盘临时文件为准与暂停恢复修复（build 76）：
  - 修复暂停后点击继续从 0 重新下载的问题：用户主动暂停后点击继续，直接针对原已暂停的原生任务恢复下载（保持同一 taskId，不发起新一轮），消除因新轮次取消旧任务而误删 ResumeData 的问题；「只能有一个原生任务」检查中将 paused 视为不在运行，取消旧任务前强制备份保护已有临时文件；
  - 续传起点严格以磁盘上实际落盘的物理临时文件长度为准，彻底废除「只增不减」与「取较大者」逻辑；记录大于文件物理长度时按文件实际长度续传并记录日志（`resume_data_ahead`）；从 0 重新下载时彻底清空 App 与插件续传记录；同一原因连续失败超过 2 次（如 `resume_failed`）后转入「已中断，点继续」，避免死循环；
  - 修复发布门禁中的卡片按钮触摸热区（恢复 $\ge 44\times 44\text{dp}$ 规范）与同一卡片内百分比唯一展示规范（圈内展示百分比时文字标签不再重复）；修复单任务并发测试中的异步删除等待竞态。
  Disk temporary file length as ground truth for resume and pause/resume fix (build 76):
  - Fixes bug where resuming after user pause restarted from 0: resumes the exact same paused native task (`taskId`) without starting a new round, preventing old task preemption from clearing plugin ResumeData; treats paused tasks as not actively running and protects temp files before any non-terminal cancellation;
  - Resumption start byte is strictly determined by physical disk file size, discarding monotonic non-decreasing and max-value assumptions; when records exceed disk file size, truncates start byte to disk size and logs `resume_data_ahead`; wipes all resume metadata and plugin state when restarting from 0; pauses at "已中断，点继续" on repeated failure without infinite retry loops;
  - Fixes release gate failures: restores toggle touch target to $\ge 44\times 44\text{dp}$ and ensures single percentage display per card (omits duplicate percentage text next to progress rings); resolves async deletion polling race condition in concurrent tests.


- 收尾阶段细分显示恢复与优先级对齐（build 75）：恢复下载达 100% 后入库耗时阶段的细分文案呈现，在历史卡片底栏、下载队列、悬浮球三处完整联动展示「正在保存到相册（写入来源信息）」与「正在保存到相册（复制到相册）」；统一状态显示优先级为：空间不足 > 已暂停 > 收尾阶段（`isFinishing`） > 失败 > 状态文案 > 进度百分比，消除大文件在 100% 停滞约 50 秒的假死感，且与中断、暂停等异常状态互不覆盖混淆；历史页下载刷新逻辑补充入库阶段变化监听，保证进度达到 1.0 时仍能实时刷新子阶段文案。
  Restored saving phase granular display and priority alignment (build 75): re-enables detailed saving phase labels during post-download file import across history card overlays, download queue items, and the floating bubble ("正在保存到相册（写入来源信息）" and "正在保存到相册（复制到相册）"); aligns status display priority as: storage shortage > paused > saving phase (`isFinishing`) > failed > status text > progress percentage, removing the frozen feeling at 100% during prolonged finishing of large files without clobbering interrupted or paused states; downloads refresh loop in history page now tracks saving phase transitions to guarantee UI updates when progress reaches 1.0.

- 缩略图加载超时迟到平滑替换与单次重试（build 75）：历史卡片本地缩略图加载 5 秒超时后保留原请求监听并降级显示网络低清封面；若原请求后续就绪且卡片仍在屏幕上，以 180ms 交叉淡入无缝替换为清晰缩略图（`late_ok`）；若原请求最终失败或未返回，在卡片仍在可视区域的前提下于 20 秒后仅自动重试一次（`late_retry`），不在可视区则不重试，不增加全局并发上限，根治冷启动卡片模糊需手动滚动才能清晰的问题。
  Thumbnail late arrival smooth fade-in and single retry (build 75): keeps image stream listeners active after 5s local thumbnail timeouts with low-res network covers; if the native thumbnail arrives late while the card remains mounted on screen, it smoothly transitions to the sharp thumbnail via a 180ms cross-fade (`late_ok`); if the initial load fails or does not complete, it schedules a single retry after 20s if still on screen (`late_retry`), avoiding off-screen retries or raising concurrency limits and curing startup blurriness.

- 全屏浏览媒体信息条与元数据面板（build 75）：全屏大图浏览底部新增半透明紧凑信息条，展示「宽×高 · 格式 · 大小」，视频标注时长，实况照片标注「实况」；信息条显示 4 秒后自动收起为右下角圆形「ⓘ」图标，点击「ⓘ」重新展开，点击信息条主体弹出底部元数据详情面板（列出标题、尺寸、格式、大小、时长、路径与来源链接等完整字段）；双指放大图片（scale > 1.0）时完全隐藏信息条与「ⓘ」图标，复位后恢复；本地文件展示实际文件大小，远程预览仅为当前单页按需获取大小并标注「预计」，网络探测失败时静默忽略对应字段。
  Fullscreen viewer media info strip and metadata bottom sheet (build 75): adds a translucent compact media info strip at the bottom of the fullscreen viewer showing "width×height · format · size", with video duration and "实况" live tag; automatically collapses after 4 seconds into a floating "ⓘ" button, expandable on tap; tapping the strip opens a metadata details bottom sheet displaying complete properties (title, dimensions, format, size, duration, path, source URL); completely hides the strip and "ⓘ" when zoomed in (scale > 1.0); displays exact file metrics for local items, and lazily fetches single-page remote sizes with an "预计" (estimated) label without blocking or erroring.

- 终结并发原生任务与过期完成文件采纳（build 74）：彻底修复多轮次原生任务同时写入同一临时文件导致文件损坏与重复从 0 下载的问题；移除下载中网络切换强制打断重续的旧规则，网络切换对运行中任务仅保持观察（`network_change action=observe`），避免网络震荡时引发多轮次并发请求；新一轮任务发起前强制等待旧任务到达终态（最多 10 秒超时），超时则安全挂起（`round_blocked`）并提示用户手动继续；针对 Android 14+ UIDT 运行中任务在特定场景下取消失效产生的僵尸任务，增加监测与二次强制取消（`zombie_task`）；过期旧轮次完成上报（`stale_update complete`）不再盲目丢弃，当文件大小与类型校验完全合格时直接安全采纳并入相册（`adopt_stale_complete`），取消多余的后续轮次；启动与批次对账时全面扫描并清理孤立成品与临时残留（`temp_sweep`）；预检与写入空间不足时卡片与队列明确提示「空间不足 · 需 <x>GB，可用 <y>GB」与「清理后继续」按钮，严禁误显为「已暂停」；开发者选项断网不自动续传开关增加构建期常量配置（`kDefaultManualResumeOnlyOnDisconnect = false`）。
  Single native task enforcement and valid stale completion adoption (build 74): resolves an issue where multiple native task rounds concurrently wrote to the same temporary file causing file corruption and fallback to downloading from 0; removes the legacy rule of interrupting and resuming on mid-flight network switches, keeping running tasks untouched while observing (`network_change action=observe`) to avoid racing rounds during network handoffs; strictly blocks launching new rounds until previous round native tasks reach terminal state within a 10s wait window (`round_blocked`); detects and re-cancels zombie tasks (`zombie_task`) caused by Android 14+ UIDT running job cancellation anomalies; stale completion updates are verified against expected size and MIME type and adopted directly into the gallery (`adopt_stale_complete`) while canceling redundant in-flight rounds; orphaned artifacts and stale temp files are cleanly swept during startup and reconciliation (`temp_sweep`); storage shortage explicitly displays "空间不足 · 需 <x>GB，可用 <y>GB" with a "清理后继续" action button across cards and download queue rather than "已暂停"; adds a compile-time default constant for the manual resume disconnect fallback switch (`kDefaultManualResumeOnlyOnDisconnect = false`).

- 断网续传内部中断保护与状态收敛（build 73）：彻底修复 App 内部取消误当用户取消导致删除已下载数据的问题；严格限定仅用户在 UI 上的主动取消与删除操作才允许丢弃临时文件并设置 `userCancelRequested`，插件上报的 canceled 状态一律视为内部中断并保留已有数据进入「下载中断」；增加续传并发在途互斥守卫（`_inFlightResumes`），避免 auto_resume 与网络恢复同时触发导致并发重复 206 续传；续传起点取落盘实际大小与记录中的最大者并同步更新，消除落后回退与原生截断；修复多引擎场景下 `NetworkStatusChannel` 监听被意外解绑的问题；卡片与队列在断网后即刻显示「下载中断 · 等待网络」，自动重试显示「自动重试 n/5」，耗尽显示「已中断，点继续」；开发者选项新增「断网不自动续传」回退开关。
  Resumable download internal interruption protection and status refinement (build 73): resolves an issue where internal cancellations were treated as user cancellations resulting in downloaded data being deleted; restricts temporary file deletion strictly to explicit user-initiated actions (`userCancelRequested`), treating any plugin-reported canceled state as an internal interruption that preserves partial files and enters "下载中断"; adds an in-flight resume mutex guard (`_inFlightResumes`) to prevent duplicate concurrent 206 resume requests from simultaneous auto-resume and network recovery events; sets the resume start byte to the larger of actual on-disk size and stored metadata while preventing native file truncation; fixes an issue in `NetworkStatusChannel` where engine detachment prematurely unregistered system network callbacks for the main app; immediately displays "下载中断 · 等待网络" on disconnect without percentages, "自动重试 n/5" during retries, and "已中断，点继续" upon exhaustion; adds an optional developer switch to pause at "已中断，点继续" on disconnect instead of auto-resuming.

- 批次活跃任务查询与结算解耦及自愈修复（build 72）：结算判断以 App 自身任务状态为准，当批次内所有项均已保存（`saved`/`done`）、已取消或已确认失败时，直接完成结算，绕过插件活跃任务扫描，彻底解决全记录扫描（`allRecords`）在真机超时导致批次被永久阻塞、历史记录停留在 0 文件的死锁问题；仅在存在未完成或失败项时针对当前轮次 taskId 执行单任务定向查询（单次超时 3 秒），连续 3 次超时后以 App 自身状态为准降级结算（`reason=native_query_unavailable`）；App 与悬浮球启动时自动扫描并对账修复既有「已全部保存但未完成结算」的受阻批次（`settle_repair`），补全历史文件行并恢复「最近保存」展示；删除确认弹窗与提示中避免出现「0 项」文案。
  Decoupled batch active query and settlement with self-healing repairs (build 72): settlement decisions now prioritize the App's own task states, immediately concluding settlement and bypassing full-table plugin scans (`allRecords`) once all batch items are saved (`saved`/`done`), canceled, or confirmed failed, eliminating a deadlock on real devices where active query timeouts permanently blocked settlement and froze records at 0 files; queries are restricted to unconfirmed taskIds during failures with a 3-second per-task timeout and fallback to App state after 3 consecutive timeouts (`reason=native_query_unavailable`); automatically reconciles and repairs previously stuck batches upon startup across main and bubble engines (`settle_repair`), populating missing history file rows and restoring recent saved records; deletes without files no longer display misleading "0 项" texts.

- 小红书域名备选切换收敛：单次解析中主备域名切换严格限制至多 1 次，避免未登录或重定向时在 `xiaohongshu.com` 与 `rednote.com` 之间反复循环；检测到重定向至 `/explore` 或 `/login` 等页面时立即停止切换与冗余重试，交由解析器返回 `LOGIN_REQUIRED`。
  Bounded Xiaohongshu domain switching: switching between primary and alternate domains is capped at at most 1 time per parse session, preventing ping-pong loops between `xiaohongshu.com` and `rednote.com`; detects redirects to `/explore` or `/login` to halt retries immediately and let the parser return `LOGIN_REQUIRED`.
- 统一错误文案与原始异常屏蔽：所有错误卡片、Toast、系统通知以及悬浮球错误提示全面屏蔽 `FormatException`、`Bad state`、`PlatformException` 等原始异常类名与堆栈，统一映射为用户友好的可读文案；原始异常仅保留在调试日志与脱敏诊断信息中。对小红书、Instagram、X 等已知需要登录的站点，若未登录且遇到无法归类的错误时，除「重试」外额外提供「去登录」入口。
  Unified error messages and raw exception masking: error cards, toasts, system notifications, and bubble error states now sanitize raw exception class names and stack traces (e.g. `FormatException`, `Bad state`, `PlatformException`) into friendly, readable text, reserving raw details for logs and sanitized diagnostics. Known sites requiring login (Xiaohongshu, Instagram, X) now provide a "去登录" (Sign in) action alongside "重试" (Retry) on unclassified errors when signed out.
- TikTok 地区限制文案优化：遇到 `REGION_RESTRICTED` 错误时，文案明确提示「该内容在你所在的地区不可用（平台限制），登录也无法查看」，保留「打开原链接」按钮且不显示无意义的「去登录」。
  TikTok region restriction copy improvement: `REGION_RESTRICTED` errors now state that content is unavailable in the current region due to platform restrictions, retaining "打开原链接" without offering an ineffective login action.
- 悬浮球后台引擎冷启动加速：优化启动恢复逻辑，已结算且已写入历史的终态批次跳过重复的 `_afterTerminal` 收尾；通知取消仅针对当前会话活跃的通知并支持批量处理；批次对账（reconcile）在后台异步完成，不阻塞新任务入队开始，启动耗时由 4–8 秒缩短至 1 秒以内。
  Bubble background engine startup acceleration: settled batches with history already written now bypass redundant `_afterTerminal` teardowns; notification cancellations only target active notifications from the current session and support batch cancellation; reconciliation runs asynchronously in the background without blocking new batch enqueuing, cutting cold start time from 4–8 seconds to under 1 second.
- 大文件断点续传（≥5MB）：大文件（主要是视频）在连接中断、等待网络或 App 重启后，自动从已有字节断点续传，无需从头重下。后台下载器复用 `background_downloader` 暂停/续传能力（build 64/65/66/67/68/69 彻底解决后台下载器续传、结算与双引擎生命周期问题：解决 CDN 响应头大小写敏感导致 `serverAcceptsRanges` 与 `Content-Range` 解析失败的问题，避免网络中断时误删临时文件，支持 `allowPause` 任务的断点保留与原生未投递数据同步；修通「暂停 → 继续」与「断网 → 恢复」全链路；根治断网恢复时活跃任务因重试耗尽导致的 0 文件提前结算，确立 `active_native` 互斥守卫与对账保护；关闭插件内部无 Range 重试并引入断点单调防退化与覆盖告警；确立双引擎单一所有权，已结算批次禁止重复接管，悬浮球与主程序接管后实时同步终态；收尾阶段细分为「写入来源信息」与「复制到相册」两阶段并全端联动展示；实况图删除全链路统一格式并严格校验底层物理文件数；引入收尾阶段锁（`isFinishing`）与相册回查机制，防止文件入库与取消/断网产生并发竞态；无 ETag 资源校验 `Content-Range` 总大小一致性并在不一致时安全重下；多次网络中断保证起始字节单调不减；建立临时文件与续传数据全生命周期管理，任务取消、删除或终态失败时彻底清理，启动时自动对账清理孤立临时文件；严格依据复制入库双倍峰值计算可用空间并在不足时安全暂停保留断点）；build 70 确立断点续传终版收敛与兜底规则：凡部分临时文件字节数 $> 0$ 的任务，任何异常绝不判定终态失败与删除临时文件，统一转入「下载中断」并支持 5 次指数退避自愈（耗尽提示「已中断，点继续」）；临时文件删除严格受限于服务器不支持 Range、大小不符或用户主动取消；引入网络恢复 3 秒稳定窗口与切换即刻断点续传机制；App 内直接下载（如 TikTok 会话传输）实现 `Range` 续传并通过 `If-Range`（ETag 或 Last-Modified）校验；在 Dart `MediaRequestPolicy` 与 Android 原生两处同步加入 `If-Range` 白名单与合法格式校验。
  Resumable downloads for large files (≥5MB): large files (mainly videos) now automatically resume from existing bytes upon connection drop, network reconnection, or app restart without starting over. The background downloader leverages `background_downloader` pause/resume capabilities (build 64-69 comprehensively addressed resume, settlement, and dual-engine lifecycle edge cases: case-insensitive CDN header handling for `Accept-Ranges`/`Content-Range`, preventing accidental tempfile deletions on disconnect, full 'pause -> resume' and 'disconnect -> reconnect' paths, fixing premature 0-file settlement by adding `active_native` mutex guards and reconcile corrections, disabling plugin un-ranged internal retries with monotonic start byte protection, enforcing single ownership across main and bubble engines with graceful adoption, refining the finishing stage into 'writing provenance' and 'copying to album' with synchronized UI feedback, unifying live photo deletion counts across all entrypoints matching underlying MediaStore files, adding finishing-stage locks (`isFinishing`) and gallery verification against race conditions, ensuring start byte monotonicity across multiple drops, and managing tempfile lifetimes with double-peak storage preflight checks); build 70 solidifies final fallback and self-healing convergence: any task with partial bytes $> 0$ never marks final failure or deletes partial files on error, entering "下载中断" with 5-retry exponential backoff (transitioning to "已中断，点继续" on exhaustion); restricts tempfile deletion strictly to 200 without Range, size mismatch, or user cancellation; introduces a 3s network recovery stability window and instant mid-flight network switch recovery; in-app direct downloads (e.g. TikTok sessions) implement `Range` resume with `If-Range` verification; and `If-Range` headers are whitelisted across Dart and Android native layers.
- 悬浮球跨引擎进度实时同步与持久化补全：解决悬浮球下载批次在主程序历史与下载列表中显示为 0% 的问题（补充 `DownloadJob` 序列化与反序列化时缺失的 `progress` 字段，并在拥有批次的引擎中按 1s 或 1% 增量节流写入 `SharedPreferences`，主程序只读呈现跨引擎实时进度且不发生越权接管）。
  Bubble cross-engine progress real-time sync and persistence completion: fixes bubble download batches showing 0% progress in the main app history and queue (adds missing `progress` field to `DownloadJob` serialization/deserialization, throttles writes to `SharedPreferences` at 1s or 1% intervals from the owning engine, and enables the main app to display live progress as a foreign observer without unauthorized takeover).
- 悬浮球轮次判定修复与已入库状态防二次处理：修复悬浮球「全部下载」或「选择下载」多图时任务卡在「正在保存到相册」且原生进度被误判为过期（`stale_update`）的问题（轮次判定改为仅比较轮次编号 `-rN`，重试后缀 `-tryN` 不参与过期判定；`reloadBatchSnapshot` 增加属主保护，禁止磁盘旧快照覆盖内存活跃批次实例；全链路校验已入库状态，已完成项记录 `finish_skipped reason=already_saved` 并安全跳过，绝不重复调用 `finishFile`；收尾阶段临时文件不存在但已有相册/历史记录的按成功处理，不再报错「文件丢失，请重试」；修正 watchdog 延迟计算时序，确保 `watchdog_delay_ms` 准确反映真实差值且绝不为 0ms）。
  Bubble round-based update matching and duplicate finish prevention: resolves an issue where bubble multi-image downloads stalled in "正在保存到相册" with task updates dropped as `stale_update` (matches updates strictly by round number `-rN` ignoring retry suffix `-tryN`; guards `reloadBatchSnapshot` against clobbering live in-memory batches; enforces `finish_skipped reason=already_saved` across watchdog, reconciliation, retries, and normal completion to prevent duplicate `finishFile` calls; treats missing temp files as successful if already recorded in album/history without reporting "文件丢失"; corrects watchdog delay calculation timing to reflect true elapsed duration).
- 历史卡片紧凑下载进度条与交互优化：下载中的卡片进度遮罩由原先全卡片覆盖改为底部半透明紧凑横条（固定高度 44dp），卡片上部的封面、视频时长、多图数量与平台标签完全可见；横条左侧显示 24dp 进度指示器、状态文案与进入队列箭头（点击进入下载队列），右侧提供独立的暂停/继续按钮（触摸区域 $\ge 40\times 40\text{dp}$，点击瞬间同帧翻转暂停/继续状态图标并展示微型加载角标）；点击卡片主体（封面、标题、平台标签）任何状态均直接进入大图预览，不再重定向至下载队列；将视频时长角标调整至右上角并与多图数量合并，彻底消除与左侧平台图标的重叠；下载完成进入入库阶段时卡片底栏与队列明确显示「正在保存到相册」，消除 100% 停滞感；卡片宽度小于 130dp 时自适应紧凑布局，取消操作统一收归至下载队列页面及卡片长按菜单（附带二次确认弹窗）。
  Compact history card download progress bar and interaction improvements: the in-progress download overlay is redesigned from a full-card blocking veil into a compact bottom semi-transparent bar (fixed height 44dp), keeping upper covers, video durations, item counts, and platform badges fully visible; displays a 24dp progress indicator, status label, and chevron on the left (tap navigates to download queue), and an independent pause/resume button on the right ($\ge 40\times 40\text{dp}$ touch target with instant same-frame icon flip and micro-spinner feedback); tapping the upper card body (cover, title, platform) directly opens fullscreen preview in any state without redirecting to the download queue; video duration badges are repositioned to the top-right grouped with multi-item counts, completely eliminating overlap with the top-left platform badge; in-progress overlay explicitly shows "正在保存到相册" during file import, removing perceived freezing at 100%; automatically adapts on cards narrower than 130dp, and unifies cancellation into the download queue page and card long-press menu with confirmation dialog.
- 全屏大图浏览多选批量删除：大图浏览页多选批量删除整合为单次 App 确认弹窗（「删除 N 项？」）及单次系统相册媒体删除授权请求；用户在系统对话框取消删除时提示「已取消删除」且不删除任何本地或相册记录；部分媒体删除失败时明确提示成功与失败项数；删除完成后平滑停留在相邻媒体项，全部删除自动退出浏览页；历史页删除帖子确认弹窗的项数计算对齐（实况照片合并按 1 项计数）。
  Fullscreen viewer batch multi-selection deletion: batch deletion in the fullscreen viewer is unified into a single confirmation dialog ("删除 N 项？") and a single system MediaStore permission request for all selected media; canceling the system request leaves all records intact with an "已取消删除" toast, and partial album deletion failures report specific succeeded and failed counts while keeping the database synchronized; smoothly navigates to adjacent media upon deletion, exiting to history if all items are removed; history page post deletion confirmation count is aligned to count items (Live photo counts as 1 item).

### 解析器 / Parser

- parser 1.4.17（`manifestVersion` 14，只走解析器通道，不随 App 版本发布）：已登录但会话失效时不再一律报「该帖子不存在、私密或已删除」。小红书与 Instagram 各自区分两类页面信号——平台自己的「内容不存在 / 无法查看」提示仍按原样回答 `PRIVATE_OR_UNAVAILABLE`；而登录表单、登录提示或跳转到登录页说明是会话失效，回答 `LOGIN_REQUIRED` 并显示「登录可能已失效，请重新登录」，用户可以直接去登录后重新解析。两类信号都读不到时保持 1.4.16 的原有答案。没有新增错误码，仍在用旧版 App 的设备看到的是同一个 `LOGIN_REQUIRED` 与「去登录」按钮，提示文案用解析器给的这一句。
  Parser 1.4.17 (`manifestVersion` 14, parser channel only — no App release): a signed-in device whose session has expired is no longer always told 该帖子不存在、私密或已删除. Xiaohongshu and Instagram now tell two kinds of page signal apart — the platform's own 内容不存在 / 无法查看 notice keeps answering `PRIVATE_OR_UNAVAILABLE`, while a login form, a login prompt or a redirect to the login page means the session is gone, which answers `LOGIN_REQUIRED` with 登录可能已失效，请重新登录 so the user can sign in and parse again. When neither signal is readable the pre-1.4.16 answer stands. No error code was added: an older App sees the same `LOGIN_REQUIRED` and its 去登录 button, showing the engine's own sentence.
- 小红书帖子链接被重定向回首页（`/explore`）或登录页时，解析器不再把它当普通失败：App 未登录时回答 `LOGIN_REQUIRED` 并提示先登录，App 认为已登录时按会话失效提示重新登录。同时所有钩子在任何页面状态下都返回 App 能识别的结构——文档正在被替换、模块无法判断时返回 `INVALID_PAGE` 等已有错误码，不再抛异常，界面不会再出现 `FormatException: Invalid parser hook result` 这类原始异常文案与非登录的「重试」。
  When a Xiaohongshu note link is redirected back to the home feed (`/explore`) or to the login page, the parser no longer treats it as an ordinary failure: a signed-out App gets `LOGIN_REQUIRED` with the sign-in prompt, and an App that believes it is signed in gets the expired-session prompt. Every hook now also answers a shape the App recognises in any page state — a document being replaced, or a module that cannot tell, answers an existing code such as `INVALID_PAGE` instead of throwing, so raw text such as `FormatException: Invalid parser hook result` with a bare 重试 can no longer reach the screen.
- 小红书图片（含实况的静态图）由解析器直接给出 `imageView2/format/jpg/q/100` 的全质量 JPEG 候选，排在其他 JPEG 候选与原图之前；服务端只转 `format/jpg` 会重编码到约四分之一体积，`/q/100` 才回到原图大小与分辨率。视频候选与其他平台不变。v1.11.0 已在派生后按最终 URL 去重，v1.10.3 会因候选集里已有同一地址的 JPEG 转码而不再派生，v1.10.2 本就不派生——三个版本的候选列表、排序与请求策略均已验证，同一地址不会被请求两次。
  Xiaohongshu stills (including a Live photo's still) now carry the CDN's full-quality JPEG transcode `imageView2/format/jpg/q/100` from the parser itself, ahead of every other JPEG candidate and of the stored original: `format/jpg` alone re-encodes down to about a quarter of the bytes, and only `/q/100` comes back to the original size and resolution. Video candidates and other platforms are unchanged. v1.11.0 already deduplicates by final URL after derivation, v1.10.3 stops deriving because the candidate set already holds a JPEG transcode of that address, and v1.10.2 never derived — candidate lists, ordering and the request policy were verified on all three, so no address is requested twice.

## [1.11.0] - 2026-11-16

### 新增 / Added

- 历史页瀑布流（帖子与全部两种模式）改为懒加载：只为可见区域附近的卡片构建卡片并请求本机缩略图，卡片高度由封面宽高比直接算出，不再为测量高度而构建屏幕外的子项。平衡布局规则（左列不短于右列、打平放左、布局确定）与「全部」的错位网格顺序均不变。
  Both history waterfalls (帖子 and 全部) are now lazy: only cards near the viewport are built and ask for a local thumbnail, and a card's height comes from its cover's aspect ratio instead of building off-screen cards to measure them. The balanced rules (left column never the shorter one, ties to the left, deterministic) and the 全部 staggered order are unchanged.
- 无网络时开始下载会提示「当前无网络，联网后自动开始」，任务照常排队；等待期间卡片、下载面板与通知显示「等待网络…联网后自动继续」并保留「取消」，联网后自动继续。等待网络不算失败，不生成失败快照；网络状态只用于显示，不改变下载器的排队与重试逻辑。
  Starting a download without a connection now says 当前无网络，联网后自动开始 while the batch is queued as usual; while it waits, the card, the panel and the notification say 等待网络…联网后自动继续 and keep 取消 available, and it continues by itself once the connection is back. Waiting for the network is not a failure and takes no snapshot; the connection state is display-only and never changes queuing or retry behaviour.
- 历史页「创作者」模式右上角新增排序菜单：帖子数、最近保存时间、名称，每种可升序或降序；默认「最近保存」降序，选择会记住。排序只在已加载的分组数据上做内存排序，不额外查询数据库。名称排序规则固定：忽略大小写、未知作者排最后、数字按数值（`2` 在 `10` 前）、其后依次为拉丁字母、中日韩字符（按 Unicode 码位）、其他符号与 emoji；同值时按最近保存降序。
  The history page's 创作者 view has its own sort menu: post count, latest save time and name, each ascending or descending, defaulting to latest-save descending and remembered across launches. Ordering is an in-memory sort over the groups already loaded, with no extra database query. Names follow a fixed rule: case-insensitive, unknown authors last, digits compared as numbers (`2` before `10`), then Latin, then CJK by code point, then symbols and emoji; ties fall back to newest save.
- 帖子模式瀑布流改为平衡布局：每张卡片放进当前较矮的一列，两列高度差不超过 8dp 视为打平并放左列；分组结束时若右列更长则整组左右对调，保证左列不短于右列。放置只由卡片高度决定，滚动或刷新不会重排已经显示的卡片。
  The 帖子 waterfall now uses a balanced layout: each card goes into the shorter column, a difference of at most 8dp counts as a tie and goes left, and a group that would end with the right column taller is mirrored so the left column is never the shorter one. Placement depends only on card heights, so scrolling or refreshing never reshuffles cards already on screen.
- 备份会记录外部文件夹自动备份的开关与文件夹显示名（不含授权本身）。恢复这类备份后会询问是否继续自动备份到该文件夹，确认后由系统文件夹选择器重新授权，授权成功才开启；旧备份照常恢复、不弹提示。
  Backups now record the automatic folder-backup switch and the folder's display name (never the grant itself). Restoring such a backup asks whether to keep backing up to that folder; the system folder picker re-authorises it and only a successful pick switches it on. Older backups restore as before, without a prompt.
- 某次下载批次出现失败时，自动把该批次前 200 行到结束的日志另存为脱敏快照（App 私有目录，最多 10 份）；「我的 → 日志」新增「下载失败日志」，可查看与导出这些快照。
  A download batch that ends with failures now saves a redacted snapshot of the log around it (200 lines before the batch through its end, app private directory, at most 10 files). 「我的 → 日志」 gains 「下载失败日志」 to view and export them.
- 浏览页闭环（v1.11 第二批）：帖子的每个媒体项区分「在本机 / 不在本机 / 已删除」三种状态。不再在本机的项在本地浏览器里显示裂图占位 + 「不在本机」+「重新下载这张」，帖子底部给出「重新下载缺失的 N 张」一次重下全部缺失项；顶部计数改为「原始位置 / 原始总数」（如 3/8），全部缺失的帖子也能进入浏览页并提示「未找到可查看的媒体文件」。重新下载会重新解析原帖、打开预览选择页并只预选缺失项（Live 整对重下）；原帖已删除、需要登录或已没有这些项时明确提示且不改动记录。浏览页还支持「删除这张」：默认仅删除记录并可撤销，或同时删除相册文件（走系统确认、不可撤销），删光后询问是否删除整个帖子记录。
  Closing the browsing loop (v1.11 second batch): every media item of a post is now in one of three states — in the album, not on this device, or deleted in the app. An item that is no longer on the device shows a broken-file placeholder with 不在本机 and its own 重新下载这张 in the local browser, the bottom bar offers 重新下载缺失的 N 张 for all of them, the top counter reads original position over the post's original total (e.g. 3/8), and a post whose items are all gone still opens, with 未找到可查看的媒体文件 as a notice. Re-downloading parses the post again, opens the preview selection with only the missing items ticked (a Live photo is re-downloaded as a pair) and says plainly when the post is gone, needs a login or no longer holds those items, without touching the record. The viewer can also delete a single item: record only (default, undoable) or together with the album file (system confirmation, not undoable), and it asks whether to drop the post record once nothing is left.
- 备份 v2 增加每个文件的在本机状态（在本机 / 不在本机 / 已删除）：恢复后已删除的项仍为已删除，不会被当作缺失，也不会被计入「会恢复的文件数」；旧备份没有该字段时按原行为处理。
  A schema-v2 backup now records the on-device state of every file (in the album, missing, or deleted in the app): after a restore a deleted item is still deleted — never counted as missing and never promised by the restore preview — and a backup written before the field existed restores exactly as it used to.

### 修复 / Fixed

- 下载进度与结果一律按「项」计数，不再按「文件」：实况的静态图与视频合计为 1 项，悬浮球、通知栏标题、App 内下载面板、下载队列与完成/失败提示显示的都是「选了 8 项」而不是「11 个文件」（此前 11 项的帖子选了 8 项、其中 3 项是实况，悬浮球显示 x/11，看起来像选错了）。一项只有在它的所有文件都保存成功后才算完成，实况任一半失败，该项计为失败（「N 项失败」）。日志仍按文件计数，并同时给出 `items=`。
  Every download number now counts items instead of files: a Live photo's still and motion clip are one item, so the floating bubble, the notification title, the in-app panel, the download queue and the completion / failure prompts all read 8 items selected rather than 11 files (an 11-item post with 8 items selected, three of them Live photos, used to show x/11 on the bubble and looked like the wrong items had been picked). An item only counts as done once all of its files are in the album, and one failed half fails the item (N 项失败). The log keeps counting files and adds `items=` beside them.
- 同一媒体地址只尝试一次：候选地址在派生与排序之后按最终 URL 去重。解析器接下来会自己给出 `imageView2/format/jpg/q/100` 的 JPEG 原图候选，而 App 也会从同一地址派生它——现在两者无论哪一侧先给出，一项都不会为同一份字节花掉两次尝试。
  The same media address is now tried once: candidates are deduplicated by their final URL after derivation and ranking. The parser release that follows hands out the `imageView2/format/jpg/q/100` JPEG original itself, while the App derives the same candidate from the same address — whichever side delivers it, an item never spends two attempts on the same bytes.
- 修复多图帖子下载被判为「开始下载失败」的回归：上一版给「开始批次」加了 10 秒截止时间，而开始批次要对每个文件做一次存储预检，耗时随文件数增长，于是 8 张以上的帖子必然超时——用户看到「开始下载失败，请重试」和「全部已在本地」，悬浮球还不显示 x/N，而批次其实仍在下载。现在批次一旦进入队列就算「已开始」：立即发出开始与进度、悬浮球从第一个文件起显示 x/N，其余预检在后台继续；截止时间只留给本应很快的步骤（读设置、网络状态、解析器与下载器初始化），超时一律按安全默认值继续，不会报失败、不会写空记录、也不会停止进度上报。
  Fixed a multi-image post being reported as 开始下载失败: a fixed 10-second deadline sat on starting a batch, while starting one does a storage precheck per file, so a post with 8 or more images always timed out — the user was told 开始下载失败，请重试 and then 全部已在本地, the bubble showed no x/N, and the batch kept downloading anyway. A batch now counts as started the moment it is queued: the start and its progress go out at once, the bubble counts from the first file, and the remaining prechecks continue in the background; deadlines are kept only for steps that should be quick (settings, connection state, parser and downloader start) and a timeout there continues on safe defaults without reporting a failure, writing an empty record or stopping progress.
- 首页「最近保存」不再显示「0 个文件」：下载开始时会先写一条没有文件的占位记录，首页照原样把它渲染成「0 个文件」；首页现在只列出至少保存了一个文件的帖子，历史页仍保留下载中的占位与失败记录。
  最近保存 no longer shows 0 个文件: a download writes a file-less placeholder as soon as it starts and the home list rendered that as 0 个文件; the home list now lists only posts with at least one saved file, while the history page keeps the in-progress placeholder and a failed post with its retry.
- 预览页实况长按更跟手：全屏大图停留约 0.5 秒后就预加载当前这张的动态视频，长按时立即开始；尚未就绪时 LIVE 角标显示加载指示，就绪后仍在按住即开始播放，松手即取消，只预加载当前页、离开即释放。
  A live photo in the fullscreen viewer now plays without the wait: the motion clip of the photo in view is prepared after about 0.5 s of dwell, so a long press starts at once; if it is not ready yet, the LIVE badge shows a loading indicator and playback begins as soon as the clip arrives, still while holding — releasing cancels, only the current page is prepared, and leaving it releases the clip.
- 修复后台引擎空闲销毁后重建、悬浮球再次提交时任务停在「准备中」不动的问题：原先前台与后台两个引擎各自手写要注册的原生通道，重建后的引擎可能在通道或插件上停在一次永不返回的等待里，而提交路径上没有任何一步有超时或日志。现在两个引擎都通过同一处注册全部共用通道（连通性回调也会随引擎重建重新挂载），提交路径的每一步（收到 → 读取设置 → 网络状态 → 解析器与下载器初始化 → 解析 → 批次开始）都有日志与截止时间，超时后按安全默认值继续（网络状态未知按在线处理，设置读不到就用默认值），失败也不再把整个任务卡死。
  Fixed a submitted task freezing on 准备中 after the background engine had been destroyed for being idle and rebuilt: the foreground and background engines each listed the native channels they registered by hand, so a rebuilt engine could end up waiting forever on a channel or plugin, and no step of the submit path had a deadline or a log line. Both engines now register the shared channels from one place (the connectivity callback is re-attached with the engine), every step of the submit path — received, settings, network, parser and downloader start, parse, batch start — logs and has a deadline, a timeout continues on safe defaults (an unknown connection counts as online, unreadable settings fall back to the defaults), and a failed step no longer stops the whole task.
- 修复远程预览进入全屏大图后，实况图长按变成切换选中而不是播放动效的问题：多选状态下那层「点图片即选中」的透明层原先不透明，把按压整个抢走，长按被当成一次点击；实况图现在自己处理点击与长按（长按播放、多选时单击选中），普通图片与视频保持原有规则，预览宫格里长按选中不变。
  Fixed a live photo's long press toggling the selection instead of playing the clip in the remote preview's fullscreen viewer: the transparent 「a tap selects」 layer used while multi-select is active was opaque, took the whole press away from the picture and let the long press arrive as a tap; a live photo now handles both gestures itself (long press plays, a tap selects while selecting), ordinary stills and videos keep their existing rules, and long press in the preview grid still selects.
- 修复历史页滚动位置：三种模式各自记住自己的位置，切换回来时等目标列表有了高度再恢复（不再被压回顶部）；作者、平台、搜索词任何筛选变化与任何排序变化（含创作者模式的排序与升降序）都回到顶部，清除筛选回到无筛选时原来的位置；下拉刷新、后台新增或删除记录、从大图返回列表都保持当前第一张可见卡片不动；瀑布流与列表互换时让切换前第一张完整可见的帖子留在原位；任何超出列表范围的位置回到顶部而不是停在末尾。位置按「模式 + 筛选条件 + 排序」分别记录。
  Fixed the history page's scroll positions: each of the three modes remembers its own place and a switch restores it only once the target list has a height (it is no longer clamped back to the top); any change of author, platform or search, and any change of order (including 创作者 mode's own order and direction) starts at the top, while clearing a filter returns to where the unfiltered list was left; a pull-to-refresh, a background add or delete and returning from the viewer all keep the first visible card in place; switching 瀑布流 ↔ 列表 keeps the first fully visible post where it was; a position outside the list becomes the top instead of parking at the end. Positions are recorded per mode + filter + sort.

- 大图浏览页底部操作栏改为「有选中就作用于选中项」：无选中时重新下载 = 重新解析并默认全选，删除 = 删当前项，分享 = 分享当前项；有选中时重新下载只预选选中的项（原帖已没有的项给出提示），删除走同一个弹窗删掉全部选中项（仅删除记录可整批撤销），分享一次分享全部选中项并跳过「不在本机」的项（附提示）。三个图标在有选中时右上角只显示选中数量数字（不套红色圆盘）；「打开原帖」收进「更多」，此按钮为竖排三点、不再有圆盘底图，弹出的菜单文字小一号且右侧留白很小。底部的「重新下载这张」移除（「不在本机」占位页上的保留）。所有按钮统一 48dp 高、图标与文字垂直居中，既有的防溢出退让顺序与长按提示、无障碍标签不变。
  The fullscreen viewer's bottom bar is now selection-driven: with nothing selected 重新下载 re-parses the post with everything selected, 删除 deletes the page in view and 分享 shares it; with a selection 重新下载 preselects exactly what was chosen (saying which items the post no longer has), 删除 deletes the whole batch through the same one dialog (record-only deletions undo together) and 分享 shares every selected item at once, skipping the ones that are not on the device and saying how many. The three icons show the number of selected items as a bare number in the corner (no red disc); 打开原帖 moved into 更多, whose button is now a plain vertical ellipsis with no disc behind it and whose menu entries read a size smaller with only a little room left on the right, and 重新下载这张 left the bar (the one on the 不在本机 placeholder stays). Every button is 48 dp high with icon and text vertically centered, and the existing retreat order, tooltips and semantics labels are unchanged.
- 大图浏览页多选：右上角圆圈切换当前项并进入多选，多选状态下点图片切换选中，底部缩略图长按也能切换该项的选中（再次长按取消）；普通图片长按进入多选，实况图长按仍是播放动效、不会触发多选；顶部提供「全选」与「取消选择」。
  Multi-select in the viewer: the circle in the top right toggles the page in view and enters multi-select, a tap on the picture toggles the selection while selecting, and a long press on a bottom thumbnail ticks that item and a second long press unticks it. A still picture enters multi-select on a long press while a Live photo's long press still plays its motion clip and never selects, and 全选 / 取消选择 sit beside the circle.
- 大图浏览页顶部计数改为「本页位置 / 本页项数」与原帖索引并列，如「1 / 3」+ 半透明胶囊里的「2 / 8」：前者是当前项在本浏览页中的位置与本页项数（含「不在本机」占位，不含已删除与从未下载，删除即时收缩、撤销恢复），后者显示原帖位置与原帖总数，不受删除影响，只在重新解析成功时更新。两者始终同时显示（即使相同），数字与斜杠之间、两个索引之间都留了间隔，原帖索引不再带括号，而是套一个与操作按钮同色的半透明椭圆底图（与按钮圆盘一样用 12% 白）；原帖总数变少、某项原位置超出新总数时该胶囊显示「— / 新总数」，不再崩溃。
  The viewer's top counter now puts the page's place over this browser's item count beside the post's own index, e.g. 1 / 3 plus 2 / 8 in a translucent pill: the first is the page's place and the item count of this browser (placeholders included, deleted and never-downloaded items not), so a delete shrinks it at once and an undo restores it, while the second is the item's place and the post's total, untouched by deletes and only updated by a successful re-parse. Both are always shown, even when they agree, with a space around each slash and between the two numbers; the post's index has no brackets and sits in a translucent stadium pill tinted like the round action buttons (12% white). A post that came back shorter shows — / new total inside the pill instead of a stale place and never crashes.
- 大图浏览页底部操作栏改为纯图标（删除、打开原帖、分享、保存/下载、重新解析），每个图标都有长按提示与无障碍标签；缺失项按钮保留文字「补下缺失(N)」并只在有缺失时出现。「点右上角选择」提示在空间不足时自动隐藏，按钮按「先隐藏提示、再缩小间距、最后把次要图标收进「更多」」的顺序退让，任何宽度都不再溢出，分享/保存始终可见。
  The fullscreen viewer's bottom bar is now icons only (delete, open the post, share, save / download, re-parse), each with a long-press tooltip and a semantics label; the missing-items button keeps its words as 补下缺失(N) and appears only when something is missing. The 点右上角选择 hint hides itself when the width is short, and the buttons retreat in a fixed order — hide the hint, tighten the gaps, then fold the secondary icons into 更多 — so the bar never overflows and 分享 / 保存 stay visible.
- 修复无网络时 App 内直接下载（TikTok 等站点声明 `transport: session` 的会话内传输，以及需要登录会话的媒体）把断网当内容错误的问题：飞行模式下载 TikTok 视频时首条即 `reason=CONTENT`、批次以 0 文件结束并写出失败快照，恢复网络也不继续。现在连接类失败（无网络、DNS 失败、连接被拒、连接重置、超时、TLS 握手失败）单独归类，任务进入「等待网络」状态：界面显示「等待网络…联网后自动继续」，联网后自动继续；不计入失败、不写失败快照、不消耗重试次数。后台下载器路径在系统报告离线时同样进入该状态，最终放弃时记为 `NETWORK` 而不再是 `CONTENT`。
  Fixed the in-app download paths treating a missing connection as a content error (TikTok and any site declaring `transport: session`, plus media that needs a login session): a TikTok video in airplane mode failed on its first line as `reason=CONTENT`, ended the batch with 0 files, wrote a failure snapshot and never continued. Connectivity failures (no network, DNS, refused, reset, timeout, TLS handshake) are now classified on their own and the file waits: the UI says 等待网络…联网后自动继续 and it continues by itself once the connection is back, without counting as a failure, without a snapshot and without spending an attempt. The background path enters the same state when the system reports offline and reports `NETWORK` (never `CONTENT`) when it finally gives up.
- 修复下载前置检查 `preflight` 在网络不可达或探测失败时仍记 `result=ok`、只留下 `size=-1` 的问题：现在只有在真正读到大小且空间足够时才记 `result=ok`，否则记 `result=unknown` 并给出固定原因（`offline`、`session`、`timeout`、`status_NNN`、`no_length`、`no_range`）。
  Fixed the download preflight claiming `result=ok` while `size=-1` when the probe could not run or failed. `result=ok` now needs a size that was really read and room for it; otherwise the line says `result=unknown` with a fixed reason (`offline`, `session`, `timeout`, `status_NNN`, `no_length`, `no_range`).
- 修复「不在本机」被误判为「已删除」的问题：只有相册查询成功并确认文件不存在时才标记「不在本机」；查询超时、出错或没有相册权限都不改变状态。不在本机的记录不再被自动清理，文件重新出现（例如从回收站恢复）时自动回到「在本机」；从未下载过的项不显示，卡片的文件数只算在本机的项。
  Fixed 「不在本机」 being treated as a deletion: an item is only marked missing when the album query succeeded and confirmed the file is not there, and a timeout, an error or missing permission never changes a state. Missing records are no longer cleaned away and go back to in the album by themselves when the file reappears (e.g. restored from the trash); items that were never downloaded stay hidden and a card's file count only counts the items on the device.

- 修复真机上大量本机缩略图请求同时发出、成批超时的问题（真机日志中一次 625 条 `local_decode_failed`、在途请求峰值 416，而屏幕只有十几张卡片）：历史页瀑布流原先必须构建整个日期分组的全部卡片才能知道组高度，现在改为两列并排的懒加载列表，只构建视口附近的卡片，也就只为这些卡片请求缩略图。实测 200 个帖子的一组：初次构建 4 张卡片、快速滑动后 6 张，在途请求数与已构建卡片数相同。
  Fixed off-screen cards flooding the local thumbnail pipeline on real devices (625 `local_decode_failed` lines and an in-flight peak of 416 requests in one device log, while a dozen cards were on screen): a date group used to build every one of its cards just to learn its height, and now renders as two side-by-side lazy lists that build only the cards near the viewport — and only those ask for a thumbnail. Measured on a 200-post group: 4 cards built at first, 6 after a fast flick, with in-flight requests equal to the cards that exist.
- 修复真机上一条 `ThumbStat` 10 秒统计都没有输出的问题：原先在途请求清零就停掉计时器，而一次洪泛的请求全部在 5 秒超时、10 秒窗口还没到就先清零，统计随之丢失；现在一个突发结束时立即输出该窗口的统计并停止计时器，同时保留进行中的 10 秒统计。
  Fixed the missing `ThumbStat` 10 second summaries on real devices: the timer was cancelled as soon as nothing was in flight, and a flooded batch gave up at 5s — before the first 10s tick — so the summary never printed. A burst that ends now reports its window immediately and then stops the timer, while the periodic summary stays for work in flight.
- 修正 `queue_timeout` / `system_timeout` 的判定：改为按请求发出时已经在排队的请求数判断，请求洪泛时不会再出现 400+ 在途却整批判为 `system_timeout` 的情况；统计行同时给出该窗口的在途峰值 `max_inflight`。
  The `queue_timeout` / `system_timeout` split now looks at how many requests were already waiting when a request was issued, so a flood can no longer report 400+ in flight yet call every timeout `system_timeout`; the summary line also reports the window's in-flight peak as `max_inflight`.
- 下载失败日志的 `candidate=` 字段改为候选序号/候选总数，不再出现 `candidate=3/1`、`candidate=11/4`（此前分子是重试次数）；重试次数单独记为 `attempts=`。
  The `candidate=` field of the download log now shows candidate position over total candidates instead of the retry counter, so `candidate=3/1` and `candidate=11/4` can no longer appear; the retry count is logged separately as `attempts=`.

### 诊断 / Diagnostics

- 修复真机上一条 `[ModeSwitch]` 都没有输出的问题：这行原先要求「整个 App 在途的缩略图请求为 0」才输出，只要有一个别处的请求不返回或跨过切换，条件就永远不成立，再次切换还会把它静默丢弃。现在只等这一次切换自己发出的请求结束（并有 10 秒上限），每次切换都必然输出一行；超时或提前切换的以 `timed_out=1` / `superseded=1` 标注。`ThumbStat` 的在途口径不变。
  Fixed `[ModeSwitch]` never appearing at all on real devices: the line used to require that no thumbnail request anywhere in the app was in flight, so a single unrelated or long-lived request kept the condition false forever, and switching again dropped the probe silently. It now waits only for the requests its own switch issued (bounded by 10 seconds) and every switch reports exactly one line, marked `timed_out=1` or `superseded=1` when it did not settle; the `ThumbStat` in-flight accounting is unchanged.

- 本机缩略图请求新增「发出时已在排队的请求数」(`concurrent_at_issue`) 与统计窗口的在途峰值 (`max_inflight`)，用于区分「排队拥堵」和「系统调用不返回」；统计行在突发结束时立即补发一行，不再因为请求在 10 秒内全部结束而整段丢失。加载、超时与回退行为不变。
  Local thumbnail requests now record how many requests were already waiting when they were issued (`concurrent_at_issue`) and the window's in-flight peak (`max_inflight`), which separates queue congestion from a platform call that never answers; a burst that ends inside a window now reports that window instead of losing it. Loading, timeout and fallback behaviour is unchanged.
- 本机缩略图超时日志补充缩略图 key、等待时长、超时阈值、更早未返回的请求数及其最长等待和在途请求数，并区分「排队超时」与「系统调用超时」；每 10 秒输出一行统计（成功/超时/平均耗时/在途）。加载、超时与回退行为不变。
  Local thumbnail timeout logs now carry the thumbnail key, the wait, the timeout, how many older requests are still unresolved and for how long, and the in-flight count, and separate queue timeouts from system call timeouts; a one-line summary every 10 seconds reports successes, timeouts, average time and in-flight requests. Loading, timeout and fallback behaviour is unchanged.

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

### 修复 / Fixed （build 59）

- 悬浮球下载的帖子不在历史页的回归。历史页把本页删除过的帖子记住到了会话结束，后来同一帖子又下载回来（`restoreDeleted`），记录留在数据库和「最近保存」里，历史页却永远过滤掉；读取开始于删帖之前的另一次读取也会被永久屏蔽。现在只屏蔽读取开始前的删帖，删帖条目在它服务过一次读取后就清除，恢复后的帖子按本次保存时间排序，与「最近保存」一致出现在「今天」；后台引擎写入后回到前台的读取若与写入重叠，会补一次读取，所以三种模式都会显示新帖子。
  A post downloaded with the bubble never reached the history page. The page remembered every post it deleted in the session and filtered it out of every later read — so a post deleted once and then re-downloaded (restoreDeleted) stayed invisible in history while showing up in the database and 「最近保存」, exactly as 1.10.x used to. The page now suppresses only the reads that started before a delete committed, and drops a delete as soon as one read has passed it; a re-downloaded post is dated by this save and appears in 今天 just like 「最近保存」. A resume read that overlapped the other engine's write runs again once it finishes, so 帖子 / 全部 / 创作者 all show the new post.
- 删除确认对话框的「同时删除相册中的 N 个文件」、删除结果提示、历史页顶部统计、帖子卡片与列表行、创作者卡片「N 帖 · N 个文件」、排序「文件最多」、备份预览「媒体文件」与恢复结果「恢复文件 / 不在本机」都改为按项计数：实况的静态图与视频是 1 项，文案改用「项」。系统删除确认仍把整个相册中的文件一起删（实况两半一起删），内部逻辑与日志仍按文件，仅附带 items=。
  Every user-visible count now counts items instead of files: the delete sheet's 同时删除相册中的 N 项, the deletion result prompt, the history page's statistics, post cards and list rows, the 创作者 card's N 帖 · N 项, the 项最多 sort, the backup preview's 媒体项 and the restore summary's 恢复媒体 / 不在本机. A Live photo's still and clip are one item; the wording uses 项 throughout. The system deletion still removes every related file (both halves of a Live photo together); internal logic and logs keep counting files.

## [1.10.2] - 2026-11-12
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
