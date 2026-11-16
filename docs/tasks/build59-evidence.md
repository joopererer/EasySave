# Build 59 证据：历史页不显示悬浮球下载、用户可见的计数一律按「项」

版本 **1.11.0+59**，分支 `feature/v1.11`。未合并、未推送 master、未打 tag。
build 58 的真机回归（悬浮球全部下载/选择下载、引擎空闲销毁后再下载、「最近保存」文件数、实况预加载与长按、计数按项、候选去重）全部通过；本 build 做下面三项。

## 1. P0 回归：悬浮球下载的帖子不在历史页显示

### 真机现象（build 58）

悬浮球下载的帖子在首页「最近保存」可见，历史页没有；App 内下载正常。v1.10.x 时正常。日志：

- 后台引擎：`history write post=6af7c74e0000000014010400 files=10 restoreDeleted=true`；`notify … but no listeners attached`（后台引擎本身无监听，正常）。
- 回到主界面：`HistoryTiming step=recent rows=249 → rows=250`（主引擎读到了新记录，历史页却没显示）。
- 另一例：`post=6af9995b000000002b01e76e`（之前下载过又删除，本次 `restoreDeleted=true` 恢复）。

### 根因

主引擎在 `HistoryPageState` 里记录了本页会话内每一次删除：`_deletedRecordIds`（行 id）和 `_deletedPostKeys`（`platform:postId`）。之后每一次读取都用 `dropDeletedRecords` 把这些记录过滤掉，而且集合**永远不清空**。所以：

- 用户在历史页删了一条帖子，同一帖子又被悬浮球重新下载（`restoreDeleted = true`，记录恢复并可能沿用同一行 id）→ 过滤器里的 `platform:postId` 永远拦着它 → 历史页不显示，数据库和「最近保存」里却有，与 build 58 日志 `rows=250` 一致。
- 另外，`HistoryRefreshController.refresh` 用 `??=` 合并：当一次读取正在进行时，另一条刷新请求（如 resume 读取与后台引擎写入重叠）被丢弃，而不是排一次后续读取 → 刚好在写入发生时回到前台的页面，永远看不到那条新记录。

两者共同导致「主引擎已读到新记录，历史页未显示」。

### 修复（app/lib/pages/history_page.dart）

- 删除守候改为按时间生效：`_deletedRecordIds` / `_deletedPostKeys` 记录每条删除的提交时刻；`_suppressedIds(readStartedAt)` / `_suppressedPostKeys(readStartedAt)` 只拦截读取**开始前**的删除；读取完成后 `_forgetDeletionsBefore(readStartedAt)` 把已经服役的条目清掉，所以被恢复的帖子会重新出现。
- `HistoryRefreshController`（app/lib/services/history_io.dart）：刷新请求若在读取进行中到达，记录 `_queuedAgain`，读取完毕后再跑一次读取；突发请求合并为一次后续读取，不会变成多次读取。

### 数据时间的另一处修复（app/lib/services/history_db.dart）

用户发起的下载/重新下载把记录的时间设为**本次保存时间**（`userSave && (hasNewFiles || downloadStartedAt != null)`，恢复已删除记录同样取新时间），恢复后的帖子因此按本次保存时间排序，与「最近保存」一致，出现在「今天」分组；恢复、重建、备份恢复（`userSave: false`）以及纯关联本地文件（不带 `downloadStartedAt`）保持旧时间不变。

滚动保持规则不变（第一个可见项不跳动，锚点 `_captureAnchor`/`_scheduleScroll` 不动）。

### 测试

- `test/v111_build59_history_refresh_test.dart`：重新下载把旧记录移到今天；恢复被删除的记录按今天排在第一；读取进行中时再请求一次刷新不被丢弃；模拟后台引擎写入后 resume 重新读取，断言帖子 / 全部 / 创作者三种模式都显示新帖子；App 内保存（`HostBridge.historyRevision` 通知）让可见模式立即更新。
- `test/history_io_test.dart`：并发刷新不再全被合并为 1 次，而是 collapse 为 1 次后续读取（读取进行中到达的请求必须被再读一次，否则页面看不到后台写入的新记录）。
- `flutter test` 全量：1418 passed（含 `media_request_policy_test` 与全部 fixture）。

## 2. 用户可见的数量统一按「项」

### 真机现象（build 58）

删除对话框显示「11」，实际为 8 项（其中 3 项实况，共 11 个文件）。

### 修复

新增 `services/media_delete_service.dart`：`savedItemCountFor`（按条目，实况一对为 1）、`deletableItemCountFor`（请求命名的文件里属于多少个条目）。`savedFileCountFor` 只留给内部逻辑和日志，不再出现在用户看到的文案。

改到「项」的用户可见位置（改前 → 改后）：

- 删除确认对话框：`同时删除相册中的 ${savedFileCount} 个文件` → `同时删除相册中的 ${savedItemCount} 项`（实况两半仍一起被系统删除，只数一次）。
- 删除结果提示：`已删除 N 条记录，并删除 M 个相册文件` → `已删除 N 条记录，并从相册删除 deletableItemCountFor(...) 项`；找不到相册文件的提示里的文件数 → 项数。
- 历史页顶部统计：`${filtered.length} 个帖子 · $fileCount 个文件` → `${filtered.length} 个帖子 · $itemCount 项`；系统删除失败的提示不再带文件数（`部分相册文件未能删除`）。
- 帖子卡片：`$fileCount 个文件 · 时间` → `$itemCount 项 · 时间`（水流与列表）；`按类型`排序名 `文件最多` → `项最多`，且按条目排序。
- 创作者卡片：`$postCount 帖 · $fileCount 个文件` → `$postCount 帖 · $itemCount 项`（计数已改为条目，并注明）。
- 解析页「最近保存」行：`… · ${savedMediaEntryCount(...)} 个文件` → `… 项`；开始下载提示 `已开始下载 1 个文件` → `已开始下载 1 项`。
- 预览页保存结果：`已将 $associated 个本地文件关联到历史记录` → `… $associated 项本地内容`；`已保存 $done 项，并关联 $associated 个本地文件` → `… 并关联 $associated 项本地内容`。
- 批量页：`${post.items.length} 个文件` → `${post.items.length} 项`。
- 备份预览：`媒体文件` `${fileCount} 个` → `媒体项` `${itemCount} 项`（`fileCount` 保留供内部/日志，`itemCount` 新增）；恢复结果：`恢复文件：${restoredFiles} 个` → `恢复媒体：${restoredItems} 项`；`不在本机：${notOnDevice} 个` → `不在本机：${notOnDeviceItems} 项`。

内部逻辑与日志继续按文件（`savedFileCountFor`、`MediaDeleteOutcome.requested/remaining`、日志 `files=`），系统删除确认仍删除全部相关文件（实况两半一起删），只是不在用户可见文案里写文件数了。

### 测试

- `test/v111_build59_item_counts_test.dart`：8 项 11 文件的实况帖；删除面板显示 `同时删除相册中的 8 项` 且不出现 `11`；`deletableItemCountFor` 返回 8；备份预览与恢复结果按项；历史页顶部统计、列表行、创作者卡片的文案。
- `test/services/backup_restore_ui_test.dart`、`test/v1103_build47_delete_test.dart`：期待的文案已相应调整。
- `flutter test` 全量通过；`flutter analyze` 0 error，98 issues，与基线一致。

## 3. 回归清单补充

`docs/tasks/v1.11.md` 固定清单第 8 项：「悬浮球下载完成后回到 App，历史页三种模式都能看到该帖子（含之前删除过又重新下载的帖子）」；新增 `build 59 追加的回归项` 小节。

## 4. APK

```
path    app/build/app/outputs/flutter-apk/app-release.apk
        (same file as app/build/app/outputs/flutter-apk/EasySave-1.11.0-build59-release.apk)
version 1.11.0 (versionName='1.11.0', versionCode='59'), package com.james.easysave
sha256  652d05a442de957e4607c0f3983158d53497594b91c73793beda16467551898a
signer  CN=Jiawei LI, L=Paris, ST=Val de marne, C=FR
        08d7da286f2a84251ddfa85d1a49dc1b1d6b3ffc59ab7d117d8db783b0633907
        (same release key as build 56 / 57 / 58: installs in place, no uninstall)
```

## 5. 真机验证步骤（待执行）

1. 用同一签名的 release APK **覆盖安装**（不卸载、不清数据、不删相册文件）。
2. **悬浮球下载后回到 App**：任一帖子的悬浮球下载完成后，回到历史页，帖子 / 全部 / 创作者三种模式都能看到该帖子；之前删除过又重新下载的帖子也能看到，且出现在「今天」分组。
3. **删除计数按项**：选一条 8 项（其中 3 项实况、11 个文件）的帖子，删除确认对话框应显示 `同时删除相册中的 8 项`，不出现 `11`；结果提示按项。
4. **历史页统计与卡片**：顶部 `N 个帖子 · M 项`；帖子卡片/列表行 `M 项 · …`；创作者卡片 `N 帖 · M 项`；排序「项最多」按条目排序。
5. **App 内下载不受影响**：多图帖子、实况帖、视频帖各一次（进度、完成提示、历史记录、失败重试）。
