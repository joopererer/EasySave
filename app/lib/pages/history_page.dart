// History tab: platform filter, date groups, undoable delete, empty state,
// local photo_manager album resolution, permission banners, and unified fullscreen browser.

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/gallery_locator_service.dart';
import '../services/history_db.dart';
import '../services/parse_service.dart';
import '../theme/app_theme.dart';
import '../widgets/download_sheet.dart';
import '../widgets/gallery_browser.dart';
import '../widgets/shared.dart';
import 'preview_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.onGoParse});

  final VoidCallback? onGoParse;

  @override
  State<HistoryPage> createState() => HistoryPageState();
}

class HistoryPageState extends State<HistoryPage> with WidgetsBindingObserver {
  String _filter = 'all';
  List<HistoryRecord> _records = [];
  bool _loading = true;
  String? _dbError;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GalleryLocatorService.instance.addListener(_onLocatorChanged);
    _initPermissionsAndLoad();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GalleryLocatorService.instance.removeListener(_onLocatorChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissionAndRefresh();
    }
  }

  Future<void> _checkPermissionAndRefresh() async {
    final locator = GalleryLocatorService.instance;
    final oldPerm = locator.permission;
    final newPerm = await locator.checkPermission();
    if (newPerm.hasAccess) {
      await locator.scanAlbum(force: true);
      await _reload();
    } else if (newPerm != oldPerm) {
      if (mounted) setState(() {});
    }
  }

  void _onLocatorChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initPermissionsAndLoad() async {
    final locator = GalleryLocatorService.instance;
    await locator.checkPermission();
    if (locator.permission == PermissionState.notDetermined) {
      await locator.requestPermission();
    } else if (locator.hasAccess) {
      await locator.scanAlbum();
    }
    await _reload();
  }

  /// Reload from DB; called by the shell every time the tab becomes visible
  /// because IndexedStack keeps this page alive across tab switches.
  Future<void> reload() async {
    if (!mounted) return;
    await _reload();
  }

  Future<void> _reload() async {
    final silent = _records.isNotEmpty;
    if (!silent) {
      setState(() {
        _loading = true;
        _dbError = null;
      });
    }
    try {
      final records = await HistoryDb.instance().then((db) => db.recent());
      final locator = GalleryLocatorService.instance;
      if (locator.hasAccess) {
        await locator.syncAll(records);
      }
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

  Future<void> _reparse(HistoryRecord record) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 12),
            Text('正在重新解析...'),
          ],
        ),
        duration: Duration(seconds: 10),
      ),
    );
    try {
      final outcome = await parsePostOutcome(record.postUrl);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PreviewPage(
            post: outcome.data,
            rawImages: outcome.rawImages,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('解析失败：$e')),
      );
    }
  }

  Future<void> _openOriginal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _open(HistoryRecord record) {
    if (_opening) return;
    _opening = true;

    final post = PreviewPage.postFromRecord(record);
    final locator = GalleryLocatorService.instance;

    final downloadedIndices = record.files.map((f) => f.itemIndex).toSet();
    final targetIndices = downloadedIndices.isNotEmpty
        ? (downloadedIndices.toList()..sort())
        : [for (var i = 0; i < post.items.length; i++) i];

    final items = <GalleryBrowserItem>[];
    for (final i in targetIndices) {
      if (i < 0 || i >= post.items.length) continue;
      final postItem = post.items[i];
      HistoryFile? matchedFile;
      for (final f in record.files) {
        if (f.itemIndex == i) {
          matchedFile = f;
          break;
        }
      }
      AssetEntity? asset;
      FileStatus status = FileStatus.unknown;
      if (matchedFile != null) {
        asset = locator.getAssetById(matchedFile.mediaId) ??
            locator.locateAsset(matchedFile, record.postId);
        status = matchedFile.status;
      }
      items.add(
        GalleryBrowserItem(
          index: i,
          type: postItem.type,
          url: postItem.url,
          videoUrl: postItem.videoUrl,
          isGif: postItem.isGif ?? false,
          asset: asset,
          status: status,
          filename: matchedFile?.filename,
        ),
      );
    }

    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => GalleryBrowserPage(
              items: items,
              authorName: record.authorName ?? '',
              title: (record.title?.isNotEmpty == true)
                  ? record.title!
                  : record.postId,
              platform: record.platform,
              postUrl: record.postUrl,
              onReparse: () => _reparse(record),
              onRedownload: (index) async {
                await DownloadSheet.show(context, post, [index]);
                await locator.scanAlbum(force: true);
                await locator.syncRecord(record);
                if (mounted) setState(() {});
              },
            ),
          ),
        )
        .then((_) {
          _opening = false;
          _reload();
        });
  }

  @override
  Widget build(BuildContext context) {
    final locator = GalleryLocatorService.instance;

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
          // Permission Warning Banners
          if (locator.isDenied)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.amber.shade800, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '未获得相册权限，无法定位本地文件',
                      style: TextStyle(color: Colors.amber.shade900, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: () => locator.openSettings(),
                    child: const Text('去设置'),
                  ),
                ],
              ),
            )
          else if (locator.isLimited)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue.shade800, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '仅授权了部分照片，未授权的媒体无法显示',
                      style: TextStyle(color: Colors.blue.shade900, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: () => locator.reRequestLimited(),
                    child: const Text('管理权限'),
                  ),
                ],
              ),
            ),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('全部')),
                ButtonSegment(value: 'xhs', label: Text('小红书')),
                ButtonSegment(value: 'instagram', label: Text('Instagram')),
                ButtonSegment(value: 'x', label: Text('X')),
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
    return RefreshIndicator(
      onRefresh: () async {
        final locator = GalleryLocatorService.instance;
        if (locator.hasAccess) {
          await locator.scanAlbum(force: true);
        }
        await _reload();
      },
      child: ListView(
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
                    subtitle: Row(
                      children: [
                        PlatformTag(platform: record.platform),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${record.authorName ?? ''} · ${record.fileCount} 个文件',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: '重新解析',
                          onPressed: () => _reparse(record),
                        ),
                        IconButton(
                          icon: const Icon(Icons.open_in_new, size: 20),
                          tooltip: '打开原帖',
                          onPressed: () => _openOriginal(record.postUrl),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 48px leading thumbnail reading local album photo_manager asset without CDN requests.
  Widget _thumbOf(HistoryRecord record) {
    final locator = GalleryLocatorService.instance;

    // Show shimmering loading box while scanning or before scan completes
    if (locator.isScanning || !locator.scanned) {
      return const ShimmerBox(width: 48, height: 48);
    }

    AssetEntity? asset;
    for (final f in record.files) {
      asset = locator.getAssetById(f.mediaId) ??
          locator.locateAsset(f, record.postId);
      if (asset != null) break;
    }

    if (asset != null) {
      return ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: SizedBox(
          width: 48,
          height: 48,
          child: AssetEntityImage(
            asset,
            isOriginal: false,
            thumbnailSize: const ThumbnailSize.square(150),
            fit: BoxFit.cover,
          ),
        ),
      );
    }

    // Only show "已从相册删除" when fully authorized, scan completed, and all files are confirmed not found
    final allNotFound = record.files.isNotEmpty &&
        record.files.every((f) => f.status == FileStatus.notFound);

    if (locator.isFullyAuthorized && allNotFound) {
      return Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: const Icon(Icons.broken_image, size: 24, color: Colors.grey),
      );
    }

    // Default neutral placeholder when not found or permissions unknown
    return Container(
      width: 48,
      height: 48,
      decoration: const BoxDecoration(
        color: AppTokens.beigeBg,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: const Icon(
        Icons.photo_outlined,
        size: 24,
        color: AppTokens.textSecondary,
      ),
    );
  }
}
