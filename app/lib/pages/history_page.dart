// History tab (ui-spec §2.4): three views (帖子 / 全部 / 创作者), waterfall and
// list layouts, compact toolbar with search / platform filter / sort / layout,
// sticky grouping, local-album thumbnails, multi-select and delete.
//
// Reuses GalleryLocatorService for local file resolution and GalleryBrowserPage
// for fullscreen viewing — no parallel implementations.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import '../services/auth.dart';
import '../services/gallery_locator_service.dart';
import '../services/history_db.dart';
import '../services/host_bridge.dart';
import '../services/media_delete_service.dart';
import '../services/parse_service.dart';
import '../services/settings.dart';
import '../theme/app_theme.dart';
import '../widgets/delete_records_sheet.dart';
import '../widgets/download_sheet.dart';
import '../widgets/gallery_browser.dart';
import '../widgets/history_cards.dart';
import 'login_page.dart';
import 'preview_page.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({
    super.key,
    this.onGoParse,
    this.onSelectionModeChanged,
  });

  final VoidCallback? onGoParse;

  /// Notifies the shell to hide its bottom navigation while multi-select is
  /// active (the page renders its own action bar in that state).
  final ValueChanged<bool>? onSelectionModeChanged;

  @override
  State<HistoryPage> createState() => HistoryPageState();
}

class HistoryPageState extends State<HistoryPage> with WidgetsBindingObserver {
  List<HistoryRecord> _records = [];
  bool _loading = true;
  String? _dbError;
  bool _opening = false;

  AppSettings? _settings;
  HistoryView _view = HistoryView.posts;
  HistoryLayout _layout = HistoryLayout.waterfall;
  HistorySort _sort = HistorySort.latest;

  bool _searchOpen = false;
  String _query = '';
  final _searchController = TextEditingController();
  String _platform = 'all';
  String? _author;

  bool _selectionMode = false;
  // Keys: posts view -> 'p{recordId}'; all view -> 'm{recordId}:{itemIndex}'.
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GalleryLocatorService.instance.addListener(_onLocatorChanged);
    HostBridge.historyRevision.addListener(_onHostHistoryChanged);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GalleryLocatorService.instance.removeListener(_onLocatorChanged);
    HostBridge.historyRevision.removeListener(_onHostHistoryChanged);
    _searchController.dispose();
    super.dispose();
  }

  // The background engine finished a download and wrote history; reload so
  // the new records show up without a manual refresh.
  void _onHostHistoryChanged() {
    if (!mounted) return;
    unawaited(_reload());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reload from the DB so records written by the background engine while
      // we were away (e.g. a share-to-background download) show up right away.
      unawaited(_reload());
      _checkPermissionAndRefresh();
    }
  }

  Future<void> _init() async {
    final settings = await AppSettings.load();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _view = settings.historyView;
      _layout = settings.historyLayout;
      _sort = settings.historySort;
    });
    await _initPermissionsAndLoad();
  }

  Future<void> _persistPrefs() async {
    final settings = _settings;
    if (settings == null) return;
    settings.historyView = _view;
    settings.historyLayout = _layout;
    settings.historySort = _sort;
    await settings.save();
  }

  Future<void> _checkPermissionAndRefresh() async {
    final locator = GalleryLocatorService.instance;
    final oldPerm = locator.permission;
    final newPerm = await locator.checkPermission();
    if (!oldPerm.hasAccess && newPerm.hasAccess) {
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
    await _reload();
    final locator = GalleryLocatorService.instance;
    await locator.checkPermission();
    if (!locator.permission.hasAccess) {
      await locator.requestPermission();
    }
    if (locator.hasAccess) {
      await locator.preloadMediaIds(_records);
      if (mounted) setState(() {});
      unawaited(_backgroundScanAndSync());
    }
  }

  Future<void> _backgroundScanAndSync() async {
    final locator = GalleryLocatorService.instance;
    await locator.scanAlbum();
    if (_records.isNotEmpty) {
      await locator.syncAll(_records);
    }
    if (mounted) setState(() {});
  }

  /// Reload from DB; called by the shell every time the tab becomes visible.
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
      if (!mounted) return;
      setState(() {
        _records = records;
        _loading = false;
      });
      final locator = GalleryLocatorService.instance;
      if (locator.hasAccess) {
        await locator.preloadMediaIds(records);
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _dbError = '$e';
      });
    }
  }

  // ---------------------------------------------------------------- filtering

  List<HistoryRecord> get _filtered {
    final q = _query.trim().toLowerCase();
    return _records.where((r) {
      if (_platform != 'all' && r.platform != _platform) return false;
      if (_author != null && (r.authorName ?? '') != _author) return false;
      if (q.isNotEmpty) {
        final title = (r.title ?? '').toLowerCase();
        final author = (r.authorName ?? '').toLowerCase();
        if (!title.contains(q) && !author.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  void _clearFilters() {
    setState(() {
      _platform = 'all';
      _author = null;
      _query = '';
      _searchOpen = false;
      _searchController.clear();
    });
  }

  // -------------------------------------------------------------- selection

  String _postKey(HistoryRecord r) => 'p${r.id}';
  String _mediaKey(HistoryRecord r, int itemIndex) => 'm${r.id}:$itemIndex';

  void _enterSelection(String key) {
    HapticFeedback.mediumImpact();
    setState(() {
      _selectionMode = true;
      _selected
        ..clear()
        ..add(key);
    });
    widget.onSelectionModeChanged?.call(true);
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
    widget.onSelectionModeChanged?.call(false);
  }

  void _toggleSelection(String key) {
    setState(() {
      if (_selected.contains(key)) {
        _selected.remove(key);
      } else {
        _selected.add(key);
      }
    });
  }

  /// The set of all selectable keys in the current view.
  Set<String> get _allKeys {
    if (_view == HistoryView.posts) {
      return {for (final r in _filtered) _postKey(r)};
    }
    if (_view == HistoryView.all) {
      final keys = <String>{};
      for (final r in _filtered) {
        for (final f in r.files) {
          keys.add(_mediaKey(r, f.itemIndex));
        }
      }
      return keys;
    }
    return {};
  }

  void _selectAll() {
    final keys = _allKeys;
    setState(() {
      if (_selected.length == keys.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(keys);
      }
    });
  }

  List<HistoryRecord> get _selectedRecords {
    final ids = <int>{
      for (final k in _selected)
        if (k.startsWith('p'))
          int.tryParse(k.substring(1)) ?? -1
        else if (k.startsWith('m'))
          int.tryParse(k.substring(1).split(':').first) ?? -1,
    }..remove(-1);
    return _records.where((r) => ids.contains(r.id)).toList();
  }

  List<HistThumbRef> get _selectedMedia {
    final refs = <HistThumbRef>[];
    for (final k in _selected) {
      if (!k.startsWith('m')) continue;
      final parts = k.substring(1).split(':');
      if (parts.length != 2) continue;
      final id = int.tryParse(parts[0]);
      final idx = int.tryParse(parts[1]);
      if (id == null || idx == null) continue;
      HistoryRecord? record;
      for (final r in _records) {
        if (r.id == id) {
          record = r;
          break;
        }
      }
      if (record != null) refs.add(HistThumbRef(record, idx));
    }
    return refs;
  }

  // ----------------------------------------------------------------- actions

  Future<void> _openOriginal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
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
        PreviewPage.route(
          post: outcome.data,
          rawImages: outcome.rawImages,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      final isLoginRequired =
          e is ParseFailure && e.code == ParseErrorCode.loginRequired;
      final cachedPost = record.toPost();
      if (cachedPost.items.isNotEmpty) {
        Navigator.of(context).push(
          PreviewPage.route(post: cachedPost),
        );
        if (isLoginRequired) {
          final platform = platformFromKey(record.platform);
          LoginExpiredBus.markExpired(platform);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('已使用本地记录打开预览（重新解析需登录）'),
              action: SnackBarAction(
                label: '去登录',
                onPressed: () async {
                  final loggedIn = await Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (_) => LoginPage(platform: platform),
                    ),
                  );
                  if (loggedIn == true && mounted) await _reparse(record);
                },
              ),
            ),
          );
        }
        return;
      }

      if (isLoginRequired) {
        final platform = platformFromKey(record.platform);
        LoginExpiredBus.markExpired(platform);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('该内容需要登录后查看，请先登录'),
            action: SnackBarAction(
              label: '去登录',
              onPressed: () async {
                final loggedIn = await Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => LoginPage(platform: platform),
                  ),
                );
                if (loggedIn == true && mounted) await _reparse(record);
              },
            ),
          ),
        );
        return;
      }

      final msg = e is ParseFailure ? e.message : '$e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('解析失败：$msg')),
      );
    }
  }

  /// Build the fullscreen browser items for a record and open it.
  void _openRecord(HistoryRecord record, {int? highlightItemIndex}) {
    if (_opening) return;
    _opening = true;

    final post = record.toPost();
    final locator = GalleryLocatorService.instance;
    final files = [...record.files]..sort((a, b) => a.itemIndex.compareTo(b.itemIndex));
    final items = <GalleryBrowserItem>[];
    var initial = 0;

    if (files.isNotEmpty) {
      final is1Based = files.every((f) => f.itemIndex > 0);
      for (final f in files) {
        final zeroBasedIdx = is1Based ? f.itemIndex - 1 : f.itemIndex;
        MediaItem? postItem;
        if (zeroBasedIdx >= 0 && zeroBasedIdx < post.items.length) {
          postItem = post.items[zeroBasedIdx];
        } else if (f.itemIndex >= 0 && f.itemIndex < post.items.length) {
          postItem = post.items[f.itemIndex];
        }

        final asset = locator.getAssetById(f.mediaId) ??
            locator.locateAsset(f, record.postId);

        if (highlightItemIndex != null &&
            (f.itemIndex == highlightItemIndex || zeroBasedIdx == highlightItemIndex)) {
          initial = items.length;
        }

        items.add(
          GalleryBrowserItem(
            index: zeroBasedIdx,
            type: postItem?.type ?? (f.isImage ? 'image' : 'video'),
            url: postItem?.url ?? '',
            videoUrl: postItem?.videoUrl,
            posterUrl: postItem?.posterUrl,
            fallbacks: postItem?.fallbacks ?? const [],
            isGif: postItem?.isGif ?? false,
            asset: asset,
            status: f.status,
            filename: f.filename,
          ),
        );
      }
    }

    if (items.isEmpty && post.items.isNotEmpty) {
      for (var i = 0; i < post.items.length; i++) {
        final postItem = post.items[i];
        if (highlightItemIndex != null && i == highlightItemIndex) {
          initial = items.length;
        }
        items.add(
          GalleryBrowserItem(
            index: i,
            type: postItem.type,
            url: postItem.url,
            videoUrl: postItem.videoUrl,
            posterUrl: postItem.posterUrl,
            fallbacks: postItem.fallbacks,
            isGif: postItem.isGif ?? false,
            status: FileStatus.unknown,
          ),
        );
      }
    }

    if (items.isEmpty) {
      _opening = false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到可查看的媒体文件')),
      );
      return;
    }

    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => GalleryBrowserPage(
              items: items,
              initialIndex: initial,
              authorName: record.authorName ?? '',
              title: (record.title?.isNotEmpty == true)
                  ? record.title!
                  : record.postId,
              platform: record.platform,
              postUrl: record.postUrl,
              onReparse: () {
                Navigator.of(context).pop();
                _reparse(record);
              },
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

  Future<void> _shareRecords(List<HistoryRecord> records) async {
    final files = <XFile>[];
    final locator = GalleryLocatorService.instance;
    for (final r in records) {
      for (final f in r.files) {
        final asset =
            locator.getAssetById(f.mediaId) ?? locator.locateAsset(f, r.postId);
        if (asset == null) continue;
        try {
          final file = await asset.file;
          if (file != null && await file.exists()) files.add(XFile(file.path));
        } catch (_) {
          // Skip files we can't read.
        }
      }
    }
    final text = records.length == 1
        ? records.first.postUrl
        : records.map((r) => r.postUrl).join('\n');
    if (files.isEmpty) {
      await SharePlus.instance.share(ShareParams(text: text));
    } else {
      await SharePlus.instance.share(ShareParams(text: text, files: files));
    }
  }

  Future<void> _shareMedia(List<HistThumbRef> refs) async {
    final files = <XFile>[];
    final locator = GalleryLocatorService.instance;
    final urls = <String>{};
    for (final ref in refs) {
      final r = ref.record;
      urls.add(r.postUrl);
      HistoryFile? matched;
      for (final f in r.files) {
        if (f.itemIndex == ref.itemIndex) {
          matched = f;
          break;
        }
      }
      if (matched == null) continue;
      final asset =
          locator.getAssetById(matched.mediaId) ??
          locator.locateAsset(matched, r.postId);
      if (asset == null) continue;
      try {
        final file = await asset.file;
        if (file != null && await file.exists()) files.add(XFile(file.path));
      } catch (_) {
        // Skip unreadable files.
      }
    }
    final text = urls.join('\n');
    if (files.isEmpty) {
      await SharePlus.instance.share(ShareParams(text: text));
    } else {
      await SharePlus.instance.share(ShareParams(text: text, files: files));
    }
  }

  Future<void> _deleteRecords(List<HistoryRecord> records) async {
    final ids = records.map((r) => r.id).whereType<int>().toList();
    if (ids.isEmpty) return;

    final media = deletableMediaFor(records);
    if (!mounted) return;
    final result = await showDeleteRecordsSheet(
      context,
      recordCount: records.length,
      fileCount: media.length,
    );
    if (result == null || !mounted) return;

    final db = await HistoryDb.instance();
    if (!result.deleteFiles) {
      for (final id in ids) {
        await db.delete(id);
      }
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已删除 ${records.length} 条记录'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              for (final record in records) {
                await db.reinsert(record, reason: 'undo');
              }
              await _reload();
            },
          ),
        ),
      );
      return;
    }

    // Delete album files first (no undo), then the records.
    final approved = await MediaDeleteService.instance.deleteMedia(media);
    for (final id in ids) {
      await db.delete(id);
    }
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          approved
              ? '已删除 ${records.length} 条记录，并删除相册文件'
              : '相册文件已保留，仅删除历史记录',
        ),
      ),
    );
  }

  // ------------------------------------------------------------- grouping

  String _dateGroupTitle(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(time.year, time.month, time.day);
    final diff = today.difference(date).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff < 7) return '本周';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  static const _kindOrder = ['视频', 'Live 图', 'GIF', '图片'];

  List<_PostGroup> _groupPosts(List<HistoryRecord> posts) {
    switch (_sort) {
      case HistorySort.latest:
      case HistorySort.earliest:
        final sorted = [...posts]
          ..sort((a, b) {
            final cmp = _sort == HistorySort.latest
                ? b.createdAt.compareTo(a.createdAt)
                : a.createdAt.compareTo(b.createdAt);
            if (cmp != 0) return cmp;
            final aId = a.id ?? 0;
            final bId = b.id ?? 0;
            return _sort == HistorySort.latest
                ? bId.compareTo(aId)
                : aId.compareTo(bId);
          });
        final groups = <_PostGroup>[];
        for (final r in sorted) {
          final title = _dateGroupTitle(r.createdAt);
          if (groups.isNotEmpty && groups.last.title == title) {
            groups.last.posts.add(r);
          } else {
            groups.add(_PostGroup(title, [r]));
          }
        }
        return groups;
      case HistorySort.type:
        final byKind = <String, List<HistoryRecord>>{};
        for (final r in posts) {
          byKind.putIfAbsent(postKindLabel(r), () => []).add(r);
        }
        final ordered = _kindOrder.where(byKind.containsKey).toList()
          ..addAll(byKind.keys.where((k) => !_kindOrder.contains(k)));
        return [
          for (final kind in ordered)
            _PostGroup('$kind · ${byKind[kind]!.length}', byKind[kind]!),
        ];
      case HistorySort.mostFiles:
        final sorted = [...posts]
          ..sort(
            (a, b) => (b.files.isNotEmpty ? b.files.length : b.fileCount)
                .compareTo(a.files.isNotEmpty ? a.files.length : a.fileCount),
          );
        return [_PostGroup('', sorted)];
      case HistorySort.author:
        final byAuthor = <String, List<HistoryRecord>>{};
        for (final r in posts) {
          byAuthor.putIfAbsent(r.authorName ?? '未知作者', () => []).add(r);
        }
        final authors = byAuthor.keys.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        return [
          for (final a in authors)
            _PostGroup('$a · ${byAuthor[a]!.length}', byAuthor[a]!),
        ];
    }
  }

  List<_MediaGroup> _groupMedia(List<HistoryRecord> records) {
    final all = <HistThumbRef>[];
    for (final r in records) {
      for (final f in r.files) {
        all.add(HistThumbRef(r, f.itemIndex));
      }
    }
    switch (_sort) {
      case HistorySort.latest:
      case HistorySort.earliest:
        all.sort((a, b) {
          final av = _fileSavedAt(a);
          final bv = _fileSavedAt(b);
          return _sort == HistorySort.latest
              ? bv.compareTo(av)
              : av.compareTo(bv);
        });
        final groups = <_MediaGroup>[];
        for (final ref in all) {
          final title = _dateGroupTitle(_fileSavedAt(ref));
          if (groups.isNotEmpty && groups.last.title == title) {
            groups.last.media.add(ref);
          } else {
            groups.add(_MediaGroup(title, [ref]));
          }
        }
        return groups;
      case HistorySort.type:
        final byKind = <String, List<HistThumbRef>>{};
        for (final ref in all) {
          final post = ref.record.toPost();
          final is1Based = ref.record.files.isNotEmpty && ref.record.files.every((f) => f.itemIndex > 0);
          final zeroBased = is1Based ? ref.itemIndex - 1 : ref.itemIndex;
          final item = (zeroBased >= 0 && zeroBased < post.items.length)
              ? post.items[zeroBased]
              : ((ref.itemIndex >= 0 && ref.itemIndex < post.items.length)
                  ? post.items[ref.itemIndex]
                  : null);
          byKind.putIfAbsent(mediaKindLabel(item), () => []).add(ref);
        }
        final ordered = _kindOrder.where(byKind.containsKey).toList()
          ..addAll(byKind.keys.where((k) => !_kindOrder.contains(k)));
        return [
          for (final kind in ordered)
            _MediaGroup('$kind · ${byKind[kind]!.length}', byKind[kind]!),
        ];
      case HistorySort.mostFiles:
        all.sort((a, b) {
          final av = a.record.files.length;
          final bv = b.record.files.length;
          return bv.compareTo(av);
        });
        return [_MediaGroup('', all)];
      case HistorySort.author:
        final byAuthor = <String, List<HistThumbRef>>{};
        for (final ref in all) {
          byAuthor.putIfAbsent(ref.record.authorName ?? '未知作者', () => [])
              .add(ref);
        }
        final authors = byAuthor.keys.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        return [
          for (final a in authors)
            _MediaGroup('$a · ${byAuthor[a]!.length}', byAuthor[a]!),
        ];
    }
  }

  DateTime _fileSavedAt(HistThumbRef ref) {
    for (final f in ref.record.files) {
      if (f.itemIndex == ref.itemIndex) {
        return DateTime.fromMillisecondsSinceEpoch(f.savedAt);
      }
    }
    return ref.record.createdAt;
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Scaffold(
        appBar: _selectionMode ? _selectionAppBar() : _appBar(),
        body: Column(
          children: [
            _permissionBanners(),
            if (!_selectionMode) _viewSwitcher(),
            if (_searchOpen && !_selectionMode) _searchField(),
            Expanded(child: _body()),
          ],
        ),
        bottomNavigationBar: _selectionMode ? _selectionBottomBar() : null,
      ),
    );
  }

  PreferredSizeWidget _appBar() {
    final filtered = _filtered;
    final fileCount = filtered.fold<int>(
      0,
      (sum, r) => sum + (r.files.isNotEmpty ? r.files.length : r.fileCount),
    );
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('历史'),
          Text(
            '${filtered.length} 个帖子 · $fileCount 个文件',
            style: const TextStyle(
              fontSize: 12,
              color: AppTokens.textSecondary,
              fontWeight: FontWeight.normal,
            ),
          ),
        ],
      ),
      actions: [
        _toolbarButton(
          icon: Icons.search,
          active: _searchOpen || _query.trim().isNotEmpty,
          tooltip: '搜索',
          onTap: () => setState(() {
            _searchOpen = !_searchOpen;
            if (!_searchOpen) {
              _query = '';
              _searchController.clear();
            }
          }),
        ),
        _platformMenu(),
        if (_view != HistoryView.creators) _sortMenu(),
        if (_view == HistoryView.posts)
          _toolbarButton(
            icon: _layout == HistoryLayout.waterfall
                ? Icons.view_list
                : Icons.grid_view,
            active: false,
            tooltip: _layout == HistoryLayout.waterfall ? '切换列表' : '切换瀑布流',
            onTap: () {
              setState(() {
                _layout = _layout == HistoryLayout.waterfall
                    ? HistoryLayout.list
                    : HistoryLayout.waterfall;
              });
              _persistPrefs();
            },
          ),
        if (_records.isNotEmpty)
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) {
              if (v == 'clear') _confirmClearAll();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('清空历史记录')),
            ],
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    final keys = _allKeys;
    final allSelected = keys.isNotEmpty && _selected.length == keys.length;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitSelection,
      ),
      title: Text(
        '已选 ${_selected.length} 项',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      actions: [
        if (_view != HistoryView.creators)
          TextButton(
            onPressed: _selectAll,
            child: Text(allSelected ? '取消全选' : '全选'),
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _selectionBottomBar() {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          boxShadow: AppTokens.cardShadow,
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  backgroundColor: SecondaryBg.beige(context),
                  foregroundColor: scheme.onSurface,
                  side: BorderSide(
                    color: scheme.outline.withValues(alpha: 0.6),
                  ),
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                icon: const Icon(Icons.share, size: 18),
                label: const Text('分享'),
                onPressed: _selected.isEmpty
                    ? null
                    : () {
                        if (_view == HistoryView.all) {
                          _shareMedia(_selectedMedia);
                        } else {
                          _shareRecords(_selectedRecords);
                        }
                      },
              ),
            ),
            if (_view == HistoryView.posts) ...[
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTokens.primary,
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('删除'),
                  onPressed: _selected.isEmpty
                      ? null
                      : () async {
                          final records = _selectedRecords;
                          _exitSelection();
                          await _deleteRecords(records);
                        },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _permissionBanners() {
    final locator = GalleryLocatorService.instance;
    if (locator.isDenied) {
      return _banner(
        color: Colors.amber.shade50,
        border: Colors.amber.shade200,
        textColor: Colors.amber.shade900,
        icon: Icons.info_outline,
        text: '未获得相册权限，无法定位本地文件',
        actionLabel: '去设置',
        onAction: () => locator.openSettings(),
      );
    }
    // Not yet granted (never asked / dismissed): offer to grant. Android 14
    // partial authorization is handled by the limited branch below.
    if (!locator.hasAccess) {
      return _banner(
        color: Colors.blue.shade50,
        border: Colors.blue.shade200,
        textColor: Colors.blue.shade900,
        icon: Icons.photo_outlined,
        text: '授权相册访问后可显示缩略图',
        actionLabel: '授权',
        onAction: () => locator.requestPermission(),
      );
    }
    if (locator.isLimited) {
      return _banner(
        color: Colors.blue.shade50,
        border: Colors.blue.shade200,
        textColor: Colors.blue.shade900,
        icon: Icons.info_outline,
        text: '仅授权了部分照片，未授权的媒体无法显示',
        actionLabel: '管理权限',
        onAction: () => locator.reRequestLimited(),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _banner({
    required Color color,
    required Color border,
    required Color textColor,
    required IconData icon,
    required String text,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Icon(icon, color: textColor, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: textColor, fontSize: 13)),
          ),
          TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }

  Widget _viewSwitcher() {
    final segments = <(HistoryView, String)>[
      (HistoryView.posts, '帖子'),
      (HistoryView.all, '全部'),
      (HistoryView.creators, '创作者'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: SecondaryBg.beige(context),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: [
                for (final (view, label) in segments)
                  GestureDetector(
                    onTap: () {
                      if (_view == view) return;
                      setState(() {
                        _view = view;
                        _selected.clear();
                        _selectionMode = false;
                      });
                      widget.onSelectionModeChanged?.call(false);
                      _persistPrefs();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _view == view
                            ? Theme.of(context).cardColor
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: _view == view
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Spacer(),
          if (_author != null)
            _filterChip(_author!, () => setState(() => _author = null)),
          if (_platform != 'all')
            _filterChip(
              _platformLabel(_platform),
              () => setState(() => _platform = 'all'),
            ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, VoidCallback onClear) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Chip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        deleteIcon: const Icon(Icons.close, size: 14),
        onDeleted: onClear,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: SecondaryBg.pink(context),
        side: BorderSide.none,
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: '搜索标题或作者',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() {
                    _query = '';
                    _searchController.clear();
                  }),
                ),
          filled: true,
          fillColor: Theme.of(context).cardColor,
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    required bool active,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? SecondaryBg.pink(context) : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18),
          ),
        ),
      ),
    );
  }

  Widget _platformMenu() {
    return PopupMenuButton<String>(
      tooltip: '平台筛选',
      onSelected: (v) => setState(() => _platform = v),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'all', child: Text('全部')),
        PopupMenuItem(value: 'xhs', child: Text('小红书')),
        PopupMenuItem(value: 'instagram', child: Text('Instagram')),
        PopupMenuItem(value: 'x', child: Text('X')),
      ],
      child: _toolbarButtonInner(
        icon: Icons.filter_list,
        active: _platform != 'all',
      ),
    );
  }

  Widget _sortMenu() {
    return PopupMenuButton<HistorySort>(
      tooltip: '排序',
      onSelected: (v) {
        setState(() => _sort = v);
        _persistPrefs();
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: HistorySort.latest, child: Text('最新保存')),
        PopupMenuItem(value: HistorySort.earliest, child: Text('最早保存')),
        PopupMenuItem(value: HistorySort.type, child: Text('按类型')),
        PopupMenuItem(value: HistorySort.mostFiles, child: Text('文件最多')),
        PopupMenuItem(value: HistorySort.author, child: Text('按作者')),
      ],
      child: _toolbarButtonInner(
        icon: Icons.swap_vert,
        active: _sort != HistorySort.latest,
      ),
    );
  }

  Widget _toolbarButtonInner({required IconData icon, required bool active}) {
    return Container(
      width: 34,
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? SecondaryBg.pink(context) : Colors.transparent,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 18),
    );
  }

  String _platformLabel(String key) => switch (key) {
    'xhs' => '小红书',
    'instagram' => 'Instagram',
    'x' => 'X',
    _ => '全部',
  };

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
    if (_records.isEmpty) {
      return _emptyAll();
    }
    if (_filtered.isEmpty) {
      return _emptyFiltered();
    }
    switch (_view) {
      case HistoryView.posts:
        return _layout == HistoryLayout.waterfall
            ? _postsWaterfall()
            : _postsList();
      case HistoryView.all:
        return _allWaterfall();
      case HistoryView.creators:
        return _creators();
    }
  }

  Widget _emptyAll() {
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
          const Text('还没有下载记录，去首页解析第一条帖子吧'),
          const SizedBox(height: 8),
          FilledButton(onPressed: widget.onGoParse, child: const Text('去解析')),
        ],
      ),
    );
  }

  Widget _emptyFiltered() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 64, color: AppTokens.textSecondary),
          const SizedBox(height: 12),
          const Text('没有找到匹配的记录'),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _clearFilters, child: const Text('清除筛选')),
        ],
      ),
    );
  }

  Widget _refreshWrapper(Widget child) {
    return RefreshIndicator(
      onRefresh: () async {
        final locator = GalleryLocatorService.instance;
        if (locator.hasAccess) {
          await locator.scanAlbum(force: true);
        }
        await _reload();
      },
      child: child,
    );
  }

  Widget _stickyHeader(String title) {
    final title0 = title;
    if (title0.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverPersistentHeader(
      pinned: true,
      delegate: _StickyHeaderDelegate(
        title: title0,
        background: Theme.of(context).scaffoldBackgroundColor,
      ),
    );
  }

  /// A masonry block for one group: a shrink-wrapped grid inside a
  /// SliverToBoxAdapter so the sliver reports an exact height (avoids the
  /// sliver-masonry extent estimate that caused the scroll to jump back and
  /// stop short of the bottom).
  Widget _groupGrid({
    required int count,
    required Widget Function(BuildContext, int) itemBuilder,
  }) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: MasonryGridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 8,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: count,
          itemBuilder: itemBuilder,
        ),
      ),
    );
  }

  Widget _postsWaterfall() {
    final groups = _groupPosts(_filtered);
    return _refreshWrapper(
      CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          for (final group in groups) ...[
            _stickyHeader(group.title),
            _groupGrid(
              count: group.posts.length,
              itemBuilder: (context, index) {
                final record = group.posts[index];
                final key = _postKey(record);
                return WaterfallPostCard(
                  key: ValueKey('wf-${record.id}'),
                  record: record,
                  selectionMode: _selectionMode,
                  selected: _selected.contains(key),
                  onTap: () => _openRecord(record),
                  onLongPress: () => _enterSelection(key),
                  onToggleSelect: () => _toggleSelection(key),
                );
              },
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }

  Widget _postsList() {
    final groups = _groupPosts(_filtered);
    return _refreshWrapper(
      CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          for (final group in groups) ...[
            _stickyHeader(group.title),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final record = group.posts[index];
                  final key = _postKey(record);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Dismissible(
                      key: ValueKey('row-${record.id}'),
                      direction: _selectionMode
                          ? DismissDirection.none
                          : DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        decoration: BoxDecoration(
                          color: AppTokens.primary,
                          borderRadius: BorderRadius.circular(
                            AppTokens.cardRadius,
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.delete_outline, color: Colors.white),
                            SizedBox(width: 6),
                            Text(
                              '删除',
                              style: TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                      confirmDismiss: (_) async {
                        await _deleteRecords([record]);
                        return false;
                      },
                      child: ListPostRow(
                        record: record,
                        selectionMode: _selectionMode,
                        selected: _selected.contains(key),
                        onTap: () => _openRecord(record),
                        onLongPress: () => _enterSelection(key),
                        onToggleSelect: () => _toggleSelection(key),
                        onReparse: () => _reparse(record),
                        onOpenOriginal: () => _openOriginal(record.postUrl),
                      ),
                    ),
                  );
                }, childCount: group.posts.length),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _allWaterfall() {
    final groups = _groupMedia(_filtered);
    return _refreshWrapper(
      CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          for (final group in groups) ...[
            _stickyHeader(group.title),
            _groupGrid(
              count: group.media.length,
              itemBuilder: (context, index) {
                final ref = group.media[index];
                final key = _mediaKey(ref.record, ref.itemIndex);
                return AllMediaCard(
                  key: ValueKey('all-${ref.record.id}-${ref.itemIndex}'),
                  record: ref.record,
                  itemIndex: ref.itemIndex,
                  selectionMode: _selectionMode,
                  selected: _selected.contains(key),
                  onTap: () =>
                      _openRecord(ref.record, highlightItemIndex: ref.itemIndex),
                  onLongPress: () => _enterSelection(key),
                  onToggleSelect: () => _toggleSelection(key),
                );
              },
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }

  Widget _creators() {
    final creators = _creatorGroups(_filtered);
    return _refreshWrapper(
      GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
          childAspectRatio: 0.72,
        ),
        itemCount: creators.length,
        itemBuilder: (context, index) {
          final c = creators[index];
          return CreatorCard(
            authorName: c.authorName,
            platform: c.platform,
            postCount: c.postCount,
            fileCount: c.fileCount,
            thumbs: c.thumbs,
            onTap: () => setState(() {
              _view = HistoryView.posts;
              _author = c.authorName;
            }),
          );
        },
      ),
    );
  }

  List<_CreatorGroup> _creatorGroups(List<HistoryRecord> records) {
    final map = <String, _CreatorGroup>{};
    for (final r in records) {
      final author = r.authorName ?? '';
      final group = map.putIfAbsent(
        author,
        () => _CreatorGroup(authorName: author, platform: r.platform),
      );
      group.postCount++;
      group.fileCount += r.files.isNotEmpty ? r.files.length : r.fileCount;
      if (group.thumbs.length < 4) {
        for (final f in r.files) {
          if (group.thumbs.length >= 4) break;
          group.thumbs.add(HistThumbRef(r, f.itemIndex));
        }
      }
    }
    final list = map.values.toList()
      ..sort(
        (a, b) =>
            a.authorName.toLowerCase().compareTo(b.authorName.toLowerCase()),
      );
    return list;
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
}

class _PostGroup {
  _PostGroup(this.title, this.posts);
  final String title;
  final List<HistoryRecord> posts;
}

class _MediaGroup {
  _MediaGroup(this.title, this.media);
  final String title;
  final List<HistThumbRef> media;
}

class _CreatorGroup {
  _CreatorGroup({required this.authorName, required this.platform});
  final String authorName;
  final String platform;
  int postCount = 0;
  int fileCount = 0;
  final List<HistThumbRef> thumbs = [];
}

class _StickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  _StickyHeaderDelegate({required this.title, required this.background});

  final String title;
  final Color background;

  @override
  double get minExtent => 34;
  @override
  double get maxExtent => 34;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: background,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(left: 16, top: 6, bottom: 4),
      child: Text(
        title,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _StickyHeaderDelegate oldDelegate) =>
      oldDelegate.title != title || oldDelegate.background != background;
}
