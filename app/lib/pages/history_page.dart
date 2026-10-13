// History tab: platform filter, date groups, undoable delete, empty state.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services/history_db.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';
import 'preview_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.onGoParse});

  final VoidCallback? onGoParse;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  String _filter = 'all';
  List<HistoryRecord> _records = [];
  bool _loading = true;
  String? _dbError;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _dbError = null;
    });
    try {
      final records = await HistoryDb.instance().then((db) => db.recent());
      if (!mounted) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _dbError = '$e';
      });
    }
  }

  List<HistoryRecord> get _visible => _filter == 'all'
      ? _records
      : _records.where((r) => r.platform == _filter).toList();

  String _groupLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(day.year, day.month, day.day);
    final diff = today.difference(date).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Future<void> _delete(HistoryRecord record) async {
    if (record.id == null) return;
    await HistoryDb.instance().then((db) => db.delete(record.id!));
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已删除（仅删除记录，不删除相册文件）'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            await HistoryDb.instance().then((db) => db.reinsert(record));
            await _reload();
          },
        ),
      ),
    );
  }

  void _open(HistoryRecord record) {
    final items = <MediaItem>[];
    if (record.itemsJson != null) {
      try {
        final decoded = jsonDecode(record.itemsJson!) as List;
        for (final raw in decoded) {
          final map = (raw as Map).cast<String, Object?>();
          items.add(
            MediaItem(
              type: map['type'] as String? ?? 'image',
              url: map['url'] as String? ?? '',
              videoUrl: map['videoUrl'] as String?,
              width: map['width'] as num?,
              height: map['height'] as num?,
              duration: map['duration'] as num?,
            ),
          );
        }
      } catch (_) {
        // Fall through to the single-thumbnail fallback.
      }
    }
    if (items.isEmpty && record.thumbnailUrl != null) {
      items.add(MediaItem(type: 'image', url: record.thumbnailUrl!));
    }
    final post = ParsedPost(
      platform: record.platform,
      id: record.postId,
      url: record.postUrl,
      author: PostAuthor(name: record.authorName),
      items: items,
      title: record.title,
      caption: record.caption,
    );
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => PreviewPage(post: post)))
        .then((_) => _reload());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('历史')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('全部')),
                ButtonSegment(value: 'xhs', label: Text('小红书')),
                ButtonSegment(value: 'instagram', label: Text('Instagram')),
              ],
              selected: {_filter},
              onSelectionChanged: (selected) =>
                  setState(() => _filter = selected.first),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_dbError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('记录读取失败：$_dbError'),
            const SizedBox(height: 8),
            FilledButton(onPressed: _reload, child: const Text('重试')),
          ],
        ),
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 64,
              color: AppTokens.textSecondary,
            ),
            const SizedBox(height: 12),
            const Text('还没有下载记录，去解析第一条帖子吧'),
            const SizedBox(height: 8),
            FilledButton(onPressed: widget.onGoParse, child: const Text('去解析')),
          ],
        ),
      );
    }
    final groups = <String, List<HistoryRecord>>{};
    for (final record in visible) {
      groups.putIfAbsent(_groupLabel(record.createdAt), () => []).add(record);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              entry.key,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          for (final record in entry.value)
            Dismissible(
              key: ValueKey('history-${record.id}'),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16),
                child: const Icon(Icons.delete_outline),
              ),
              confirmDismiss: (_) async {
                await _delete(record);
                return false;
              },
              child: Card(
                child: ListTile(
                  onTap: () => _open(record),
                  leading: record.thumbnailUrl == null
                      ? null
                      : ClipRRect(
                          borderRadius: const BorderRadius.all(
                            Radius.circular(8),
                          ),
                          child: Image.network(
                            record.thumbnailUrl!,
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            cacheWidth: 200,
                            errorBuilder: (context, _, _) =>
                                const Icon(Icons.broken_image),
                          ),
                        ),
                  title: Text(
                    (record.title?.isNotEmpty == true) ? record.title! : '无标题',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${record.authorName ?? ''} · ${record.fileCount} 个文件',
                  ),
                  trailing: PlatformTag(platform: record.platform),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
