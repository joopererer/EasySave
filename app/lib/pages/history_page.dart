// History tab: platform filter, date groups, undoable delete, empty state.

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services/history_db.dart';
import '../services/saver.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';
import 'preview_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.onGoParse});

  final VoidCallback? onGoParse;

  @override
  State<HistoryPage> createState() => HistoryPageState();
}

class HistoryPageState extends State<HistoryPage> {
  String _filter = 'all';
  List<HistoryRecord> _records = [];
  bool _loading = true;
  String? _dbError;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// Reload from DB; called by the shell every time the tab becomes visible
  /// because IndexedStack keeps this page alive across tab switches.
  Future<void> reload() async {
    if (!mounted) return;
    await _reload();
  }

  Future<void> _reload() async {
    // Silent refresh after the first load: swapping the whole list for a
    // spinner on every return-from-preview reads as a freeze.
    final silent = _records.isNotEmpty;
    if (!silent) {
      setState(() {
        _loading = true;
        _dbError = null;
      });
    }
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

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史记录？'),
        content: const Text('将删除全部下载记录，相册中的文件不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await HistoryDb.instance().then((db) => db.clear());
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('历史记录已清空')));
  }

  void _open(HistoryRecord record) {
    // Guard against tap storms: a second push while the transition is
    // still running stacks identical routes and makes "back" look dead.
    if (_opening) return;
    _opening = true;
    final post = PreviewPage.postFromRecord(record);
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => PreviewPage(post: post)))
        .then((_) {
          _opening = false;
          _reload();
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史'),
        actions: [
          if (_records.isNotEmpty)
            TextButton(onPressed: _confirmClearAll, child: const Text('清空')),
        ],
      ),
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
                  leading: _thumbOf(record),
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

  /// 48px leading thumbnail; null-safe — a video URL is never rendered.
  Widget? _thumbOf(HistoryRecord record) {
    final url = displayThumbnail(record);
    if (url == null) return null;
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: CoverImage(
        item: MediaItem(type: 'image', url: url),
        referer: refererFor(record.platform),
        cacheWidth: 200,
        width: 48,
        height: 48,
      ),
    );
  }
}
