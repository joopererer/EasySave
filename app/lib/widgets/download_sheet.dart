// Download panel over DownloadManager: per-file rows with progress,
// cancel, manual retry on failed rows, and completion actions.
// v1.1a reserved the failure/retry slots; v1.1b wires them.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

import '../core/models.dart';
import '../services/download_manager.dart';
import '../services/network_status.dart';
import '../services/saver.dart';
import '../services/settings.dart';
import '../services/share_service.dart';
import '../services/media_request_policy.dart';
import '../theme/app_theme.dart';
import 'shared.dart';

/// What the app says when a download is started (v1.11 batch 2).
///
/// Offline the batch is still queued and starts by itself once the connection
/// returns, so the message explains the wait instead of claiming it started.
String downloadStartMessage({required bool online}) =>
    online ? '已加入下载队列' : '当前无网络，联网后自动开始';

class DownloadSheet extends StatefulWidget {
  const DownloadSheet({super.key, required this.batchId});

  final String batchId;

  /// Create the batch (asks notification permission, enqueues tasks) and
  /// then open the panel. The batch keeps running when the panel closes.
  /// Returns the batch once the panel is dismissed (null if it could not be
  /// started), so the caller can react to completion / failures.
  static Future<DownloadBatch?> show(
    BuildContext context,
    ParsedPost post,
    List<int> selected,
  ) async {
    final settings = await AppSettings.load();
    final author = post.author.name ?? '';
    final manager = DownloadManager.instance;
    Future<void>? panel;
    final batch = await manager.startBatch(
      post,
      selected,
      album: settings.albumName,
      nameFor: (label, seq, ext) =>
          settings.fileName(postId: post.id, seq: seq, author: author),
      onBatchReady: (ready) {
        if (!context.mounted) return;
        panel = showModalBottomSheet<void>(context: context, isScrollControlled: true,
            builder: (_) => DownloadSheet(batchId: ready.batchId));
      },
    );
    if (!context.mounted) return batch;
    // The batch is queued either way; offline it simply waits for the
    // connection and starts by itself (v1.11 batch 2 says so out loud).
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          downloadStartMessage(online: NetworkStatus.instance.online),
        ),
      ),
    );
    await panel;
    return batch;
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
      aiLabel: batch.aiLabel == null ? null : AiLabel(text: batch.aiLabel!, source: batch.aiLabelSource ?? 'unknown'),
    );
    if ((post.title ?? '').isEmpty && (post.caption ?? '').isEmpty) return;
    final path = await saveCaptionTxt(post);
    if (mounted) setState(() => _captionPath = path);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        DownloadManager.instance,
        NetworkStatus.instance,
      ]),
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
        // Display only: an offline batch keeps its queue position and resumes
        // by itself; the panel just stops pretending it is transferring. A file
        // parked waiting for the connection says so even while the system still
        // reports one (v1.11 batch 3).
        final waitingForNetwork =
            running &&
            (!NetworkStatus.instance.online || batch.waitingForNetwork);
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
                            ? waitingForNetwork
                            ? '等待网络…联网后自动继续'
                            : '正在保存 $doneCount/${batch.jobs.length}'
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
                if (!running && failed == 0)
                  if (imageFormatCompletionNote(batch) != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        imageFormatCompletionNote(batch)!,
                        style: const TextStyle(fontSize: 12),
                      ),
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
                    itemBuilder: (context, i) => _row(
                      context,
                      batch,
                      batch.jobs[i],
                      waitingForNetwork: waitingForNetwork,
                    ),
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

  Widget _row(
    BuildContext context,
    DownloadBatch batch,
    DownloadJob job, {
    bool waitingForNetwork = false,
  }) {
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
            _statusText(batch, job, waitingForNetwork: waitingForNetwork),
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

  String _statusText(
    DownloadBatch batch,
    DownloadJob job, {
    bool waitingForNetwork = false,
  }) {
    switch (job.state) {
      case JobState.queued:
        return waitingForNetwork ? '等待网络…联网后自动继续' : '等待中';
      case JobState.active:
        if (waitingForNetwork) return '等待网络…联网后自动继续';
        return job.progress > 0
            ? '下载中 ${(job.progress * 100).round()}%'
            : '下载中…';
      case JobState.done:
        return job.metadataNotice ?? '已完成';
      case JobState.failed:
        // The real budget of this file, not the per-candidate transfer limit:
        // a still walks several candidates, so "已试 5/3" was showing a
        // denominator the file never had.
        final attempt = '（已试 ${job.attempts}/${retryCapFor(batch, job)}）';
        return '失败$attempt：${job.error ?? '未知错误'}';
      case JobState.canceled:
        return '已取消';
      case JobState.paused:
        return '已暂停';
      case JobState.waitingNetwork:
        // A parked file: not a failure, not a spent attempt (v1.11 batch 3).
        return '等待网络…联网后自动继续';
    }
  }

  Future<void> _share(DownloadBatch batch) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await shareBatch(batch);
    } on MediaPolicyException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该资源地址不在允许范围内')),
        );
      }
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
