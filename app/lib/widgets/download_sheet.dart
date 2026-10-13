// Download panel: per-file rows, cancel, completion and partial-failure
// states. v1.1a: no background work and no retry wiring; the retry button
// position is reserved (disabled) for v1.1b.

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

import '../core/models.dart';
import '../services/saver.dart';
import '../services/settings.dart';
import '../theme/app_theme.dart';
import 'shared.dart';

class DownloadSheet extends StatefulWidget {
  const DownloadSheet({super.key, required this.post, required this.selected});

  final ParsedPost post;
  final List<int> selected;

  static Future<void> show(
    BuildContext context,
    ParsedPost post,
    List<int> selected,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DownloadSheet(post: post, selected: selected),
  );

  @override
  State<DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<DownloadSheet> {
  List<SaveFileState> _files = [];
  int _done = 0;
  int _total = 0;
  bool _running = true;
  bool _cancelled = false;
  SaveSummary? _summary;
  String? _captionPath;
  String _albumName = 'EasySave';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final settings = await AppSettings.load();
    final author = widget.post.author.name ?? '';
    _albumName = settings.albumName;
    final summary = await saveItems(
      widget.post,
      widget.selected,
      album: settings.albumName,
      nameFor: (label, seq, ext) =>
          '${settings.fileName(postId: widget.post.id, seq: seq, author: author)}.$ext',
      isCancelled: () => _cancelled,
      onProgress: (progress) async {
        if (!mounted) return;
        setState(() {
          _files = progress.files;
          _done = progress.done;
          _total = progress.total;
        });
      },
    );
    String? captionPath;
    if (settings.saveCaptionTxt &&
        ((widget.post.title ?? '').isNotEmpty ||
            (widget.post.caption ?? '').isNotEmpty)) {
      captionPath = await saveCaptionTxt(widget.post);
    }
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _running = false;
      _captionPath = captionPath;
    });
  }

  @override
  Widget build(BuildContext context) {
    final failed = _files
        .where((f) => f.status == SaveFileStatus.failed)
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
                PlatformTag(platform: widget.post.platform),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _running
                        ? '正在保存 $_done/$_total'
                        : _summary != null && failed == 0
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
                itemCount: _files.length,
                itemBuilder: (context, i) {
                  final file = _files[i];
                  final isFailed = file.status == SaveFileStatus.failed;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      file.label,
                      style: TextStyle(
                        color: isFailed
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                    subtitle: Text(
                      _statusText(file),
                      style: TextStyle(
                        color: isFailed
                            ? Theme.of(context).colorScheme.error
                            : AppTokens.textSecondary,
                      ),
                    ),
                    trailing: isFailed
                        // Reserved for v1.1b retry wiring.
                        ? const OutlinedButton(
                            onPressed: null,
                            child: Text('重试'),
                          )
                        : file.status == SaveFileStatus.done
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            if (_running)
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
                        setState(() => _cancelled = true);
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
                        // Gal.open() fires ACTION_VIEW on the MediaStore
                        // collection, which many OEM galleries cannot handle.
                        // Fall back to telling the user the album name.
                        try {
                          await Gal.open();
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('已保存到相册“$_albumName”，请手动打开相册查看'),
                              ),
                            );
                          }
                        }
                      },
                      child: const Text('打开相册'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    // v1.2 share target.
                    child: OutlinedButton(onPressed: null, child: Text('分享')),
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
  }

  String _statusText(SaveFileState file) {
    switch (file.status) {
      case SaveFileStatus.pending:
        return '等待中';
      case SaveFileStatus.active:
        return '下载中…';
      case SaveFileStatus.done:
        return '已完成';
      case SaveFileStatus.failed:
        return '失败：${file.error ?? '未知错误'}';
    }
  }
}
