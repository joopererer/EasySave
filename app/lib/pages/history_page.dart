// History tab (ui-spec §2.4): three views (帖子 / 全部 / 创作者), waterfall and
// list layouts, compact toolbar with search / platform filter / sort / layout,
// sticky grouping, local-album thumbnails, multi-select and delete.
//
// Reuses GalleryLocatorService for local file resolution and GalleryBrowserPage
// for fullscreen viewing — no parallel implementations.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import '../services/auth.dart';
import '../services/creator_sort.dart';
import '../services/download_manager.dart';
import '../services/gallery_locator_service.dart';
import '../services/history_backfill_service.dart';
import '../services/history_db.dart';
import '../services/history_decode_check.dart';
import '../services/history_deletion.dart';
import '../services/history_io.dart';
import '../services/history_scroll_memory.dart';
import '../services/host_bridge.dart';
import '../services/live_pairs.dart';
import '../services/media_delete_service.dart';
import '../services/network_status.dart';
import '../services/parse_service.dart';
import '../services/perf_trace.dart';
import '../services/settings.dart';
import '../services/site_registry.dart';
import '../theme/app_theme.dart';
import '../widgets/balanced_masonry_view.dart';
import '../widgets/delete_records_sheet.dart';
import '../widgets/gallery_browser.dart';
import '../widgets/history_browser_flow.dart';
import '../widgets/history_cards.dart';
import 'download_queue_page.dart';
import 'login_page.dart';
import 'preview_page.dart';

@visibleForTesting
Widget historyGroupSliver({
  required String title,
  required Color background,
  required Widget content,
}) {
  return SliverMainAxisGroup(
    slivers: [
      if (title.isNotEmpty)
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickyHeaderDelegate(title: title, background: background),
        ),
      content,
    ],
  );
}

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

  /// Records this page removed, by id and by `platform:postId`, with the moment
  /// their delete committed (v1.11 build 59).
  ///
  /// Only a read that *started* before that moment can still return the row, so
  /// only such a read suppresses it; the entry is dropped as soon as a read
  /// that started after the delete lands. Keeping it for the session instead
  /// hid every post the page had deleted once — including one a later download
  /// brought back (`restoreDeleted`), which the database and the home list were
  /// already showing.
  final Map<int, DateTime> _deletedRecordIds = {};
  final Map<String, DateTime> _deletedPostKeys = {};

  bool _loading = true;
  String? _dbError;
  bool _opening = false;

  AppSettings? _settings;
  HistoryView _view = HistoryView.posts;
  HistoryLayout _layout = HistoryLayout.waterfall;
  HistorySort _sort = HistorySort.latest;

  /// 创作者 view ordering. A pure in-memory sort over the groups already
  /// derived from [_records]; it never adds a query or a native call.
  CreatorSort _creatorSort = CreatorSortState.defaults.mode;
  bool _creatorSortDescending = CreatorSortState.defaults.descending;

  bool _searchOpen = false;
  String _query = '';
  final _searchController = TextEditingController();
  String _platform = 'all';
  String? _author;

  bool _selectionMode = false;

  /// The [ModeSwitch] measurement of the switch in progress (v1.11 batch 3).
  ModeSwitchProbe? _modeSwitch;

  /// The modes entered so far and the last widget built for each, created the
  /// first time that mode is entered (v1.11 batch 3). Only the mode in view is
  /// ever in the tree.
  final Map<HistoryView, Widget> _modeSubtrees = {};

  /// Modes whose data changed while they were hidden. Nothing is rebuilt in
  /// them; the flag is cleared the moment they come back and are rebuilt from
  /// the current data.
  final Set<HistoryView> _modePendingUpdate = {};

  /// One scroll controller per mode. Each mode owns its own, so a list never
  /// inherits the offset of another; the offset itself comes from
  /// [_scrollMemory], keyed by mode + filter + sort (v1.11 batch 3).
  final Map<HistoryView, ScrollController> _modeScroll = {};

  /// Remembered positions, by mode + filter + sort (v1.11 batch 3).
  final HistoryScrollMemory _scrollMemory = HistoryScrollMemory();

  /// One key per card, so the card the user was looking at can be found again
  /// after a data update reorders the list.
  final Map<String, GlobalKey> _anchors = <String, GlobalKey>{};

  /// A position waiting for the target list to exist and have a height.
  _PendingScroll? _pendingScroll;
  int _pendingFrames = 0;

  /// Whether the floating "back to top" button is currently visible (v1.12.1 Item C).
  bool _showScrollToTop = false;

  /// Keys & cached threshold for first-row visibility detection (v1.13 P0-5).
  final GlobalKey _scrollContainerKey = GlobalKey();
  final GlobalKey _firstRowKey = GlobalKey();
  double? _cachedFirstRowThreshold;
  static const double _scrollHysteresisDp = 8.0;

  /// Post IDs for new items received while the user was away from the top (v1.12.1 Item D).
  final Set<String> _pendingNewPostIds = {};

  /// Post IDs currently receiving a 1.5s subtle visual highlight after returning to top (v1.12.1 Item D).
  Set<String> _highlightedPostIds = {};
  Timer? _highlightTimer;

  // Keys: posts view -> 'p{recordId}'; all view -> 'm{recordId}:{itemIndex}'.
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GalleryLocatorService.instance.addListener(_onLocatorChanged);
    HostBridge.historyRevision.addListener(_onHostHistoryChanged);
    DownloadManager.instance.addListener(_refreshDownloads);
    // Connectivity only changes what the cards say while a batch waits.
    NetworkStatus.instance.addListener(_refreshDownloads);
    // Batches of the other engine only exist as snapshots, so poll them.
    _downloadPoll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshDownloads(),
    );
    _refreshDownloads();
    unawaited(_attachDbListener());
    _init();
  }

  HistoryDb? _listenedDb;

  Future<void> _attachDbListener() async {
    try {
      final db = await HistoryDb.instance();
      if (!mounted) return;
      _listenedDb = db;
      db.addListener(_onDbChanged);
    } catch (_) {}
  }

  void _onDbChanged() {
    if (!mounted) return;
    final reason = _listenedDb?.lastChangeReason ?? '';
    // Gallery scans and file repairs update file-location metadata on existing
    // records; reloading the whole page per scanned post would storm the DB.
    if (reason.startsWith('gallery scan') || reason.startsWith('file repair')) {
      return;
    }
    unawaited(_reload());
  }

  Timer? _downloadPoll;
  bool _refreshingDownloads = false;

  /// Unfinished batches (placeholder cards + queue badge).
  List<DownloadBatch> _unfinished = const [];

  /// postId -> 0..1 for posts that are being downloaded right now.
  Map<String, double> _downloadProgress = const {};

  /// postId -> unfinished batch, for the pause / cancel controls on a card.
  Map<String, DownloadBatch> _downloadBatches = const {};
  Set<String> _lastFinishing = const {};
  Map<String, String?> _lastStatus = const {};

  bool _isPaused(String postId) => _downloadBatches[postId]?.isPaused ?? false;
  bool _isFailed(String postId) => _downloadBatches[postId]?.isTerminal == true &&
      (_downloadBatches[postId]?.failedCount ?? 0) > 0;

  /// A failed post with no download batch in memory (after a restart or a
  /// backup restore) keeps its failure on the record; its retry re-parses the
  /// original link.
  bool _recordFailed(HistoryRecord record) =>
      _downloadBatches[record.postId] == null && record.downloadError != null;

  bool _isStalled(String postId) =>
      _downloadBatches[postId]?.isStalledAt(
        DateTime.now().millisecondsSinceEpoch,
      ) ??
      false;

  /// Pause, resume or (when stalled) restart the download of [postId].
  Future<void> _toggleDownload(String postId) async {
    final batch = _downloadBatches[postId];
    if (batch == null) return;
    final dm = DownloadManager.instance;
    try {
      if (batch.isTerminal && batch.failedCount > 0) {
        await dm.retryBatch(await dm.forceAdopt(batch));
      } else if (batch.isPaused) {
        await dm.resumeBatch(batch);
      } else if (batch.isStalledAt(DateTime.now().millisecondsSinceEpoch)) {
        await dm.restartBatch(await dm.forceAdopt(batch));
      } else {
        await dm.pauseBatch(batch);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败，请稍后重试')),
        );
      }
    }
    unawaited(_refreshDownloads());
  }

  /// Cancel the download of [postId] after a confirm; the half-made
  /// placeholder record is discarded by the manager.
  Future<void> _cancelDownload(String postId) async {
    final batch = _downloadBatches[postId];
    if (batch == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消下载？'),
        content: const Text('取消并删除已下载部分？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('保留'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('取消并删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final dm = DownloadManager.instance;
      await dm.cancelBatch(await dm.forceAdopt(batch), source: 'history_card');
    } catch (_) {
      // The next refresh shows the real state.
    }
    unawaited(_refreshDownloads());
    unawaited(_reload());
  }

  Future<void> _refreshDownloads() async {
    if (_refreshingDownloads || !mounted) return;
    _refreshingDownloads = true;
    try {
      final all = await DownloadManager.instance.liveBatches().timeout(const Duration(seconds: 2));
      if (!mounted) return;
      final unfinished = [for (final b in all)
        if (!b.cancelledByDeletion && (!b.isTerminal || b.failedCount > 0)) b];
      final progress = <String, double>{
        for (final b in unfinished) b.postId: b.progress,
      };
      final pausedNow = {
        for (final b in unfinished)
          if (b.isPaused) b.postId,
      };
      final finishingNow = {
        for (final b in unfinished)
          for (final j in b.jobs)
            if (j.isFinishing) '${b.postId}:${j.savingPhase}',
      };
      final statusNow = {
        for (final b in unfinished) b.postId: b.statusText,
      };
      final changed = progress.length != _downloadProgress.length ||
          unfinished.length != _unfinished.length ||
          pausedNow.length !=
              _downloadBatches.values.where((b) => b.isPaused).length ||
          progress.entries.any(
            (e) => (_downloadProgress[e.key] ?? -1) != e.value,
          ) ||
          !setEquals(finishingNow, _lastFinishing) ||
          !mapEquals(statusNow, _lastStatus);
      if (changed) {
        setState(() {
          _markHiddenModesPending();
          _unfinished = unfinished;
          _downloadProgress = progress;
          _downloadBatches = {for (final b in unfinished) b.postId: b};
          _lastFinishing = finishingNow;
          _lastStatus = statusNow;
        });
      } else {
        // Same numbers, but keep the batch objects fresh for the actions.
        _downloadBatches = {for (final b in unfinished) b.postId: b};
      }
    } catch (_) {
      // Progress display is best effort.
    } finally {
      _refreshingDownloads = false;
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _historyRefresh.dispose();
    _modeSwitch?.dispose();
    for (final controller in _modeScroll.values) {
      controller.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    GalleryLocatorService.instance.removeListener(_onLocatorChanged);
    HostBridge.historyRevision.removeListener(_onHostHistoryChanged);
    _listenedDb?.removeListener(_onDbChanged);
    _listenedDb = null;
    DownloadManager.instance.removeListener(_refreshDownloads);
    NetworkStatus.instance.removeListener(_refreshDownloads);
    _downloadPoll?.cancel();
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
      _creatorSort = settings.creatorSort;
      _creatorSortDescending = settings.creatorSortDescending;
    });
    await _initPermissionsAndLoad();
  }

  Future<void> _persistPrefs() async {
    final settings = _settings;
    if (settings == null) return;
    settings.historyView = _view;
    settings.historyLayout = _layout;
    settings.historySort = _sort;
    settings.creatorSort = _creatorSort;
    settings.creatorSortDescending = _creatorSortDescending;
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
    if (!mounted) return;
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

  final _historyRefresh = HistoryRefreshController();
  Future<void> _reload() => _historyRefresh.refresh(_reloadRecords, () async {
    final locator = GalleryLocatorService.instance;
    if (locator.hasAccess) {
      HistoryDb.logRefreshTrigger('*', 'media-refresh');
      await locator.preloadMediaIds(_records);
      if (mounted) setState(() {});
    }
  });

  Future<void> _reloadRecords() async {
    if (!mounted) return;
    final silent = _records.isNotEmpty;
    if (!silent) {
      setState(() {
        _loading = true;
        _dbError = null;
      });
    }
    // New or deleted records must not move the list: the card under the top
    // edge is held where it is (v1.11 batch 3). A read that changes nothing
    // restores the same offset, so pull-to-refresh is unchanged.
    final anchor = _captureAnchor();
    final offset = _activeOffset;
    // Only a read that started before a delete committed can still return the
    // deleted rows (v1.11 build 59).
    final readStartedAt = DateTime.now();
    try {
      final records = await retryHistoryRead(
          () => HistoryDb.instance().then((db) => db.recent(limit: 10000)),
          deadline: _historyRefresh.deadline);
      if (!mounted) return;
      final oldPostIds = _records.map((r) => r.postId).toSet();
      final hadRecordsBefore = _records.isNotEmpty;
      final newRecords = dropDeletedRecords(
        records,
        ids: _suppressedIds(readStartedAt),
        postKeys: _suppressedPostKeys(readStartedAt),
      );
      final incomingPostIds = newRecords.map((r) => r.postId).toSet();
      final addedPostIds = incomingPostIds.difference(oldPostIds);

      final isAwayFromTop = _isAwayFromTop(offset);
      final isUserScrolling =
          _activeAttached &&
          _activeController.hasClients &&
          _activeController.position.isScrollingNotifier.value;
      final shouldAutoScrollToTop =
          hadRecordsBefore &&
          addedPostIds.isNotEmpty &&
          !isAwayFromTop &&
          !isUserScrolling;

      setState(() {
        _markHiddenModesPending();
        _records = newRecords;
        if (hadRecordsBefore && isAwayFromTop && addedPostIds.isNotEmpty) {
          _pendingNewPostIds.addAll(addedPostIds);
        } else if (!isAwayFromTop) {
          _pendingNewPostIds.clear();
        }
        _loading = false;
        _dbError = null;
      });
      // Reads are serialised (one refresh at a time), so a delete older than
      // this read has served its purpose and can no longer be needed.
      _forgetDeletionsBefore(readStartedAt);
      if (shouldAutoScrollToTop) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            unawaited(_scrollToTop());
          }
        });
      } else {
        _scheduleScroll(
          offset,
          anchorKey: anchor?.key,
          anchorDelta: anchor?.top ?? 0,
        );
      }
      // A quiet, read-only pass over stills the album already holds: a HEIC
      // this device cannot decode is marked so its card can say so. It runs
      // once per session, one file at a time, and never opens a decode path
      // that could stall the page.
      unawaited(HistoryDecodeCheck.runOnce());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _dbError = _records.isEmpty ? '$e' : null;
      });
      if (e is TimeoutException) HistoryDb.retryPendingOpen();
    }
  }

  // ---------------------------------------------------------------- filtering

  List<HistoryRecord> get _filtered {
    final q = _query.trim().toLowerCase();
    return _records.where((r) {
      if (_platform != 'all' && !SiteRegistry.current.sameSite(r.platform, _platform)) return false;
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
    _afterPositionKeyChange();
  }

  // ------------------------------------------------------- scroll positions

  /// The position the list is remembered at: mode + filter + sort (v1.11 batch
  /// 3). The layout is deliberately not part of it — switching 瀑布流 ↔ 列表
  /// keeps the card the user was looking at instead of starting a new position.
  HistoryScrollKey get _positionKey => HistoryScrollKey(
    view: _view.name,
    author: _author,
    platform: _platform,
    query: _query,
    sort: _sort.name,
    creatorSort: _creatorSort.name,
    creatorSortDescending: _creatorSortDescending,
  );

  ScrollController get _activeController =>
      _modeScroll.putIfAbsent(_view, () => _newController(_view));

  ScrollController _newController(HistoryView view) {
    final created = ScrollController();
    // Every scroll is remembered at the key it belongs to, so switching away
    // and back always finds the place it was left at.
    created.addListener(() {
      if (view == _view) {
        _rememberScrollNow();
        _updateScrollMetrics();
      }
    });
    return created;
  }

  Widget _wrapFirstRow(bool isFirst, Widget child) {
    if (!isFirst) return child;
    return KeyedSubtree(key: _firstRowKey, child: child);
  }

  double? _measureFirstRowThreshold(double offset) {
    final itemCtx = _firstRowKey.currentContext;
    if (itemCtx != null) {
      final itemBox = itemCtx.findRenderObject() as RenderBox?;
      if (itemBox != null && itemBox.attached && itemBox.hasSize) {
        final viewport = RenderAbstractViewport.maybeOf(itemBox);
        if (viewport != null) {
          final revealOffset = viewport.getOffsetToReveal(itemBox, 0.0).offset;
          if (revealOffset.isFinite && revealOffset >= 0) {
            final threshold = revealOffset + itemBox.size.height;
            if (threshold.isFinite && threshold > 0) {
              _cachedFirstRowThreshold = threshold;
            }
          }
        }
      }
    }
    return _cachedFirstRowThreshold;
  }

  bool _isAwayFromTop(double offset) {
    final threshold = _measureFirstRowThreshold(offset);
    if (threshold == null) {
      return offset > _scrollHysteresisDp;
    }
    final hideThreshold =
        (threshold - _scrollHysteresisDp).clamp(0.0, double.infinity);
    return _showScrollToTop ? offset > hideThreshold : offset > threshold;
  }

  void _updateScrollMetrics() {
    if (!mounted || !_activeAttached) return;
    final controller = _activeController;
    if (!controller.hasClients) return;
    final offset = controller.offset;

    final shouldShow = _isAwayFromTop(offset);

    if (shouldShow != _showScrollToTop) {
      setState(() {
        _showScrollToTop = shouldShow;
      });
    }

    // D3: User manually scrolls back to top -> dismiss new content banner and highlight
    if ((!shouldShow || offset <= 10.0) && _pendingNewPostIds.isNotEmpty) {
      _consumePendingNewPosts();
    }
  }

  void _consumePendingNewPosts() {
    if (_pendingNewPostIds.isEmpty) return;
    _highlightTimer?.cancel();
    setState(() {
      _highlightedPostIds = Set<String>.from(_pendingNewPostIds);
      _pendingNewPostIds.clear();
    });
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() {
        _highlightedPostIds.clear();
      });
    });
  }

  Future<void> _onTapNewContentBanner() async {
    _consumePendingNewPosts();
    await _scrollToTop();
  }

  Widget _buildNewContentBanner() {
    final count = _pendingNewPostIds.length;
    final show = count > 0;
    return AnimatedOpacity(
      opacity: show ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      child: IgnorePointer(
        ignoring: !show,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(20),
          color: Theme.of(context).colorScheme.primaryContainer,
          shadowColor: Colors.black26,
          child: InkWell(
            key: const ValueKey('history_new_content_banner'),
            borderRadius: BorderRadius.circular(20),
            onTap: _onTapNewContentBanner,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.arrow_upward_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '有 $count 条新内容 ↑',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _highlightWrapper(String postId, Widget child) {
    final isHighlighted = _highlightedPostIds.contains(postId);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTokens.cardRadius),
        border: Border.all(
          color: isHighlighted
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 2.0,
        ),
      ),
      child: child,
    );
  }

  Future<void> _scrollToTop() async {
    if (!_activeAttached) return;
    final controller = _activeController;
    if (!controller.hasClients) return;
    final offset = controller.offset;
    if (offset <= 0) return;
    final viewportHeight = controller.position.hasViewportDimension
        ? controller.position.viewportDimension
        : 800.0;

    if (offset > 20 * viewportHeight) {
      // C3: Very far (> 20 screens): fast jump near top, then smooth scroll
      controller.jumpTo(2 * viewportHeight);
      await controller.animateTo(
        0.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    } else {
      // Smooth scroll to top, duration <= 500ms
      final durationMs = (offset / (4 * viewportHeight) * 300).clamp(200, 450).toInt();
      await controller.animateTo(
        0.0,
        duration: Duration(milliseconds: durationMs),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget _buildScrollToTopButton() {
    return AnimatedOpacity(
      opacity: _showScrollToTop ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      child: IgnorePointer(
        ignoring: !_showScrollToTop,
        child: Material(
          elevation: 4,
          shape: const CircleBorder(),
          color: Theme.of(context).colorScheme.surface,
          shadowColor: Colors.black26,
          child: Tooltip(
            message: '返回顶部',
            child: InkWell(
              key: const ValueKey('history_scroll_to_top_button'),
              customBorder: const CircleBorder(),
              onTap: _scrollToTop,
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Icon(
                    Icons.arrow_upward_rounded,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _activeAttached =>
      _activeController.hasClients && _activeController.positions.length == 1;

  double get _activeOffset => _activeAttached
      ? _activeController.position.pixels
      : (_scrollMemory.offsetFor(_positionKey) ?? 0);

  void _rememberScrollNow() {
    if (!_activeAttached) return;
    _scrollMemory.remember(_positionKey, _activeController.position.pixels);
  }

  /// After a filter or sort change: back to the top, except when the change
  /// goes back to the unfiltered list, which returns to where it was left.
  void _afterPositionKeyChange() {
    _cachedFirstRowThreshold = null;
    _pendingNewPostIds.clear();
    _highlightedPostIds.clear();
    final key = _positionKey;
    final remembered = _scrollMemory.offsetFor(key);
    final destination = destinationForChange(key, remembered: remembered);
    _scheduleScroll(
      destination == ScrollDestination.remembered ? remembered! : 0,
    );
  }

  /// A position for the list of the mode in view.
  ///
  /// [anchorKey] and [anchorDelta] name the card the user was looking at: when
  /// it is there after the rebuild, the list is put back so that card sits
  /// where it sat before. Nothing is applied before the target list has been
  /// laid out with a real height — restoring earlier is what clamped the offset
  /// away in build 55.
  void _scheduleScroll(
    double offset, {
    String? anchorKey,
    double anchorDelta = 0,
  }) {
    _pendingScroll = _PendingScroll(
      offset: offset,
      anchorKey: anchorKey,
      anchorDelta: anchorDelta,
    );
    _pendingFrames = 0;
    WidgetsBinding.instance.addPostFrameCallback(_applyPendingScroll);
  }

  void _applyPendingScroll(Duration _) {
    final pending = _pendingScroll;
    if (pending == null || !mounted) return;
    // Still reading, or nothing to lay out yet: wait for a frame with content.
    if (_loading || _dbError != null || _filtered.isEmpty) {
      _retryPendingScroll();
      return;
    }
    if (!_activeAttached || !_activeController.position.hasContentDimensions) {
      _retryPendingScroll();
      return;
    }
    final position = _activeController.position;
    final max = position.hasContentDimensions ? position.maxScrollExtent : 0.0;
    double? anchorOffset;
    if (pending.anchorKey != null) {
      anchorOffset = _anchorTarget(pending);
      // The card may not be built yet in the list that just replaced the old
      // one; a few frames are worth waiting for before falling back to the
      // pixel offset (which the new layout cannot compare to the old one).
      if (anchorOffset == null && _pendingFrames <= 8) {
        _retryPendingScroll();
        return;
      }
    }
    final resolved = resolveOffset(anchorOffset ?? pending.offset, max);
    _pendingScroll = null;
    if ((position.pixels - resolved).abs() > 0.5) {
      _activeController.jumpTo(resolved);
    }
    _scrollMemory.remember(_positionKey, resolved);
    _updateScrollMetrics();
  }

  /// Where the anchored card is now, or null when it is not built (yet).
  double? _anchorTarget(_PendingScroll pending) {
    final key = pending.anchorKey;
    if (key == null) return null;
    final box = _anchors[key]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    final reveal = viewport.getOffsetToReveal(box, 0).offset;
    if (!reveal.isFinite) return null;
    return anchorRestoreOffset(reveal: reveal, delta: pending.anchorDelta);
  }

  void _retryPendingScroll() {
    // A handful of frames is enough for a read to land and lay out; after that
    // the position is left alone instead of fighting the page.
    if (_pendingFrames++ > 120) {
      _pendingScroll = null;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback(_applyPendingScroll);
  }

  /// The card under the top edge right now, and where it sits, for a data
  /// update or a layout switch that is about to reorder the list.
  ScrollAnchor? _captureAnchor({
    AnchorPreference preference = AnchorPreference.visible,
  }) {
    if (!_activeAttached) return null;
    final offset = _activeController.position.pixels;
    final candidates = <ScrollAnchor>[];
    for (final entry in _anchors.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) continue;
      // Same measure as the restore below: where the list would have to stand
      // for this card to touch the top edge. `reveal - offset` is how far the
      // card is from the edge (negative: it starts above it).
      final reveal = viewport.getOffsetToReveal(box, 0).offset;
      if (!reveal.isFinite) continue;
      candidates.add(
        ScrollAnchor(
          key: entry.key,
          top: reveal - offset,
          height: box.size.height,
        ),
      );
    }
    final anchor = pickAnchor(candidates, preference: preference);
    return anchor;
  }

  /// Wraps a card with the key the anchor rules find it by (v1.11 batch 3).
  /// The card keeps its own key, so nothing about the list's own diffing
  /// changes.
  Widget _anchored(String itemKey, Widget child) =>
      KeyedSubtree(key: _anchors.putIfAbsent(itemKey, GlobalKey.new), child: child);

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

  void _handleCardLongPress(HistoryRecord record, String key) {
    if (_selectionMode) {
      _enterSelection(key);
      return;
    }
    final batch = _downloadBatches[record.postId];
    final isDownloading = batch != null && !batch.isTerminal;
    if (!isDownloading) {
      _enterSelection(key);
      return;
    }
    final paused = _isPaused(record.postId);
    final failed = _isFailed(record.postId) || _recordFailed(record);
    final toggleLabel = failed ? '重试' : (paused ? '继续下载' : '暂停下载');
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(failed ? Icons.refresh : (paused ? Icons.play_arrow : Icons.pause)),
              title: Text(toggleLabel),
              onTap: () {
                Navigator.pop(ctx);
                _toggleDownload(record.postId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消下载'),
              onTap: () {
                Navigator.pop(ctx);
                _cancelDownload(record.postId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('多选'),
              onTap: () {
                Navigator.pop(ctx);
                _enterSelection(key);
              },
            ),
          ],
        ),
      ),
    );
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
        for (final entry in pairSavedMedia(r.savedFiles)) {
          keys.add(_mediaKey(r, entry.itemIndex));
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
      final outcome = await parsePostOutcome(record.postUrl, source: 'history_refresh', forceRefresh: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      unawaited(PreviewPage.open(context,
          post: outcome.data,
          rawImages: outcome.rawImages,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      final isLoginRequired =
          e is ParseFailure && e.code == ParseErrorCode.loginRequired && loginSiteIds.contains(platformFromKey(record.platform));
      final cachedPost = record.toPost();
      if (cachedPost.items.isNotEmpty) {
        unawaited(PreviewPage.open(context, post: cachedPost));
        if (isLoginRequired) {
          final platform = platformFromKey(record.platform);
          LoginExpiredBus.markParseLoginRequired(platform);
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
        LoginExpiredBus.markParseLoginRequired(platform);
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

  void _openDownloadQueue() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DownloadQueuePage()),
    ).then((_) {
      if (mounted) {
        unawaited(_refreshDownloads());
        unawaited(_reload());
      }
    });
  }

  /// Build the fullscreen browser items for a record and open it.
  Future<void> _openRecord(HistoryRecord record, {int? highlightItemIndex}) async {
    if (_opening) return;
    _opening = true;

    try {
      final record0 = record;
      final post = record0.toPost();
      // Everything the browser may show: present files **and** the ones the
      // album confirmed as gone. A post whose files all left the device still
      // opens, with a placeholder per item, instead of silently doing nothing
      // (v1.11 batch 4).
      final isDownloading = _downloadBatches.containsKey(record0.postId);
      final built = await savedBrowserItems(
        record: record0,
        files: record0.visibleFiles,
        post: post,
        highlightItemIndex: highlightItemIndex,
        allowRemoteFallback: isDownloading,
      );
      final items = built.items;
      final initial = built.initial;

      if (items.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未找到可查看的媒体文件')),
          );
        }
        return;
      }
      if (mounted && items.every((item) => item.missing)) {
        // Every file left the device: still open the viewer (the placeholders
        // and the re-download button are the useful screen), but say why
        // nothing can be shown (v1.11 batch 4).
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到可查看的媒体文件')),
        );
      }

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (browserContext) => GalleryBrowserPage(
            items: items,
            initialIndex: initial,
            originalTotal: record0.originalItemCount,
            deletedIndices: deletedItemIndices(record0.files),
            authorName: record0.authorName ?? '',
            title: (record0.title?.isNotEmpty == true)
                ? record0.title!
                : record0.postId,
            platform: record0.platform,
            postUrl: record0.postUrl,
            aiLabel: record0.aiLabel,
            aiLabelSource: record0.aiLabelSource,
            onRedownloadItems: (indices) =>
                redownloadRecordItems(browserContext, record0, indices),
            onDeleteItem: (item, {required bool deleteAlbumFiles}) =>
                _deleteBrowserItem(
                  record0,
                  item,
                  deleteAlbumFiles: deleteAlbumFiles,
                ),
            onDeleteItems: (items, {required bool deleteAlbumFiles}) =>
                deleteBrowserItemsForRecord(
                  record0,
                  items,
                  deleteAlbumFiles: deleteAlbumFiles,
                  onChanged: () {
                    if (mounted) unawaited(_reload());
                  },
                ),
            onDeletePost: () => _deleteWholeRecord(record0),
            onReparse: () {
              Navigator.of(context).pop();
              _reparse(record0);
            },
          ),
        ),
      );
      _reload();
    } finally {
      _opening = false;
    }
  }

  /// Delete one item from the open viewer (v1.11 batch 4).
  ///
  /// The row state is written by the shared flow so both browser entry points
  /// behave the same; the history page only refreshes its cards.
  Future<GalleryBrowserItemDeletion?> _deleteBrowserItem(
    HistoryRecord record,
    GalleryBrowserItem item, {
    required bool deleteAlbumFiles,
  }) => deleteBrowserItemForRecord(
    record,
    item,
    deleteAlbumFiles: deleteAlbumFiles,
    onChanged: () {
      if (mounted) unawaited(_reload());
    },
  );

  /// Every item of the post was deleted and the user agreed to drop the record.
  Future<void> _deleteWholeRecord(HistoryRecord record) async {
    final db = await HistoryDb.instance();
    await deleteRecordForGood(
      record,
      delete: (fresh) => _deleteDatabaseRecords(db, [fresh]),
    );
  }

  Future<void> _shareRecords(List<HistoryRecord> records) async {
    final files = <XFile>[];
    final locator = GalleryLocatorService.instance;
    for (final r in records) {
      for (final f in r.savedFiles) {
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
      for (final f in r.savedFiles) {
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

    // The sheet reports what the user actually saved for these posts, not just
    // the rows that already carry a located album id: build 46 offered
    // "1 个文件" for two posts holding 3 + 4 files, because the other rows had
    // not been synced yet. It counts items (v1.11 build 59): a Live photo's
    // still and clip are one item, and the album delete still removes both.
    final savedItemCount = savedItemCountFor(records);
    final counts = deletionCountsForRecords(records);
    final itemSummary = savedItemCount > 0
        ? counts.format(nonLiveFallback: '$savedItemCount 项')
        : null;
    DevLog.write(
      'HIST',
      'delete sheet records=${records.length} files=${savedFileCountFor(records)} '
          'items=$savedItemCount${itemSummary != null ? ' summary=$itemSummary' : ''}',
    );
    if (!mounted) return;
    final result = await showDeleteRecordsSheet(
      context,
      recordCount: records.length,
      itemCount: savedItemCount,
      itemSummary: itemSummary,
      cancelDownloads: true,
    );
    if (result == null || !mounted) return;

    final db = await HistoryDb.instance();
    if (!result.deleteFiles) {
      if (!await _deleteDatabaseRecords(db, records)) return;
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

    // The user asked for the album files to go: resolve their current ids
    // first (a row whose album link was never refreshed has no id yet), then
    // hand them to the OS confirmation flow. Never claim a deletion that did
    // not happen.
    final media = await resolveDeletableMedia(records);
    if (!mounted) return;
    if (media.isEmpty) {
      if (!await _deleteDatabaseRecords(db, records)) return;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedItemCount > 0
                ? '未能在相册中找到这 $savedItemCount 项，仅删除了历史记录'
                : '已删除 ${records.length} 条记录',
          ),
        ),
      );
      return;
    }
    final MediaDeleteOutcome outcome;
    try {
      outcome = await MediaDeleteService.instance.deleteMedia(media);
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    if (!await _deleteDatabaseRecords(db, records)) return;
    if (!mounted) return;
    final problem = outcome.problem;
    final deletedItems = deletableItemCountFor(records, media);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          problem == null
              ? (deletedItems > 0
                  ? '已删除 ${records.length} 条记录，并从相册删除 ${counts.format(nonLiveFallback: '$deletedItems 项')}'
                  : '已删除 ${records.length} 条记录')
              : '$problem，仅删除了 ${records.length} 条记录',
        ),
      ),
    );
  }

  // ------------------------------------------------------------- grouping
  Future<bool> _deleteDatabaseRecords(HistoryDb db, List<HistoryRecord> records) async {
    try {
      await deleteHistoryRecords(db, records);
      if (mounted) {
        final committedAt = DateTime.now();
        final ids = records.map((record) => record.id).whereType<int>().toSet();
        final posts = records.map(postKeyOf).toSet();
        // Remember what this page removed, and when: a read that was still in
        // flight when the delete committed must never put one of these posts
        // back on screen (build 46 left one of two deleted posts visible and
        // openable until the page was left). A read that starts *after* this
        // moment cannot return them, so the guard is dropped then — a post a
        // later download restores must show up again (v1.11 build 59).
        for (final id in ids) {
          _deletedRecordIds[id] = committedAt;
        }
        for (final post in posts) {
          _deletedPostKeys[post] = committedAt;
        }
        setState(
          () => _records = dropDeletedRecords(
            _records,
            ids: ids,
            postKeys: posts,
          ),
        );
        unawaited(_reload());
      }
      return true;
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('删除未完成，请重试')));
      return false;
    }
  }

  /// Ids this page deleted after [readStartedAt] started reading: only those
  /// can still be in that read's result.
  Set<int> _suppressedIds(DateTime readStartedAt) => {
    for (final entry in _deletedRecordIds.entries)
      if (!entry.value.isBefore(readStartedAt)) entry.key,
  };

  Set<String> _suppressedPostKeys(DateTime readStartedAt) => {
    for (final entry in _deletedPostKeys.entries)
      if (!entry.value.isBefore(readStartedAt)) entry.key,
  };

  /// Drop the deletions a read that started at [readStartedAt] has overtaken.
  void _forgetDeletionsBefore(DateTime readStartedAt) {
    _deletedRecordIds.removeWhere((_, at) => at.isBefore(readStartedAt));
    _deletedPostKeys.removeWhere((_, at) => at.isBefore(readStartedAt));
  }

  /// Deletions the page is still guarding against, for tests (v1.11 build 59).
  @visibleForTesting
  int get guardedDeletionsForTesting =>
      _deletedRecordIds.length + _deletedPostKeys.length;

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
            (a, b) => savedMediaEntryCount(b.savedFiles)
                .compareTo(savedMediaEntryCount(a.savedFiles)),
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
      for (final entry in pairSavedMedia(r.savedFiles)) {
        all.add(HistThumbRef(r, entry.itemIndex));
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
          final is1Based = ref.record.savedFiles.isNotEmpty && ref.record.savedFiles.every((f) => f.itemIndex > 0);
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
          final av = savedMediaEntryCount(a.record.savedFiles);
          final bv = savedMediaEntryCount(b.record.savedFiles);
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
    for (final f in ref.record.savedFiles) {
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
            _videoBackfillHintBanner(),
            if (!_selectionMode) _viewSwitcher(),
            if (_searchOpen && !_selectionMode) _searchField(),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: _body()),
                  if (!_selectionMode)
                    Positioned(
                      top: 12,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: _buildNewContentBanner(),
                      ),
                    ),
                  if (!_selectionMode)
                    Positioned(
                      right: 16,
                      bottom: 20,
                      child: _buildScrollToTopButton(),
                    ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: _selectionMode ? _selectionBottomBar() : null,
      ),
    );
  }

  /// Entry to the download queue (right end of the view-switcher row); the
  /// badge counts unfinished batches. Same 34px round look as the other
  /// toolbar buttons.
  Widget _queueButton() {
    final count = _unfinished.length;
    return Tooltip(
      message: count > 0 ? '下载队列（$count 个待完成）' : '下载队列',
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DownloadQueuePage()),
          );
          if (!mounted) return;
          unawaited(_refreshDownloads());
          unawaited(_reload());
        },
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // Always filled so the entry reads as a button, tinted while busy.
            color: count > 0
                ? SecondaryBg.pink(context)
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          child: Badge(
            isLabelVisible: count > 0,
            label: Text('$count'),
            child: const Icon(Icons.download_for_offline_outlined, size: 24),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar() {
    final filtered = _filtered;
    final itemCount = filtered.fold<int>(
      0,
      (sum, r) => sum + savedMediaEntryCount(r.savedFiles),
    );
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('历史'),
          Text(
            '${filtered.length} 个帖子 · $itemCount 项',
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
        if (_view == HistoryView.creators)
          _creatorSortMenu()
        else
          _sortMenu(),
        if (_view == HistoryView.posts)
          _toolbarButton(
            icon: _layout == HistoryLayout.waterfall
                ? Icons.view_list
                : Icons.grid_view,
            active: false,
            tooltip: _layout == HistoryLayout.waterfall ? '切换列表' : '切换瀑布流',
            onTap: () {
              // 瀑布流 ↔ 列表 keeps the first fully visible post on screen; the
              // pixel offsets of the two layouts are not comparable (v1.11
              // batch 3).
              final anchor = _captureAnchor(
                preference: AnchorPreference.aligned,
              );
              final offset = _activeOffset;
              setState(() {
                _cachedFirstRowThreshold = null;
                _layout = _layout == HistoryLayout.waterfall
                    ? HistoryLayout.list
                    : HistoryLayout.waterfall;
              });
              _persistPrefs();
              _scheduleScroll(
                offset,
                anchorKey: anchor?.key,
                anchorDelta: anchor?.top ?? 0,
              );
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

  Widget _videoBackfillHintBanner() {
    return VideoBackfillHintBanner(
      dismissed: _settings?.videoBackfillHintDismissed ?? true,
      records: _records,
      onDismiss: _dismissVideoBackfillHint,
      onBackfill: _startVideoBackfill,
    );
  }

  Future<void> _dismissVideoBackfillHint() async {
    setState(() {
      _settings?.videoBackfillHintDismissed = true;
    });
    await _settings?.save();
  }

  Future<void> _startVideoBackfill() async {
    setState(() {
      _settings?.videoBackfillHintDismissed = true;
    });
    await _settings?.save();

    final progressText = ValueNotifier<String>('准备中…');
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('正在补写来源信息'),
        content: ValueListenableBuilder<String>(
          valueListenable: progressText,
          builder: (_, value, __) => Text(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );

    try {
      final result = await HistoryBackfillService.instance.backfill(
        onProgress: (current, total, filename) {
          progressText.value = '$current / $total\n$filename';
        },
      );

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已完成：${result.success} 写入，${result.authRequired} 需要授权，${result.skipped} 跳过',
          ),
        ),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('写入失败：$e')),
      );
    }
  }

  /// Starts the `[ModeSwitch]` measurement of a switch to [next] (v1.11 batch
  /// 3). The line reports the switch itself, so it is started before the new
  /// view is built and closed once every visible thumbnail has resolved.
  void _beginModeSwitch(HistoryView next) {
    if (next == _view) return;
    _modeSwitch?.dispose();
    final probe = ModeSwitchProbe(from: _view.name, to: next.name);
    _modeSwitch = probe;
    WidgetsBinding.instance.addPostFrameCallback((_) => probe.firstFrame());
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
                    key: ValueKey('view_switcher_${view.name}'),
                    onTap: () {
                      if (_view == view) return;
                      // Remember the position of the view being left, and
                      // start the one being entered where it was left
                      // (v1.11 batch 3).
                      _rememberScrollNow();
                      _beginModeSwitch(view);
                      setState(() {
                        _view = view;
                        _selected.clear();
                        _selectionMode = false;
                      });
                      widget.onSelectionModeChanged?.call(false);
                      _persistPrefs();
                      _scheduleScroll(_scrollMemory.offsetFor(_positionKey) ?? 0);
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
          // Active filter chips take the free space and scroll when they do
          // not fit, so the queue button on the right never gets pushed out.
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_author != null)
                      _filterChip(
                        _author!,
                        () {
                          setState(() => _author = null);
                          _afterPositionKeyChange();
                        },
                      ),
                    if (_platform != 'all')
                      _filterChip(
                        _platformLabel(_platform),
                        () {
                          setState(() => _platform = 'all');
                          _afterPositionKeyChange();
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          _queueButton(),
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
        onChanged: (v) {
          if (v == _query) return;
          setState(() => _query = v);
          _afterPositionKeyChange();
        },
        decoration: InputDecoration(
          hintText: '搜索标题或作者',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    setState(() {
                      _query = '';
                      _searchController.clear();
                    });
                    _afterPositionKeyChange();
                  },
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
      key: const ValueKey('canonical-platform-filter'),
      tooltip: '平台筛选',
      onSelected: (v) {
        if (v == _platform) return;
        setState(() => _platform = v);
        // A platform filter is a filter change: top, unless it goes back to the
        // unfiltered list (v1.11 batch 3).
        _afterPositionKeyChange();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'all', child: Text('全部')),
        for (final siteId in {
          ...SiteRegistry.current.sites.where((s) => s.enabled).map((s) => s.id),
          ..._records.map((r) => SiteRegistry.current.canonicalId(r.platform)),
        })
          PopupMenuItem(value: siteId, child: Text(_platformLabel(siteId))),
      ],
      child: _toolbarButtonInner(
        icon: Icons.filter_list,
        active: _platform != 'all',
      ),
    );
  }

  Widget _sortMenu() {
    return PopupMenuButton<HistorySort>(
      key: const ValueKey('sort-menu'),
      tooltip: '排序',
      onSelected: (v) {
        if (v == _sort) return;
        setState(() => _sort = v);
        _persistPrefs();
        // A new order starts at the top (v1.11 batch 3).
        _afterPositionKeyChange();
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: HistorySort.latest, child: Text('最新保存')),
        PopupMenuItem(value: HistorySort.earliest, child: Text('最早保存')),
        PopupMenuItem(value: HistorySort.type, child: Text('按类型')),
        PopupMenuItem(value: HistorySort.mostFiles, child: Text('项最多')),
        PopupMenuItem(value: HistorySort.author, child: Text('按作者')),
      ],
      child: _toolbarButtonInner(
        icon: Icons.swap_vert,
        active: _sort != HistorySort.latest,
      ),
    );
  }

  /// 创作者 sort menu (v1.11 batch 1): three keys, each with both directions.
  /// Only shown in the 创作者 view; the choice is persisted with the other
  /// history preferences.
  Widget _creatorSortMenu() {
    String label(CreatorSort mode) => switch (mode) {
      CreatorSort.postCount => '帖子数',
      CreatorSort.latestSaved => '最近保存',
      CreatorSort.name => '名称',
    };
    final atDefault = _creatorSort == CreatorSortState.defaults.mode &&
        _creatorSortDescending == CreatorSortState.defaults.descending;
    return PopupMenuButton<CreatorSortState>(
      key: const ValueKey('creator-sort-menu'),
      tooltip: '创作者排序',
      onSelected: (value) {
        setState(() {
          _creatorSort = value.mode;
          _creatorSortDescending = value.descending;
        });
        _persistPrefs();
        // 创作者 ordering is one of the page's own sorts: a change starts the
        // grid at the top (v1.11 batch 3).
        _afterPositionKeyChange();
      },
      itemBuilder: (_) => [
        for (final mode in CreatorSort.values)
          for (final descending in const [true, false])
            PopupMenuItem<CreatorSortState>(
              value: CreatorSortState(mode: mode, descending: descending),
              child: Text('${label(mode)} · ${descending ? '降序' : '升序'}'
                  '${_creatorSort == mode && _creatorSortDescending == descending
                      ? ' （当前）'
                      : ''}'),
            ),
      ],
      child: _toolbarButtonInner(
        icon: Icons.swap_vert,
        active: !atDefault,
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

  String _platformLabel(String key) => key == 'all' ? '全部' : platformLabel(key,
    savedDisplayName: _records.where((r) => SiteRegistry.current.sameSite(r.platform, key) && r.platformDisplayName?.trim().isNotEmpty == true)
      .map((r) => r.platformDisplayName).firstOrNull);

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
    return _modeStack();
  }

  /// Shows the mode in view, and only that one (v1.11 batch 3).
  ///
  /// A mode is created the first time it is entered and remembered afterwards;
  /// while it is hidden nothing of it exists in the tree, so it cannot issue a
  /// thumbnail request and cannot react to a refresh. What it keeps is its
  /// scroll offset (through its own [ScrollController] and [PageStorage]) and
  /// its decoded thumbnails (through the image cache), and its data change is
  /// applied the moment it is switched back to. Lazy building is untouched: the
  /// visible mode still builds only the cards near the viewport.
  Widget _modeStack() {
    return KeyedSubtree(
      key: ValueKey('history_view_${_view.name}'),
      child: _modeBody(_view),
    );
  }

  Widget _modeBody(HistoryView view) {
    _modeSubtrees[view] = _buildModeView(view);
    _modePendingUpdate.remove(view);
    return _modeSubtrees[view]!;
  }

  Widget _buildModeView(HistoryView view) {
    final controller = _modeScroll.putIfAbsent(
      view,
      () => _newController(view),
    );
    switch (view) {
      case HistoryView.posts:
        return _layout == HistoryLayout.waterfall
            ? _postsWaterfall(controller)
            : _postsList(controller);
      case HistoryView.all:
        return _allWaterfall(controller);
      case HistoryView.creators:
        return _creators(controller);
    }
  }

  /// Data changed. Every hidden mode now owes itself a rebuild, which it gets
  /// the moment it is switched back to.
  void _markHiddenModesPending() {
    for (final view in _modeSubtrees.keys) {
      if (view != _view) _modePendingUpdate.add(view);
    }
  }

  /// Modes entered so far, for tests (v1.11 batch 3).
  @visibleForTesting
  Set<HistoryView> get keptModesForTesting => Set<HistoryView>.of(_modeSubtrees.keys);

  /// Rows and visible rows, for tests.
  @visibleForTesting
  int get recordCountForTesting => _records.length;

  /// The records the page is showing, in the order it read them (v1.11
  /// build 59).
  @visibleForTesting
  List<HistoryRecord> get recordsForTesting => List.of(_records);

  @visibleForTesting
  int get filteredCountForTesting => _filtered.length;

  // The position rules are about where the list ends up, so they are asserted
  // on the real offsets rather than on the pixels of a rendered card
  // (v1.11 batch 3).

  @visibleForTesting
  double get scrollOffsetForTesting => _activeOffset;

  @visibleForTesting
  void scrollToForTesting(double offset) {
    if (!_activeAttached) return;
    _activeController.jumpTo(
      offset.clamp(0.0, _activeController.position.maxScrollExtent),
    );
  }

  /// The card nearest the top edge right now — what an update that must not
  /// move anything holds on to.
  @visibleForTesting
  String? get firstVisibleKeyForTesting => _captureAnchor()?.key;

  /// The first fully visible card — what a layout switch holds on to.
  @visibleForTesting
  String? get firstAlignedKeyForTesting =>
      _captureAnchor(preference: AnchorPreference.aligned)?.key;

  /// A card's top relative to the viewport edge and its height, for tests.
  @visibleForTesting
  (double, double)? itemPlacementForTesting(String key) {
    if (!_activeAttached) return null;
    final box = _anchors[key]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return null;
    final reveal = viewport.getOffsetToReveal(box, 0).offset;
    if (!reveal.isFinite) return null;
    return (reveal - _activeController.position.pixels, box.size.height);
  }

  @visibleForTesting
  HistoryScrollKey get scrollKeyForTesting => _positionKey;

  /// Hidden modes that still owe themselves a rebuild, for tests.
  @visibleForTesting
  Set<HistoryView> get pendingModeUpdatesForTesting =>
      Set<HistoryView>.of(_modePendingUpdate);

  /// Every card of the 帖子 mode in the order it is shown, with its group
  /// title (今天 / 昨天 / 本周 / a date), for tests (v1.11 build 59).
  @visibleForTesting
  List<({String group, int? id, String postId})> get postGroupsForTesting => [
    for (final group in _groupPosts(_filtered))
      for (final record in group.posts)
        (group: group.title, id: record.id, postId: record.postId),
  ];

  /// Delete [records] through the page's own delete path, for tests
  /// (v1.11 build 59).
  @visibleForTesting
  Future<void> deleteRecordsForTesting(List<HistoryRecord> records) async =>
      _deleteDatabaseRecords(await HistoryDb.instance(), records);

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
        await _reload();
        historyBackground('refresh-scan', () async {
          final locator = GalleryLocatorService.instance;
          if (locator.hasAccess) await locator.scanAlbum(force: true);
          if (mounted) setState(() {});
        }, timeout: const Duration(seconds: 5), deadline: _historyRefresh.deadline);
      },
      child: child,
    );
  }

  /// A lazy masonry block for one group (v1.11 batch 2).
  ///
  /// The cards are laid out by two side-by-side sliver lists, so only the cards
  /// near the viewport exist and only those ask for a local thumbnail. The
  /// placement comes from [LazyMasonrySliver.estimatedHeightOf], i.e. from the
  /// cover's aspect ratio — never from measuring an off-screen card.
  /// [itemKeys] identify the ordered items so an element follows its content
  /// when the order changes.
  Widget _groupMasonry({
    required List<String> itemKeys,
    required double Function(int index, double columnWidth) estimatedHeightOf,
    required Widget Function(BuildContext, int) itemBuilder,
    bool balanced = false,
  }) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: LazyMasonrySliver(
        itemKeys: itemKeys,
        estimatedHeightOf: estimatedHeightOf,
        itemBuilder: itemBuilder,
        balanced: balanced,
      ),
    );
  }

  Widget _postsWaterfall(ScrollController controller) {
    final groups = _groupPosts(_filtered);
    return _refreshWrapper(
      KeyedSubtree(
        key: _scrollContainerKey,
        child: CustomScrollView(
          controller: controller,
          key: const PageStorageKey<String>('history_scroll_posts'),
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            for (var gi = 0; gi < groups.length; gi++)
              historyGroupSliver(
                title: groups[gi].title,
                background: Theme.of(context).scaffoldBackgroundColor,
                content: _groupMasonry(
                balanced: true,
                itemKeys: [for (final record in groups[gi].posts) 'wf-${record.id}'],
                estimatedHeightOf: (index, columnWidth) =>
                    waterfallCardHeight(groups[gi].posts[index], columnWidth),
                itemBuilder: (context, index) {
                  final record = groups[gi].posts[index];
                  final key = _postKey(record);
                  return _wrapFirstRow(
                    gi == 0 && index == 0,
                    _anchored(key, _highlightWrapper(record.postId, WaterfallPostCard(
                  key: ValueKey('wf-${record.id}'),
                  record: record,
                  selectionMode: _selectionMode,
                  selected: _selected.contains(key),
                  downloadProgress: _downloadProgress[record.postId] ?? (_recordFailed(record) ? 0 : null),
                  downloadBatch: _downloadBatches[record.postId],
                  downloadPaused: _isPaused(record.postId),
                  downloadUserPaused: _downloadBatches[record.postId]?.isUserPaused ?? false,
                  downloadStatusText: _downloadBatches[record.postId]?.statusText,
                  downloadStalled: _isStalled(record.postId),
                  downloadWaitingForNetwork:
                      !NetworkStatus.instance.online ||
                      (_downloadBatches[record.postId]?.waitingForNetwork ??
                          false),
                  downloadFailed: _isFailed(record.postId) || _recordFailed(record),
                  downloadIsFinishing: _downloadBatches[record.postId]?.jobs.any((j) => j.isFinishing) ?? false,
                  downloadSavingPhase: _downloadBatches[record.postId]?.jobs.cast<DownloadJob?>().firstWhere((j) => j?.isFinishing == true, orElse: () => null)?.savingPhase,
                  downloadFailureReason: _downloadBatches[record.postId]?.failureReason ?? record.downloadError,
                  onToggleDownload: _recordFailed(record) ? () => _reparse(record) : _downloadBatches[record.postId]?.supportsPause == false && !_isFailed(record.postId) ? null : () => _toggleDownload(record.postId),
                  onTapQueue: _openDownloadQueue,
                  onCancelDownload: () => _cancelDownload(record.postId),
                  onTap: () => _openRecord(record),
                  onLongPress: () => _handleCardLongPress(record, key),
                  onToggleSelect: () => _toggleSelection(key),
                ))));
              },
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
      ),
    );
  }

  Widget _postsList(ScrollController controller) {
    final groups = _groupPosts(_filtered);
    return _refreshWrapper(
      KeyedSubtree(
        key: _scrollContainerKey,
        child: CustomScrollView(
          controller: controller,
          key: const PageStorageKey<String>('history_scroll_posts_list'),
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            for (var gi = 0; gi < groups.length; gi++)
              historyGroupSliver(
                title: groups[gi].title,
                background: Theme.of(context).scaffoldBackgroundColor,
                content: SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final record = groups[gi].posts[index];
                    final key = _postKey(record);
                    return _wrapFirstRow(
                      gi == 0 && index == 0,
                      _anchored(
                    key,
                    _highlightWrapper(
                      record.postId,
                      Padding(
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
                        downloadProgress: _downloadProgress[record.postId] ?? (_recordFailed(record) ? 0 : null),
                  downloadBatch: _downloadBatches[record.postId],
                        downloadPaused: _isPaused(record.postId),
                        downloadUserPaused: _downloadBatches[record.postId]?.isUserPaused ?? false,
                        downloadStatusText: _downloadBatches[record.postId]?.statusText,
                        downloadStalled: _isStalled(record.postId),
                  downloadFailed: _isFailed(record.postId) || _recordFailed(record),
                  downloadIsFinishing: _downloadBatches[record.postId]?.jobs.any((j) => j.isFinishing) ?? false,
                  downloadSavingPhase: _downloadBatches[record.postId]?.jobs.cast<DownloadJob?>().firstWhere((j) => j?.isFinishing == true, orElse: () => null)?.savingPhase,
                  downloadFailureReason: _downloadBatches[record.postId]?.failureReason ?? record.downloadError,
                        onToggleDownload: _recordFailed(record) ? () => _reparse(record) : _downloadBatches[record.postId]?.supportsPause == false && !_isFailed(record.postId) ? null : () => _toggleDownload(record.postId),
                        onTapQueue: _openDownloadQueue,
                        onCancelDownload: () =>
                            _cancelDownload(record.postId),
                        onTap: () => _openRecord(record),
                        onLongPress: () => _handleCardLongPress(record, key),
                        onToggleSelect: () => _toggleSelection(key),
                        onReparse: () => _reparse(record),
                        onOpenOriginal: () => _openOriginal(record.postUrl),
                      ),
                    ),
                  ))));
                }, childCount: groups[gi].posts.length),
              ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
      ),
    );
  }

  Widget _allWaterfall(ScrollController controller) {
    final groups = _groupMedia(_filtered);
    return _refreshWrapper(
      KeyedSubtree(
        key: _scrollContainerKey,
        child: CustomScrollView(
          controller: controller,
          key: const PageStorageKey<String>('history_scroll_all'),
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            for (var gi = 0; gi < groups.length; gi++)
              historyGroupSliver(
                title: groups[gi].title,
                background: Theme.of(context).scaffoldBackgroundColor,
                content: _groupMasonry(
                itemKeys: [
                  for (final ref in groups[gi].media) 'all-${ref.record.id}-${ref.itemIndex}',
                ],
                estimatedHeightOf: (index, columnWidth) {
                  final ref = groups[gi].media[index];
                  return allMediaCardHeight(
                    allMediaItemFor(ref.record, ref.itemIndex),
                    columnWidth,
                  );
                },
                itemBuilder: (context, index) {
                  final ref = groups[gi].media[index];
                  final key = _mediaKey(ref.record, ref.itemIndex);
                  return _wrapFirstRow(
                    gi == 0 && index == 0,
                    _anchored(
                  key,
                  _highlightWrapper(
                    ref.record.postId,
                    AllMediaCard(
                      key: ValueKey('all-${ref.record.id}-${ref.itemIndex}'),
                      record: ref.record,
                      itemIndex: ref.itemIndex,
                      selectionMode: _selectionMode,
                      selected: _selected.contains(key),
                      onTap: () =>
                          _openRecord(ref.record, highlightItemIndex: ref.itemIndex),
                      onLongPress: () => _enterSelection(key),
                      onToggleSelect: () => _toggleSelection(key),
                    ),
                  ),
                  ),
                  );
                },
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
    );
  }

  Widget _creators(ScrollController controller) {
    final creators = _creatorGroups(_filtered);
    return _refreshWrapper(
      KeyedSubtree(
        key: _scrollContainerKey,
        child: GridView.builder(
          controller: controller,
          key: const PageStorageKey<String>('history_scroll_creators'),
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
            return _wrapFirstRow(
              index == 0,
              _anchored(
            'c:${c.platform}:${c.authorName}',
            CreatorCard(
            authorName: c.authorName,
            platform: c.platform,
            savedDisplayName: _platformLabel(c.platform),
            postCount: c.postCount,
            itemCount: c.itemCount,
            thumbs: c.thumbs,
            onTap: () {
              // 创作者 → 帖子 with this author is a filter change, so the list
              // starts at its top (v1.11 batch 3) instead of inheriting the
              // creators offset, which parked it at the end.
              _rememberScrollNow();
              setState(() {
                _beginModeSwitch(HistoryView.posts);
                _view = HistoryView.posts;
                _author = c.authorName;
              });
              _afterPositionKeyChange();
            },
          ),
          ),
          );
        },
      ),
      ),
    );
  }

  List<_CreatorGroup> _creatorGroups(List<HistoryRecord> records) {
    final map = <String, _CreatorGroup>{};
    for (final r in records) {
      final author = r.authorName ?? '';
      final group = map.putIfAbsent(
        '${SiteRegistry.current.canonicalId(r.platform)}:$author',
        () => _CreatorGroup(authorName: author, platform: SiteRegistry.current.canonicalId(r.platform)),
      );
      group.postCount++;
      group.itemCount += savedMediaEntryCount(r.savedFiles);
      final createdMs = r.createdAt.millisecondsSinceEpoch;
      if (createdMs > group.latestSavedMs) group.latestSavedMs = createdMs;
      for (final f in r.savedFiles) {
        if (f.savedAt > group.latestSavedMs) group.latestSavedMs = f.savedAt;
        if (group.thumbs.length < 4) {
          group.thumbs.add(HistThumbRef(r, f.itemIndex));
        }
      }
    }
    // Ordering runs on the grouped data already in memory: no query and no
    // native sort-key call (build 35).
    return sortCreators(
      map.values.toList(),
      mode: _creatorSort,
      descending: _creatorSortDescending,
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

class _CreatorGroup implements CreatorSortable {
  _CreatorGroup({required this.authorName, required this.platform});
  final String authorName;
  final String platform;
  int postCount = 0;

  /// Items, not files: a Live photo's still and clip are one item (v1.11
  /// build 59), so the 创作者 card reads 「N 帖 · N 项」.
  int itemCount = 0;

  /// Newest save among this creator's files (falls back to the post time), the
  /// 创作者 view's "最近保存" key.
  int latestSavedMs = 0;
  final List<HistThumbRef> thumbs = [];

  @override
  String get sortName => authorName;

  @override
  String get sortPlatform => platform;

  @override
  int get sortPostCount => postCount;

  @override
  int get sortLatestSavedMs => latestSavedMs;
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

class VideoBackfillHintBanner extends StatelessWidget {
  const VideoBackfillHintBanner({
    super.key,
    required this.dismissed,
    required this.records,
    required this.onDismiss,
    required this.onBackfill,
  });

  final bool dismissed;
  final List<HistoryRecord> records;
  final VoidCallback onDismiss;
  final VoidCallback onBackfill;

  @override
  Widget build(BuildContext context) {
    if (dismissed) {
      return const SizedBox.shrink();
    }
    final hasVideoWithoutAssetId = records.any(
      (r) => r.savedFiles.any((f) => !f.isImage && (f.assetId == null || f.assetId!.isEmpty)),
    );
    if (!hasVideoWithoutAssetId) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.video_library_outlined, color: Colors.blue.shade900, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '为已保存的视频补写来源信息',
              style: TextStyle(color: Colors.blue.shade900, fontSize: 13),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onDismiss,
            child: Text(
              '不再提示',
              style: TextStyle(color: Colors.blue.shade700, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onBackfill,
            child: const Text(
              '去补写',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// A list position that is applied once the target list has been laid out
/// (v1.11 batch 3).
///
/// Restoring straight after a rebuild is what put the lists back at the top in
/// build 55: the content had no height yet, so the offset was clamped away.
class _PendingScroll {
  const _PendingScroll({
    required this.offset,
    this.anchorKey,
    this.anchorDelta = 0,
  });

  /// The pixel offset to return to.
  final double offset;

  /// The card the user was looking at, when the change was a data update or a
  /// layout switch: the list is then put back so that card stays in place.
  final String? anchorKey;

  /// That card's top relative to the viewport top when it was captured.
  final double anchorDelta;
}
