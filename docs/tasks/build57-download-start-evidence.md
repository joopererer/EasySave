# Build 57 证据：批次启动不再被判超时（v1.11 P0 回归）

版本 1.11.0+57，分支 `feature/v1.11`。修复 build 56 新增截止时间引入的回归，
并加上预览页实况的预加载。未合并、未推送、未打 tag。

## 1. 现象与真机日志（build 56）

| 帖子 | 日志 | 用户可见 |
| --- | --- | --- |
| 8 图 | `batch start` → 2 张已 gallery import done → `step=batch-start TIMEOUT after=10003ms -> safe default` → `step=batch-start gave up` → 其余 6 张继续导入 → `history write files=8` | 悬浮球不显示 x/N；「开始下载失败，请重试」；重试提示全部已在本地 |
| 9 图（mode=all） | `TIMEOUT after=10012ms` → gave up，其后 9 张全部导入成功 | 同上 |
| 2 图 | `step=batch-start ok 4381ms` | 正常 |
| 1 图 | `step=batch-start ok 217ms` | 正常 |

耗时随文件数增长，正好卡在 10 秒上下，这就是「2 图刚好通过、8/9 图必然超时」
的原因。

## 2. 根因（a）：`startBatch` 返回前等待了什么

`DownloadManager.startBatch` 只有在**所有文件都已加入下载队列**之后才返回，
其中每个文件都是一次独立的、耗时不等的步骤：

1. `DevDownloadFailure.refresh()`（SharedPreferences 读）。
2. `AppSettings.load()`（SharedPreferences 读）。
3. `planFiles`：为每个 item 计算候选 URL（纯内存，可忽略）。
4. `_reserve(batch, jobs)`：读 `liveBatches()` 快照、写 `DownloadClaims`
   （SharedPreferences 读 + 写各一次）。
5. `init()`：`FileDownloader().start()`、通知插件 `initialize` +
   `createNotificationChannel`、`_loadAndReconcile()`（见第 6 节）、
   `_resumeWaitingJobs()`。前三者都是原生往返。
6. `_writeHistoryWithRetry(writePlaceholderHistory)`：写占位历史记录
   （`files=0`，见第 5 节）。
7. **逐文件 `_enqueueAttempt`**，每个文件都要：
   - `_reserve`（再读一次批次快照 + 写 claim）；
   - `_storageBlocked` → `_probeContentLength`：一次**真实的网络 ranged
     GET**（默认 8 秒上限）拿 Content-Length，用来判断剩余空间是否够；
   - 已保存项的历史库查询；
   - `FileDownloader().enqueue`（原生往返，写入 WorkManager 队列）。

第 7 步是线性增长的那一项：8 张 ≈ 8 次网络预检 + 8 次原生入队。真机上单次
1 秒多，8–9 张就超过 10 秒，于是 build 56 的 `_step('batch-start')` 必然超时。
超时并没有取消批次（Dart 的 `.timeout` 只放弃等待），批次继续下载，这正是
「日志说 gave up，实际 8 张全部保存成功」的原因。

**结论**：`batch-start` 的耗时随工作量增长，属于「不得用固定截止时间判失败」
的一类。

## 3. 截止时间原则（b）

- 只有「本应很快」的步骤才带截止时间：读设置（`step=settings`）、网络状态
  （`step=network`）、解析器初始化（`step=parser-init`）、下载器初始化
  （`step=downloads-init`）。超时一律走安全默认值。
- 耗时随工作量增长的步骤没有固定截止时间：解析（`_parseTimeout` 120 秒，
  只作为死锁兜底，不作为失败判据）、开始批次、下载本身。
- 批次一**入队**即视为已开始：`DownloadManager.startBatch` 在把批次登记进
  `_batches`、jobs 进入 `queued` 之后立刻调用 `onBatchReady`，后台引擎在这个
  回调里发出 `DOWNLOAD started N files` + 悬浮球 `0/N`，并开始 `_awaitBatchAndNotify`
  的轮询；逐文件预检与入队在其后继续，与用户可见的进度无关。
- `_step` 的文档注释已写明这条规则，避免以后再把长步骤包进去。

## 4. 安全默认值路径的约束（c）

- 超时只写 `DevLog`（`step=... TIMEOUT after=... -> safe default`），不弹提示、
  不写历史、不停止进度上报。
- `.timeout` 不会取消底层 Future，所以「超时」之后真实结果仍然落地：例如
  `downloads-init` 超时，`init()` 仍在后台继续完成插件启动与 reconcile，
  之后的入队、进度、历史写入照常发生。
- 开始批次失败只在**队列登记之前**才算失败（无相册权限、已在下载中）。登记
  之后即使入队抛出异常，也只写
  `step=batch-start late failure ... (batch already queued)`，用户看到的仍是批次
  自己的真实结果。
- 因此没有任何路径会因为「超时 → 安全默认值」写出空记录或停止上报。

## 5. 「最近保存显示 0 个文件」的写入来源（d）

写入来源是 `writePlaceholderHistory`：批次一开始就写一条占位记录
（`files=[]`、`file_count=0`、`source=download-placeholder`），让帖子在下载
期间就出现在历史页（带进度）。历史页用进度覆盖层表示「下载中」，所以看起来
正常；首页「最近保存」直接渲染 `savedMediaEntryCount(record.savedFiles)`，
于是显示「0 个文件」。build 56 的 gave-up 路径让这条占位记录成了唯一的可见
记录，看起来就像「保存失败、0 个文件」。

修复：

- 新增 `recentSavedRecords()`（`lib/services/history_db.dart`）：首页「最近保存」
  只列**至少有一个已保存文件**的记录。占位记录、以及 0 文件的失败记录都不进
  首页；历史页仍保留占位（带进度）与失败记录（带失败原因与重试）。
- `parse_page` 的两个读取入口（`_readRecentList`、`_reloadRecent`）统一走这个
  过滤，并把两次查询合并成一次 `db.recent(limit: 30)`。
- 失败路径本身：开始批次失败发生在占位写入之前，因此不会留下 `files=0` 的
  可见记录；取消且无成功/失败仍由既有 `discardEmptyPlaceholder` 清理。

## 6. `step=downloads-init` 为什么在后台引擎要 4–8 秒（e，仅分析）

真机数值：4054 / 6648 / 6857 / 8305 ms。`DownloadManager.init()` 依次 await：

1. `FileDownloader().start()`：原生插件启动（WorkManager/队列服务 + 打开插件
   数据库），引擎重建后是冷启动，通常最慢的一次往返。
2. `_notifications.initialize(...)` + `createNotificationChannel(...)`：两次原生
   往返。
3. `_loadAndReconcile()`：
   - `prefs.reload()` + 读取批次索引（最多 10 份快照）；
   - 每份快照 `jsonDecode` + 归属判断；外来未结算批次还会调
     `_allTasksTerminal` → `FileDownloader().database.allRecords(group:)`，
     又是一次原生数据库查询；
   - 每个自有批次 `_reconcileBatch`：再调一次 `allRecords`，可能补做
     `_finishFile`（相册导入 + provenance + MediaStore）；批次已是终态时还会
     走 `_afterTerminal(recovered: true)`：**`_refreshNotification` →
     `_cancelNotification`（原生 `notifications.cancel`，被
     `historyStep('cancel-notification', timeout: 1s)` 限到 1 秒）** +
     SQLite 历史写入 + `_persist`（SharedPreferences 写）+
     `_forgetSupersededFailureBatches`（prefs 与快照文件）。
4. `_resumeWaitingJobs()`。

结论：耗时随**索引里保留的终态批次数**增长，而不是随当前任务增长。终态批次
每次都重新走 `_afterTerminal` 的尾巴，其中「每个批次一次 cancel-notification」
是最容易吃掉 1 秒的部分：4 份历史批次 × 每次最多 1 秒 ≈ 4 秒，与 4054 ms
吻合；插件冷启动再叠加就是 6–8 秒。

可以缩短的方向（本次不改动，按指示仅分析）：

1. 已结算（`settledBy != null`）或
   `historyWritten == true` 且通知已取消的终态批次直接跳过
   `_afterTerminal`，只保留幂等的快照清理。
2. `_cancelNotification` 只在「本引擎本次会话里显示过通知」时调用
   （`_lastShownPercent` 里有这个批次才有通知要取消），可省掉全部历史批次的
   原生往返。
3. 把 `init()` 里的 `_loadAndReconcile()` 改成不 await（recovery 不阻塞入队），
   或只在有未终态批次时才 await；本文改动后 `downloads-init` 的超时不影响任务，
   但缩短它仍能减少首次进度延迟。
4. `cancel-notification` 的 1 秒上限可降到 300 ms 左右，或在一次通道调用里
   批量取消。

以上任一项都需要单独的真机验证，本轮只记录。

## 7. 预览页实况：长按播放的等待感

- 全屏大图停留 500 ms（`kLiveMotionPreloadDelay`）后预加载**当前页**这张实况的
  动态视频；远程实况走 `networkPreviewController`（按请求策略抓取后本地播放），
  本地实况本就不慢，不预加载。
- 只有当前页预加载（`_BrowserItemView.isCurrentPage`）：PageView 会保留相邻页
  的状态，离开即 `_dropLiveClip()`，正在加载的结果到达后直接释放，因此不会
  同时预加载多张。
- 长按时若尚未就绪：LIVE 角标出现小 spinner（`kLiveMotionLoadingKey`），就绪后
  立即开始播放（仍在按住）；松手则取消（尚未就绪的加载做完后保留，下一次长按
  立即播放；正在播放的释放）。
- 宫格页、本地浏览页未改动：预加载只发生在 `type == 'live'` 且需要网络抓取时，
  宫格不构建 `_BrowserItemView`，本地实况保持原路径。

## 8. 测试与闸门

新增/更新：

- `test/v111_build57_batch_start_test.dart`：真实耗时模拟（10 个文件、每文件
  1.1 秒预检），断言 `DOWNLOAD started 10 files` 在预检完成前发出、悬浮球从
  `0/10` 起上报、无 `TIMEOUT` / `gave up` / 「开始下载失败」/错误页，完成提示为
  `下载完成：10/10 个文件`；另一条断言「登记之后入队抛异常」不会变成启动失败。
- `test/v111_build57_recent_saved_test.dart`：占位记录不进「最近保存」、
  终态写入的数量正确、全部失败的启动不产生可见的 0 文件记录。
- `test/v111_build57_live_preload_test.dart`：已预加载/未预加载两种长按行为、
  松手取消、离开页面释放预加载、不重复加载。
- `test/v111_batch3_background_engine_test.dart`：保留 build 56 的「引擎重建后
  再次提交」，并按新的 `onBatchReady` 接口更新测试桩。

闸门结果：

- `flutter test`：**1383 passed**（含 `media_request_policy_test`、全部 fixture
  与 node 驱动的兼容测试）。
- `gradlew testDebugUnitTest`：**BUILD SUCCESSFUL**，`:app:testDebugUnitTest`
  135 tests / 34 suites / 0 failures。
- `extension` 的 `npm test`：**290 Vitest + 33 build checks** 通过。
- `flutter analyze`：**0 error / 98 issues**，与基线数量一致。

## 9. APK

```
path    app/build/app/outputs/flutter-apk/app-release.apk
        (same file as app/build/app/outputs/flutter-apk/EasySave-1.11.0-build57-release.apk)
version 1.11.0 (versionName='1.11.0', versionCode='57'), package com.james.easysave
bytes   64,962,214
sha256  63d1ff451d20b4eddbb2f64bf7e38960341533198e02575c6b6bc67e927412d1
signer  CN=Jiawei LI … C=FR
        08d7da286f2a84251ddfa85d1a49dc1b1d6b3ffc59ab7d117d8db783b0633907
        (release key: installs in place over build 56)
parser  builtin 1.4.16 / manifestVersion 12, sha256 91434d22…7ddb
```

## 10. 真机验证步骤（待执行）

1. 用同一签名的 release APK 覆盖安装（不要卸载、不要清数据）。
2. 悬浮球「下载」一个 **8 张以上**的多图帖子：日志应是
   `DOWNLOAD started 8 files` → 悬浮球立即出现 `0/8` 并递增 → 结束
   `DOWNLOAD done: 8/8 in …s`，且**不得**出现 `step=batch-start TIMEOUT`、
   `gave up` 或「开始下载失败」。
3. 悬浮球「选择下载」再选 8 张以上：同上。
4. 等待 60 秒以上（日志出现 `Idle 60000ms reached`）让后台引擎销毁，再重复 2、3
   各一次（build 56 的通道修复必须仍然有效）。
5. 下载完成后看首页「最近保存」：应显示真实文件数，不再出现「0 个文件」；
   历史页条数与相册文件数一致。
6. 远程预览进入全屏大图，停在实况照片约 1 秒后长按：应立即播放；若在 500 ms
   内就长按，应先看到 LIVE 角标 spinner，随后在按住期间开始播放；松手停止。
   左右滑动到别的图再回来，确认不会同时加载两张。
7. `adb logcat` 观察 `[V16HOST] step=downloads-init ok …ms` 与
   `[HistoryTiming] step=cancel-notification ms=…`，记录本次数值用于第 6 节的
   优化评估。
