// Download panel over DownloadManager: per-file rows with progress,
// cancel, manual retry on failed rows, and completion actions.
// v1.1a reserved the failure/retry slots; v1.1b wires them.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

import '../core/models.dart';
import '../services/download_manager.dart';
import '../services/saver.dart';
import '../services/settings.dart';
import '../services/share_service.dart';
import '../theme/app_theme.dart';
import 'shared.dart';

class DownloadSheet extends StatefulWidget {
  const DownloadSheet({super.key, required this.batchId});

  final String batchId;

  /// Create the batch (asks notification permission, enqueues tasks) and
  /// then open the panel. The batch keeps running when the panel closes.
  static Future<void> show(
    BuildContext context,
    ParsedPost post,
    List<int> selected,
  ) async {
    final settings = await AppSettings.load();
    final author = post.author.name ?? '';
    final manager = DownloadManager.instance;
    final batch = await manager.startBatch(
      post,
      selected,
      album: settings.albumName,
      nameFor: (label, seq, ext) =>
          '${settings.fileName(postId: post.id, seq: seq, author: author)}.$ext',
    );
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DownloadSheet(batchId: batch.batchId),
    );
  }

  @override
  State<DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<DownloadSheet> {
  String? _captionPath;
  bool _captionSaved = false;
  bool _sharing = false;

  DownloadBatch? get _batch =>
      DownloadManager.instance.batchById(widget.batchId);

  Future<void> _maybeSaveCaption(DownloadBatch batch) async {
    if (_captionSaved || !batch.isTerminal) return;
    _captionSaved = true;
    final settings = await AppSettings.load();
    if (!settings.saveCaptionTxt) return;
    final post = ParsedPost(
      platform: batch.platform,
      id: batch.postId,
      url: batch.postUrl,
      author: PostAuthor(name: batch.authorName),
      items: const [],
      title: batch.title,
      caption: batch.caption,
    );
    if ((post.title ?? '').isEmpty && (post.caption ?? '').isEmpty) return;
    final path = await saveCaptionTxt(post);
    if (mounted) setState(() => _captionPath = path);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DownloadManager.instance,
      builder: (context, _) {
        final batch = _batch;
        if (batch == null) {
          return const SafeArea(
            child: Padding(padding: EdgeInsets.all(24), child: Text('下载任务已清理')),
          );
        }
        unawaited(_maybeSaveCaption(batch));
        final failed = batch.jobs
            .where((j) => j.state == JobState.failed)
            .length;
        final running = !batch.isTerminal;
        final doneCount = batch.jobs
            .where((j) => j.state == JobState.done)
            .length;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    PlatformTag(platform: batch.platform),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        running
                            ? '正在保存 $doneCount/${batch.jobs.length}'
                            : failed == 0
                            ? '全部完成 ✓'
                            : '$failed 项失败',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (_captionPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '文案已保存：$_captionPath',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: batch.jobs.length,
                    itemBuilder: (context, i) =>
                        _row(context, batch, batch.jobs[i]),
                  ),
                ),
                const SizedBox(height: 8),
                if (running)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('后台下载'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            DownloadManager.instance.cancelBatch(batch);
                            Navigator.of(context).pop();
                          },
                          child: const Text('取消'),
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            try {
                              await Gal.open();
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '已保存到相册“${batch.album}”，请手动打开相册查看',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text('打开相册'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _sharing || doneCount == 0
                              ? null
                              : () => _share(batch),
                          child: _sharing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('分享'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('完成'),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, DownloadBatch batch, DownloadJob job) {
    final isFailed = job.state == JobState.failed;
    final isDone = job.state == JobState.done;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(
        job.label,
        style: TextStyle(
          color: isFailed ? Theme.of(context).colorScheme.error : null,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _statusText(job),
            style: TextStyle(
              color: isFailed
                  ? Theme.of(context).colorScheme.error
                  : AppTokens.textSecondary,
            ),
          ),
          if (!isDone && !isFailed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(value: job.progress),
            ),
        ],
      ),
      trailing: isFailed
          ? OutlinedButton(
              onPressed: () => DownloadManager.instance.retryJob(batch, job),
              child: const Text('重试'),
            )
          : isDone
          ? const Icon(Icons.check_circle, color: Colors.green)
          : const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    );
  }

  String _statusText(DownloadJob job) {
    switch (job.state) {
      case JobState.queued:
        return '等待中';
      case JobState.active:
        return job.progress > 0
            ? '下载中 ${(job.progress * 100).round()}%'
            : '下载中…';
      case JobState.done:
        return '已完成';
      case JobState.failed:
        final attempt = '（已试 ${job.attempts}/$kMaxAttempts）';
        return '失败$attempt：${job.error ?? '未知错误'}';
      case JobState.canceled:
        return '已取消';
    }
  }

  Future<void> _share(DownloadBatch batch) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await shareBatch(batch);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('分享失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}
