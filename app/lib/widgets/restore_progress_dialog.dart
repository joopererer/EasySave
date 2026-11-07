import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../services/backup/backup_service.dart';

/// Non-dismissible progress of a running restore: "正在恢复 x / y 个帖子".
class RestoreProgressDialog extends StatelessWidget {
  const RestoreProgressDialog({super.key, required this.progress});

  /// (posts done, posts total).
  final ValueListenable<(int, int)> progress;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('正在恢复'),
        content: ValueListenableBuilder<(int, int)>(
          valueListenable: progress,
          builder: (context, value, _) {
            final (done, total) = value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: total == 0 ? null : done / total),
                const SizedBox(height: 12),
                Text('正在恢复 $done / $total 个帖子'),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Result summary shown after a restore.
String restoreSummaryText(ImportResult result) =>
    '恢复完成！\n\n'
    '· 恢复帖子：${result.restoredPosts - result.skippedPosts} 个'
    '（新增 ${result.insertedPosts}，合并 ${result.mergedPosts}'
    '${result.skippedPosts > 0 ? '，跳过 ${result.skippedPosts}' : ''}）\n'
    '· 恢复文件：${result.restoredFiles} 个\n'
    '· 不在本机：${result.notOnDevice} 个'
    '${result.overlayNotice ? '\n\n提示：由于系统未授予悬浮窗权限，悬浮球已设为关闭，可在权限管理中授权后开启。' : ''}';
