// Download queue (history top entry): every batch the two engines know about,
// with per-file state, cancel / retry / delete. Batches of the other engine
// are read from the shared snapshots and force-adopted when acted upon.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services/download_manager.dart';
import '../services/saver.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';

/// Media items of a batch, decoded from its stored `itemsJson`; used to show
/// a real preview next to each file instead of only its file name.
List<MediaItem> batchItems(DownloadBatch batch) {
  final raw = batch.itemsJson;
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is Map) MediaItem.fromJson(e.cast<String, dynamic>()),
    ];
  } catch (_) {
    return const [];
  }
}

/// Small rounded preview of one post item (CDN image with fallbacks).
class _QueueThumb extends StatelessWidget {
  const _QueueThumb({
    required this.item,
    required this.platform,
    this.size = 44,
  });

  final MediaItem? item;
  final String platform;
  final double size;

  @override
  Widget build(BuildContext context) {
    final it = item;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: size,
        height: size,
        child: it == null
            ? const ColoredBox(
                color: Colors.black12,
                child: Icon(Icons.image_outlined, size: 20),
              )
            : CoverImage(
                item: it,
                referer: refererFor(platform),
                cacheWidth: (size * 3).round(),
                width: size,
                height: size,
              ),
      ),
    );
  }
}

class DownloadQueuePage extends StatefulWidget {
  const DownloadQueuePage({super.key});

  @override
  State<DownloadQueuePage> createState() => _DownloadQueuePageState();
}

class _DownloadQueuePageState extends State<DownloadQueuePage> {
  List<DownloadBatch> _batches = const [];
  bool _loading = true;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    DownloadManager.instance.addListener(_refresh);
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    _refresh();
  }

  @override
  void dispose() {
    DownloadManager.instance.removeListener(_refresh);
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final list = await DownloadManager.instance.liveBatches();
    if (!mounted) return;
    setState(() {
      // Only what is still downloading (or paused); finished batches belong
      // to the history.
      _batches = [for (final b in list) if (!b.isTerminal) b];
      _loading = false;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _confirmRemove(DownloadBatch batch) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除下载任务'),
        content: Text(
          batch.isTerminal
              ? '从队列中移除这条记录？已保存的文件不会被删除。'
              : '取消未完成的下载并移除任务？已保存的文件不会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _run(() => DownloadManager.instance.removeBatch(batch));
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载队列'),
        actions: [
          if (_batches.isNotEmpty)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(DownloadManager.instance.cancelAll),
              child: const Text('全部取消'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _batches.isEmpty
              ? const Center(
                  child: Text(
                    '没有正在下载的任务',
                    style: TextStyle(color: AppTokens.textSecondary),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _batches.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _BatchCard(
                    batch: _batches[i],
                    stalled: _batches[i].isStalledAt(now),
                    busy: _busy,
                    onCancelJob: (j) => _run(
                      () => DownloadManager.instance.cancelJob(_batches[i], j),
                    ),
                    onRetryJob: (j) => _run(() async {
                      final owned = await DownloadManager.instance
                          .forceAdopt(_batches[i]);
                      final job = owned.jobs.firstWhere((x) => x.key == j.key);
                      await DownloadManager.instance.retryJob(owned, job);
                    }),
                    onRetryAll: () => _run(() async {
                      final owned = await DownloadManager.instance
                          .forceAdopt(_batches[i]);
                      await DownloadManager.instance.retryBatch(owned);
                    }),
                    onToggle: () => _run(() async {
                      final b = _batches[i];
                      final dm = DownloadManager.instance;
                      if (b.isPaused) {
                        await dm.resumeBatch(b);
                      } else if (b.isStalledAt(now)) {
                        final owned = await dm.forceAdopt(b);
                        await dm.restartBatch(owned);
                      } else {
                        await dm.pauseBatch(b);
                      }
                    }),
                    onRemove: () => _confirmRemove(_batches[i]),
                  ),
                ),
    );
  }
}

class _BatchCard extends StatelessWidget {
  const _BatchCard({
    required this.batch,
    required this.stalled,
    required this.busy,
    required this.onCancelJob,
    required this.onRetryJob,
    required this.onRetryAll,
    required this.onToggle,
    required this.onRemove,
  });

  final DownloadBatch batch;
  final bool stalled;
  final bool busy;
  final void Function(DownloadJob) onCancelJob;
  final void Function(DownloadJob) onRetryJob;
  final VoidCallback onRetryAll;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  String get _status {
    if (batch.isPaused) return '已暂停';
    return stalled ? '已停滞' : '下载中';
  }

  @override
  Widget build(BuildContext context) {
    final title = (batch.title?.isNotEmpty == true) ? batch.title! : '无标题';
    final pct = (batch.progress * 100).round();
    final items = batchItems(batch);
    final paused = batch.isPaused;
    final toggleTip = paused ? '继续下载' : (stalled ? '重试' : '暂停下载');
    final toggleIcon = paused
        ? Icons.play_arrow_rounded
        : (stalled ? Icons.refresh : Icons.pause_rounded);
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: _QueueThumb(
          item: items.isEmpty ? null : items.first,
          platform: batch.platform,
          size: 52,
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$_status · ${batch.doneCount}/${batch.jobs.length} 个文件'
                '${batch.failedCount > 0 ? ' · ${batch.failedCount} 个失败' : ''}',
                style: TextStyle(
                  fontSize: 12,
                  color: stalled || batch.failedCount > 0
                      ? Theme.of(context).colorScheme.error
                      : AppTokens.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: paused || batch.progress > 0 ? batch.progress : null,
                semanticsLabel: '下载进度 $pct%',
              ),
            ],
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (batch.supportsPause) IconButton(
              tooltip: toggleTip,
              icon: Icon(toggleIcon),
              onPressed: busy ? null : onToggle,
            ),
            IconButton(
              tooltip: batch.supportsPause ? '删除任务' : '取消',
              icon: const Icon(Icons.delete_outline),
              onPressed: busy ? null : onRemove,
            ),
          ],
        ),
        children: [
          if (batch.failedCount > 0)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: TextButton.icon(
                  onPressed: busy ? null : onRetryAll,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重试失败项'),
                ),
              ),
            ),
          for (final job in batch.jobs)
            _JobTile(
              job: job,
              platform: batch.platform,
              item: job.itemIndex >= 1 && job.itemIndex <= items.length
                  ? items[job.itemIndex - 1]
                  : null,
              busy: busy,
              onCancel: () => onCancelJob(job),
              onRetry: () => onRetryJob(job),
            ),
        ],
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({
    required this.job,
    required this.platform,
    required this.item,
    required this.busy,
    required this.onCancel,
    required this.onRetry,
  });

  final DownloadJob job;
  final String platform;
  final MediaItem? item;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  String get _label => switch (job.state) {
    JobState.queued => '排队中',
    JobState.active => '下载中 ${(job.progress.clamp(0.0, 1.0) * 100).round()}%',
    JobState.done => '已保存',
    JobState.failed => job.error ?? '失败',
    JobState.canceled => '已取消',
    JobState.paused => '已暂停',
  };

  @override
  Widget build(BuildContext context) {
    // "第 N 张" reads better than a generated file name.
    final name = job.itemIndex > 0 ? '第 ${job.itemIndex} 项' : job.filename;
    return ListTile(
      dense: true,
      leading: _QueueThumb(item: item, platform: platform),
      title: Text(
        job.isLivePhoto ? '$name · ${job.isImage ? '实况图片' : '实况视频'}' : name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(_label, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: switch (job.state) {
        JobState.queued || JobState.active || JobState.paused => IconButton(
          tooltip: '取消此文件',
          icon: const Icon(Icons.close),
          onPressed: busy ? null : onCancel,
        ),
        JobState.failed || JobState.canceled => IconButton(
          tooltip: '重试此文件',
          icon: const Icon(Icons.refresh),
          onPressed: busy ? null : onRetry,
        ),
        JobState.done => const Icon(Icons.check, size: 18),
      },
    );
  }
}
