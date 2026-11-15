# Build 58 证据：下载计数按「项」、候选去重与 1.11.0 发布准备

版本 **1.11.0+58**，分支 `feature/v1.11`。未合并、未推送 master、未打 tag。
build 57 的真机回归（悬浮球全部下载/选择下载、引擎空闲销毁后再下载、「最近
保存」文件数、远程实况预加载与长按播放）全部通过，本 build 只做下面四项。

## 1. 用户可见的计数一律按「项」

真机：11 项的帖子选了 8 项（其中 3 项是实况），悬浮球显示 `x/11`（8 项 + 3 个
实况视频 = 11 个文件），看起来像选错了项。

规则：实况的静态图与视频合计为 **1 项**；一项只有在它的**所有文件**都成功后才
计为完成；实况任一半失败，该项计为**失败**。

实现（`DownloadBatch`）：以 `DownloadJob.itemIndex`（原帖 1-based 位置）为单位
统计，新增三个派生值：

| 值 | 含义 |
| --- | --- |
| `itemTotal` | 本批次覆盖的项数（未被全部取消的项） |
| `itemDone` | 所有文件都已写入相册的项数 |
| `itemFailed` | 至少有一个文件失败的项数 |

同一项里一个文件已保存、另一个仍在下载或已取消时，该项在 `itemTotal` 里，但
不在 `itemDone` 里；`itemDone + itemFailed ≤ itemTotal`。原有的 `succeeded` /
`doneCount` / `failedCount` 仍按文件，供逐文件行与日志使用。

改到「项」的用户可见位置：

- 悬浮球与快捷设置磁贴：`x/N`（`background_entry.dart`）。
- 通知栏标题：`正在下载 x/N` / `等待网络 x/N`（`_refreshNotification` → `downloadNotificationTitle`）。
- App 内下载面板：`正在保存 x/N`、`N 项失败`。
- 下载队列卡片：`下载中 · x/N 项 · M 项失败`。
- 完成提示（toast + 通知）：`下载完成：x/N 项`（含「图片格式」附注）。
- 失败 / 部分失败提示：`下载失败：成功 x/N 项 —— 原因`、预览页 `M 项下载失败`、
  预览页保存结果 `已保存 x 项到相册` / `已保存 x 项，并关联 M 个本地文件`、
  `M 项保存失败`。
- 重试提示：队列页「重试失败项」与预览页「重试」按钮本身不带数字，行为不变。

日志（V16DL / V16HOST）仍按文件计数，并附带 `items=`：

```
DOWNLOAD started 14 files items=11
DOWNLOAD done: 11/11 in 42s (files=14/14)
DOWNLOAD failed: 11/14 ok, 3 failed, 42s (files=13/14, failedFiles=1)
```

## 2. 候选去重防护（不改 parser）

parser 1.4.17 计划由解析器直接生成 `imageView2/format/jpg/q/100` 候选，而 App 也会
从同一 token 派生它。现在在**派生与排序之后**按最终 URL 去重
（`dedupeFinalCandidates`，保持首次出现的顺序）：

- `stillCandidatesFor` 的三个分支（兼容优先 / 原始格式 / JPEG）都在最后去重；
- 视频候选（`filterMediaCandidates` 之后）与手动重试的 `planFilesForItem` 同样去重；
- 解析器先给出还是 App 先派生出同一候选，结果都是同一条 URL，只尝试一次。

## 3. v1.12 待办（只记录，不实现）

后台引擎 `downloads-init` 4–8 秒的优化已记入
[`docs/roadmap.md`](../roadmap.md) 的 v1.12 与
[`v1.12.md`](v1.12.md)，依据本文档来源
[`build57-download-start-evidence.md`](build57-download-start-evidence.md) §6：
已结算的终态批次跳过 `_afterTerminal`；`cancel-notification` 只在本次会话显示过
通知时调用；`reconcile` 不阻塞入队。

## 4. 发布准备（只准备，不执行发布）

- `CHANGELOG.md`：`[Unreleased]` 整理为面向用户的 `[1.11.0]`，覆盖创作者排序、
  瀑布流平衡、备份恢复自动备份设置、失败日志快照、无网络等待与续传、浏览页闭环
  （不在本机 / 补下缺失 / 单张删除 / 选择驱动的操作栏 / 双计数）、切换模式保持
  状态与滚动位置、大图低清占位平滑过渡、实况预加载、图片格式设置、悬浮球与后台
  稳定性修复、缩略图请求洪泛修复，以及本 build 的「计数按项」与「候选去重」；
  删除了开发者开关与「开发者选项」分组条目，正文里的内部构建号改为面向用户的
  说法；被同版本后续批次替换掉的临时计数规则不再列出。
- `docs/roadmap.md`：「当前版本」更新为 v1.11.0（versionCode 58），v1.11 三批
  已完成项全部勾选。
- `app/pubspec.yaml`：`1.11.0+58`。

`feature/v1.11` 相对 `master`：**55 个提交**，92 个文件，+16704 / −756（含本次
发布提交；`git diff --shortstat master...HEAD`）。

## 5. 测试与闸门

新增测试：

- `test/v111_build58_item_counts_test.dart`（10 个用例）：实况 1 项 = 2 文件、
  纯图 / 纯视频帖、选择部分项、实况一半失败、取消整项、通知标题、面板标题，
  以及后台引擎真实提交路径——11 项（3 项实况）的帖子断言悬浮球 / 磁贴全程只有
  `x/11`、日志 `14 files items=11`、完成提示 `下载完成：11/11 项`、用户可见文案
  中不再出现「个文件」；实况一半失败的批次断言 `下载失败：成功 1/2 项`。
- `test/v111_build58_candidate_dedup_test.dart`（10 个用例）：解析器已给出派生
  候选、解析器只给原图、解析器列表内重复、原始格式 / JPEG 两个分支、视频候选项
  重复、实况静态图与视频分离、手动重试规划。

闸门（全部通过）：

| 闸门 | 结果 |
| --- | --- |
| `flutter test` | **1403 passed**（含 `media_request_policy_test` 与全部 fixture） |
| `gradlew testDebugUnitTest` | **BUILD SUCCESSFUL**，`:app:testDebugUnitTest` 135 tests / 34 suites / 0 failures（1 skipped） |
| `extension` `npm test` | **290 Vitest + 33 build checks** 通过 |
| `flutter analyze` | **0 error / 98 issues**，与基线数量一致 |

## 6. APK

```
path    app/build/app/outputs/flutter-apk/app-release.apk
        (same file as app/build/app/outputs/flutter-apk/EasySave-1.11.0-build58-release.apk)
version 1.11.0 (versionName='1.11.0', versionCode='58'), package com.james.easysave
bytes   64,962,218
sha256  f3ee43e7ee38f8c280aa3006e286e080702d6790fc7297fb5e4e9d884d3ff7b3
signer  CN=Jiawei LI, L=Paris, ST=Val de marne, C=FR
        08d7da286f2a84251ddfa85d1a49dc1b1d6b3ffc59ab7d117d8db783b0633907
        (same release key as build 56 / 57: installs in place, no uninstall)
```

## 7. 真机验证步骤（待执行）

1. 用同一签名的 release APK **覆盖安装**（不卸载、不清数据、不删相册文件）。
2. **计数按项（重点）**：找一条 **11 项、其中 3 项为实况** 的帖子，用悬浮球
   「选择下载」只选 8 项。
   - 悬浮球与快捷设置磁贴应显示 `x/8`（任何时刻都不出现 `/11`），
   - 通知栏标题应是 `正在下载 x/8`，
   - App 内下载面板应是 `正在保存 x/8`，
   - 结束时的提示应是 `下载完成：8/8 项`，历史条数与「最近保存」都应是 8。
   - `adb logcat -s flutter` 里应是 `DOWNLOAD started 11 files items=8` 与
     `DOWNLOAD done: 8/8 in …s (files=11/11)`：日志按文件、用户看按项。
3. **实况一半失败**：用「我的 → 开发者选项 → 下一次下载模拟失败」让批次的首个
   文件失败（若首个文件是实况的一半），确认该项计为失败、提示为
   `下载失败：成功 7/8 项 —— …`，面板显示 `1 项失败`，重试后变为 `8/8 项`。
4. **纯图 8 项帖子**「全部下载」一次：`x/8` 且完成提示 `8/8 项`（与文件数相同）。
5. **候选去重**：`adb logcat` 中同一项的 `[V16DL] candidate=` 里不应出现两条完全
   相同的 URL 记录；下载过程中同一地址只被请求一次（下载器日志中
   `imageView2/format/jpg/q/100` 的候选在每项里最多一次）。
6. 重复 build 57 的核心回归各一次：悬浮球全部下载、引擎空闲销毁（
   `Idle 60000ms reached`）后再下载、远程实况长按播放。
