// Parse tab: gradient header with overlapping input card, clipboard
// auto-detect, progress/cancel and error states, recent history.

import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/ai_label_badge.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/error_copy.dart';
import '../core/dev_log.dart';
import '../core/models.dart';
import '../services/auth.dart';
import '../services/site_registry.dart';
import '../services/clipboard_guard.dart';
import '../services/gallery_locator_service.dart';
import '../services/history_db.dart';
import '../services/host_bridge.dart';
import '../services/links.dart';
import '../services/live_pairs.dart';
import '../services/login_navigation.dart';
import '../services/preview_open_guard.dart';
import '../services/preview_route_observer.dart';
import '../services/parse_service.dart';
import '../services/seal.dart';
import '../services/settings.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/download_sheet.dart';
import '../widgets/gallery_browser.dart';
import '../widgets/parse_feedback.dart';
import '../widgets/shared.dart';
import 'batch_page.dart';
import 'login_page.dart';
import 'preview_page.dart';

class ParsePage extends StatefulWidget {
  const ParsePage({
    super.key,
    this.onSeeAll,
    this.isVisible,
    this.onShowSelf,
    this.initializeServices = true,
  });

  final bool initializeServices;

  final VoidCallback? onSeeAll;

  /// Whether the Parse tab is the one on screen. When it is not (the
  /// clipboard dialog also appears over History / Mine), parse progress and
  /// errors are shown as snackbars instead of the inline state.
  final bool Function()? isVisible;

  /// Switch to the Parse tab (used by the error snackbar's "查看" action).
  final VoidCallback? onShowSelf;

  @override
  State<ParsePage> createState() => ParsePageState();
}

class ParsePageState extends State<ParsePage> with WidgetsBindingObserver {
  final _linkController = TextEditingController();
  final _inputFocus = FocusNode();
  bool _busy = false;
  bool _resolving = false;
  int _resolveEpoch = 0;
  bool _cancelRequested = false;
  String? _errorCode;
  String? _errorMessage;
  String _lastLink = '';

  /// Clipboard key of the link opened by an external entry (bubble).
  String? _externalLink;
  String _currentLink = '';
  String _appVersion = '';
  List<HistoryRecord> _recent = [];
  bool _recentLoaded = false;

  /// Wider window used only for the "already downloaded" clipboard dedupe.
  List<HistoryRecord> _recentAll = [];

  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  bool _handlingShare = false;

  @override
  void initState() {
    super.initState();
    if (!widget.initializeServices) {
      _recentLoaded = true;
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    // Kick off history DB load and preloading immediately so records are
    // ready at or before the very first frame.
    unawaited(_reloadRecent());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkClipboard();
      _loadVersion();
    });
    _initShareIntent();
    // A download that finishes while we are on this tab must show up in
    // "最近保存" right away: the album scan (in-app download) and the host
    // bridge (background engine) are the two signals that a new history
    // record exists. Switching tabs does not trigger a lifecycle change, so
    // without these listeners the list would stay stale.
    GalleryLocatorService.instance.addListener(_onHistoryChanged);
    HostBridge.historyRevision.addListener(_onHistoryChanged);
    // Every mutation made through HistoryDb in this isolate (delete, clear,
    // undo, restore, rebuild, new download) also refreshes the list.
    unawaited(_attachHistoryDb());
  }

  HistoryDb? _historyDb;

  Future<void> _attachHistoryDb() async {
    try {
      final db = await HistoryDb.instance();
      if (!mounted) return;
      _historyDb = db;
      db.addListener(_onHistoryChanged);
    } catch (e) {
      // Never silent: "no listeners attached" in a device log is otherwise
      // indistinguishable from a subscription that failed here.
      DevLog.write(
        'HIST',
        'attach failed: $e', // i18n:ignore 日志
        level: DevLogLevel.warn,
      );
    }
  }

  /// New history record available (in-app download or background engine).
  void _onHistoryChanged() {
    if (!mounted) return;
    unawaited(_refreshRecentList());
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _appVersion = '${info.version}+${info.buildNumber}');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reload history first so the clipboard dedupe sees records that were
      // downloaded in the background (tile / bubble) while we were away.
      _reloadRecent().then((_) => _checkClipboard());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GalleryLocatorService.instance.removeListener(_onHistoryChanged);
    HostBridge.historyRevision.removeListener(_onHistoryChanged);
    _historyDb?.removeListener(_onHistoryChanged);
    _shareSub?.cancel();
    _linkController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Light refresh of the "最近保存" list: only the database is read. Safe to
  /// call from a listener — the heavy [_reloadRecent] touches the album
  /// service, which notifies its own listeners and would loop back here.
  Future<void>? _recentRead;
  Future<void> _refreshRecentList() => _recentRead ??= _readRecentList().whenComplete(() => _recentRead = null);

  Future<void> _readRecentList() async {
    final db = await HistoryDb.instance();
    final all = await db.recent(limit: 30);
    final records = all.take(3).toList();
    final locator = GalleryLocatorService.instance;
    if (locator.hasAccess && records.isNotEmpty) {
      await locator.preloadMediaIds(records);
    }
    if (!mounted) return;
    setState(() {
      _recent = records;
      _recentAll = all;
      _recentLoaded = true;
    });
    DevLog.write(
      'HIST',
      'recent refreshed shown=${records.length} known=${all.length}',
    ); // i18n:ignore 日志
  }

  /// Reload recent from DB; called by the shell every time the tab becomes visible.
  Future<void> reload() async {
    if (!mounted) return;
    await _reloadRecent();
  }

  Future<void> _reloadRecent() async {
    final db = await HistoryDb.instance();
    final records = await db.recent(limit: 3);
    final all = await db.recent(limit: 30);
    final locator = GalleryLocatorService.instance;
    await locator.checkPermission();
    if (locator.hasAccess && records.isNotEmpty) {
      // Preload thumbnails BEFORE triggering setState to prevent any empty/shimmer intermediate frame
      await locator.preloadMediaIds(records);
    }
    if (!mounted) return;
    setState(() {
      _recent = records;
      _recentAll = all;
      _recentLoaded = true;
    });
    // Silent background scan and sync
    unawaited(_backgroundScanAndSync());
  }

  Future<void> _backgroundScanAndSync() async {
    final locator = GalleryLocatorService.instance;
    await locator.scanAlbum();
    if (_recent.isNotEmpty) {
      await locator.syncAll(_recent);
    }
    if (mounted) setState(() {});
  }

  /// Single entry for clipboard dialog, paste button and share intents:
  /// YouTube links detour to Seal, multiple links open the batch queue,
  /// exactly one supported link resolves directly.
  ///
  /// [entry] is passed on to the dedup decision so the log names the door.
  Future<void> _handleLinks(String text, {String entry = 'input'}) async {
    if (await routeExternalText(text, present: _showYouTubeSheet)) return;
    if (!mounted) return;
    final links = extractLinks(text);
    if (links.length > 1) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('发现 ${links.length} 个链接'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: links.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  links[i],
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('逐个解析'),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => BatchPage(links: links)),
        );
        _reloadRecent();
      }
      return;
    }
    if (links.length == 1) {
      await _resolve(links.first, entry: entry);
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有找到支持的链接')));
    }
  }

  Future<void> _showYouTubeSheet(String url) async {
    final installed = await isSealInstalled();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'YouTube 视频由 Seal 下载',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                url,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              if (installed)
                GradientButton(
                  label: '去 Seal 下载',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.of(context).pop();
                    try {
                      await sendToSeal(url);
                    } catch (_) {
                      messenger.showSnackBar(
                        const SnackBar(content: Text('跳转失败，请重试')),
                      );
                    }
                  },
                )
              else ...[
                const Text(
                  '手机上没有检测到 Seal，请先安装：\n'
                  '· F-Droid 搜索 Seal\n'
                  '· GitHub JunkFood02/Seal Releases 下载 APK',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: url));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('链接已复制')),
                          );
                        },
                        child: const Text('复制链接'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Clipboard.setData(
                            const ClipboardData(text: sealReleasesUrl),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('下载地址已复制')),
                          );
                        },
                        child: const Text('复制下载地址'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Iterable<KnownPost> get _knownPosts =>
      _recentAll.map((r) => (postUrl: r.postUrl, postId: r.postId));

  /// True when this link was already downloaded (e.g. through the floating
  /// bubble). Matching is done by post id, so a short link (xhslink) still
  /// matches the record stored under its canonical url.
  Future<bool> _alreadyDownloaded(String link) async {
    if (isLinkKnown(link, _knownPosts)) return true;
    try {
      final db = await HistoryDb.instance();
      if (await db.findRecordByLink(link) != null) return true;
    } catch (_) {}
    String? resolved;
    try {
      resolved = await resolveShortLink(link, forHistoryLookup: true);
      if (isLinkKnown(link, _knownPosts, resolvedUrl: resolved)) return true;
    } catch (_) {}
    try {
      final db = await HistoryDb.instance();
      final record = await db.findRecordByLink(link, resolvedUrl: resolved);
      return record != null;
    } catch (_) {
      return false;
    }
  }

  /// Clear leftovers in the input box: when every link in it is already in
  /// the recent history (downloaded earlier, e.g. through the bubble), the
  /// text is stale. Never touches the box while a parse runs or an error for
  /// it is on screen.
  void _clearStaleInput() {
    if (_busy || _errorCode != null) return;
    final text = _linkController.text;
    if (text.trim().isEmpty) return;
    if (inputIsStale(text, (l) => isLinkKnown(l, _knownPosts))) {
      _linkController.clear();
    }
  }

  Future<void> _checkClipboard() async {
    _clearStaleInput();
    final settings = await AppSettings.load();
    if (!settings.autoClipboard || !mounted) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    // YouTube detours to Seal before the supported-link check — otherwise
    // extractLink filters it out and no prompt ever appears.
    final yt = extractYouTubeLink(text);
    if (yt != null) {
      if (yt == _lastLink || yt == _linkController.text.trim()) return;
      _lastLink = yt;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('检测到 YouTube 链接'),
          content: Text(yt, maxLines: 3, overflow: TextOverflow.ellipsis),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('去 Seal'),
            ),
          ],
        ),
      );
      if (go == true && mounted) _handleLinks(text, entry: 'clipboard');
      return;
    }
    final links = extractLinks(text);
    if (links.isEmpty || !mounted) return;
    if (links.length > 1) {
      final key = 'batch:${links.join('|')}';
      if (key == _lastLink) return;
      _lastLink = key;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('检测到 ${links.length} 个链接'),
          content: Text(
            links.take(3).join('\n'),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('逐个解析'),
            ),
          ],
        ),
      );
      if (go == true && mounted) _handleLinks(text);
      return;
    }
    final link = links.single;
    if (link == _lastLink) return;
    _lastLink = link;
    // Same URL as the input box or any recent history entry: already
    // parsed (including via the floating bubble) or one tap away, don't
    // nag again.
    if (link == _linkController.text.trim()) return;
    if (await _alreadyDownloaded(link)) return;
    // An external entry (bubble) may have claimed this link, or started a
    // parse, while the history lookup was awaiting.
    if (!mounted || _busy || _externalLink == link) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(
          '检测到剪贴板链接',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: Text(link, maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('解析'),
          ),
        ],
      ),
    );
    if (go == true && mounted) _handleLinks(text);
  }

  Future<void> _initShareIntent() async {
    final instance = ReceiveSharingIntent.instance;
    final initial = await instance.getInitialMedia();
    await _handleSharedFiles(initial);
    instance.reset();
    _shareSub = instance.getMediaStream().listen((files) async {
      await _handleSharedFiles(files);
      instance.reset();
    });
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    if (_handlingShare || files.isEmpty) return;
    _handlingShare = true;
    try {
      final text = files.map((f) => f.path).join('\n');
      if (text.trim().isEmpty || !mounted) return;
      if (await routeExternalText(text, present: _showYouTubeSheet)) return;
      if (!mounted) return;

      // Extract single link and resolve directly (shows loading state)
      final links = extractLinks(text);
      if (links.length == 1) {
        // Show feedback that download is starting
        _showDownloadStartedSnackBar(1);
        await _resolve(links.first, entry: 'share');
        _reloadRecent();
      } else {
        // Multiple links: show multi-link dialog first, then batch page
        final go = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('发现 ${links.length} 个链接'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: links.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    links[i],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('逐个解析'),
              ),
            ],
          ),
        );
        if (go == true && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => BatchPage(links: links)),
          );
          _reloadRecent();
        } else if (go == false && mounted) {
          // User cancelled - no action needed
        }
      }
    } finally {
      _handlingShare = false;
    }
  }

  /// Show an error reported by the background engine / an error notification,
  /// using the same error page as a manual parse.
  void showExternalError(String url, String code, String? message) {
    setState(() {
      _busy = false;
      _errorCode = code;
      _errorMessage = message;
      if (url.isNotEmpty) {
        _currentLink = url;
        if (_linkController.text != url) {
          _linkController.value = TextEditingValue(
            text: url,
            selection: TextSelection.collapsed(offset: url.length),
          );
        }
      }
    });
    if (code == ParseErrorCode.loginRequired && url.isNotEmpty) {
      final platform = platformFromUrl(url);
      if (platform != null) LoginExpiredBus.markParseLoginRequired(platform);
    }
  }

  /// Show a snackbar indicating download has started.
  void _showDownloadStartedSnackBar(int count) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已开始下载 $count 个文件'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: '查看',
          onPressed: () {
            // Navigate to history tab - this is handled by the parent shell
            widget.onSeeAll?.call();
          },
        ),
      ),
    );
  }

  /// Parse + open the given url (e.g. the bubble's "打开 EasySave").
  Future<void> showExternalUrl(String url) async {
    if (url.trim().isEmpty) return;
    // Claim the clipboard key synchronously: the app is resuming at the same
    // moment and its clipboard check would otherwise prompt for the very
    // link we are about to open.
    final key = clipboardKeyOf(url);
    if (key != null) {
      _lastLink = key;
      _externalLink = key;
    }
    final links = extractLinks(url);
    if (links.isEmpty) return;
    if (!mounted) return;
    _handleLinks(url, entry: 'bubble');
  }

  void _showOffscreenError(String code, String? message) {
    showParseErrorSnackBar(
      context,
      code: code,
      message: message,
      onView: () => widget.onShowSelf?.call(),
    );
  }

  /// Resolve [link] and open its preview.
  ///
  /// [entry] names the entry point (bubble / clipboard / share / input ...) and
  /// is what the DevLog line reports, so a device log shows which door the
  /// request came through. The dedup rule itself lives in [PreviewOpenGuard].
  Future<void> _resolve(String link, {String entry = 'input'}) async {
    final tap = Stopwatch()..start();
    var waitMs = 0;
    final label = const {'input', 'share', 'clipboard', 'bubble', 'retry',
      'login', 'refresh', 'paste', 'batch'}.contains(entry) ? entry : 'other';
    void log(String event, {bool dedup = false}) {
      unawaited(DevLog.write('ParseFlow', 'event=$event entry=$label '
          'waitMs=$waitMs dedup=${dedup ? 1 : 0} elapsedMs=${tap.elapsedMilliseconds}'));
    }
    log('tap');
    final normalized = link.trim();
    final postId = postIdOfUrl(normalized);
    if (PreviewRouteObserver.instance.revealPreview(postId)) {
      log('previewShown', dedup: true);
      return;
    }
    if (_busy || _resolving) {
      log('start', dedup: true);
      widget.onShowSelf?.call();
      return;
    }
    final resolveToken = ++_resolveEpoch;
    if (_linkController.text != normalized) {
      _linkController.value = TextEditingValue(text: normalized,
          selection: TextSelection.collapsed(offset: normalized.length));
    }
    setState(() {
      _busy = true;
      _resolving = true;
      _cancelRequested = false;
      _errorCode = null;
      _errorMessage = null;
      _currentLink = normalized;
    });
    final offscreen = !(widget.isVisible?.call() ?? true);
    if (offscreen) {
      showParsingSnackBar(context, onCancel: () {
        if (mounted) setState(() { _cancelRequested = true; _busy = false; });
      });
    }
    waitMs = tap.elapsedMilliseconds;
    log('start');
    try {
      // The click path reads only the already loaded history snapshot. Opening
      // SQLite, repairing history or expanding a short link belongs elsewhere.
      final decision = await PreviewOpenGuard.decide(entry: entry,
          link: normalized, resolveShortLinks: false, knownRecords: _recentAll);
      if (!mounted || _cancelRequested || resolveToken != _resolveEpoch) return;
      if (decision.action == PreviewOpenAction.skipAlreadyOnPreview) return;
      ParseOutcome outcome;
      if (decision.cachedRecord != null && entry != 'refresh') {
        log('cacheHit');
        outcome = ParseOutcome(data: PreviewPage.postFromRecord(decision.cachedRecord!),
            rawImages: const []);
      } else {
        outcome = await parsePostOutcome(normalized,
            source: entry == 'bubble' ? 'bubble_open_app' : entry,
            forceRefresh: entry == 'refresh',
            onCacheHit: () => log('cacheHit'));
      }
      if (!mounted || _cancelRequested || resolveToken != _resolveEpoch) return;
      if (offscreen) ScaffoldMessenger.of(context).hideCurrentSnackBar();
      if (PreviewRouteObserver.instance.revealPreview(outcome.data.id)) {
        log('previewShown', dedup: true);
        return;
      }
      setState(() => _busy = false);
      final shown = PreviewPage.open(context,
        post: outcome.data, rawImages: outcome.rawImages,
        onSaved: () { if (mounted) _linkController.clear(); },
      );
      log('previewShown');
      await shown;
      unawaited(_reloadRecent());
    } on ParseFailure catch (e) {
      if (!mounted || _cancelRequested) return;
      setState(() { _errorCode = e.code; _errorMessage = e.message; });
      if (e.code == ParseErrorCode.loginRequired) {
        final platform = platformFromUrl(link);
        if (platform != null) LoginExpiredBus.markParseLoginRequired(platform);
      }
      if (offscreen) _showOffscreenError(e.code, e.message);
    } catch (e) {
      if (!mounted || _cancelRequested) return;
      unawaited(DevLog.write('ParseMismatch',
          'check=UNCAUGHT site=${platformFromUrl(link) ?? "-"} post=- '
          'expected=ParseFailure actual=type=${e.runtimeType}'));
      setState(() { _errorCode = ParseErrorCode.invalidPage; _errorMessage = null; });
      if (offscreen) _showOffscreenError(ParseErrorCode.invalidPage, null);
    } finally {
      if (mounted && _resolveEpoch == resolveToken) {
        setState(() { _busy = false; _resolving = false; });
        if (offscreen) ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
    }
  }

  Future<void> _onErrorAction(ErrorAction action) async {
    switch (action) {
      case ErrorAction.goLogin:
        final link = _currentLink.isNotEmpty
            ? _currentLink
            : _linkController.text.trim();
        // Prefer the platform we can read from the link; only fall back to a
        // chooser when the URL is unknown (keeps the dialog future-proof as
        // more platforms are added).
        final recognized = platformFromUrl(link);
        if (recognized != null && !loginSiteIds.contains(recognized)) return;
        final platform = loginSiteIds.contains(recognized)
            ? recognized
            : await _chooseLoginPlatform();
        if (platform != null && mounted) {
          final loggedIn = await Navigator.of(context).push<bool>(
            MaterialPageRoute<bool>(
              builder: (_) => LoginPage(platform: platform),
            ),
          );
          // Re-run the failed parse as soon as the session is confirmed, and
          // drop the card that sent the user to the login page: build 46 left
          // "未能获取图片，请检查 Instagram 登录后重试" on screen after a
          // successful login until 解析 was tapped again.
          if (loggedIn == true && mounted) {
            _clearErrorAfterLogin(platform);
            await _handleLinks(link, entry: 'login');
          }
        }
      case ErrorAction.backHome:
        setState(() => _errorCode = null);
      case ErrorAction.retry:
        _handleLinks(
          _currentLink.isNotEmpty ? _currentLink : _linkController.text.trim(),
          entry: 'retry',
        );
      case ErrorAction.repaste:
        _inputFocus.requestFocus();
    }
  }

  /// Clears the error card once [platform] reported a session.
  ///
  /// The card describes the state before the login; keeping it also kept
  /// `_busy`/`_resolving` from a parse that was cut short, which made the
  /// re-parse below return early instead of running.
  void _clearErrorAfterLogin(String? platform) {
    if (!mounted) return;
    final link = _currentLink.isNotEmpty
        ? _currentLink
        : _linkController.text.trim();
    final errorPlatform = platformFromUrl(link);
    if (!loginClearsErrorCard(
      errorPlatform: errorPlatform,
      loginPlatform: platform,
    )) {
      return;
    }
    setState(() {
      _errorCode = null;
      _errorMessage = null;
      _busy = false;
      _resolving = false;
      _cancelRequested = false;
    });
  }

  /// Fallback platform chooser (only shown when the link's platform is
  /// unknown). A scrollable list scales to any number of platforms.
  Future<String?> _chooseLoginPlatform() {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '选择要登录的平台',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            for (final siteId in loginSiteIds)
              ListTile(
                leading: PlatformIcon(platform: siteId),
                title: Text(platformLabel(siteId)),
                onTap: () => Navigator.of(context).pop(siteId),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          Stack(
            children: [
              Container(
                height: 200,
                decoration: const BoxDecoration(
                  gradient: AppTokens.mainGradient,
                ),
                alignment: Alignment.topLeft,
                padding: const EdgeInsets.fromLTRB(20, 56, 20, 0),
                child: const Text(
                  'EasySave',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                margin: const EdgeInsets.fromLTRB(16, 120, 16, 0),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color,
                  borderRadius: const BorderRadius.all(
                    Radius.circular(AppTokens.cardRadius),
                  ),
                  boxShadow: AppTokens.cardShadow,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _linkController,
                      focusNode: _inputFocus,
                      minLines: 1,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText:
                            '粘贴${SiteRegistry.current.sites.where((s) => s.enabled).map((s) => s.displayName).join(' / ')}链接',
                        filled: true,
                        fillColor: Theme.of(context).scaffoldBackgroundColor,
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                          borderSide: BorderSide.none,
                        ),
                        suffixIcon: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _linkController,
                          builder: (context, value, _) => Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (value.text.isNotEmpty)
                                IconButton(
                                  key: const ValueKey('clear-link-input'),
                                  tooltip: '清空链接',
                                  icon: const Icon(Icons.clear),
                                  onPressed: _linkController.clear,
                                ),
                              IconButton(
                                icon: const Icon(Icons.paste),
                                tooltip: '粘贴',
                                onPressed: () async {
                                  final data = await Clipboard.getData(
                                    Clipboard.kTextPlain,
                                  );
                                  if (data?.text != null) {
                                    _linkController.text = data!.text!;
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_busy)
                      Row(
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(child: Text('解析中…')),
                          TextButton(
                            onPressed: () => setState(() {
                              _cancelRequested = true;
                              _busy = false;
                            }),
                            child: const Text('取消'),
                          ),
                        ],
                      )
                    else
                      GradientButton(
                        label: '解析',
                        onPressed: () => _handleLinks(
                          _linkController.text.trim(),
                          entry: 'input',
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (_errorCode != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: ErrorCard(
                code: _errorCode!,
                canLogin: platformFromUrl(_linkController.text.trim()) == null
                    ? loginSiteIds.isNotEmpty
                    : loginSiteIds.contains(
                        platformFromUrl(_linkController.text.trim()),
                      ),
                message: _errorMessage,
                onAction: _onErrorAction,
                diagnostics: () =>
                    'platform=?, code=$_errorCode, url=${_linkController.text.trim()}, app=$_appVersion, parser=${ParserManager.instance.activeVersion}(${ParserManager.instance.activeSourceLabel})',
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '最近保存',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton(
                  onPressed: widget.onSeeAll,
                  child: const Text('查看全部 →'),
                ),
              ],
            ),
          ),
          if (!_recentLoaded && _recent.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(height: 56),
            )
          else if (_recent.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text('粘贴链接开始第一次保存'),
            )
          else
            for (final record in _recent)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Card(
                  child: ListTile(
                    onTap: _openingRecordId != null
                        ? null
                        : () => _openRecord(record),
                    leading: _thumbOf(context, record),
                    title: Text(
                      (record.title?.isNotEmpty == true)
                          ? record.title!
                          : '无标题',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${record.authorName ?? ''} · '
                      '${savedMediaEntryCount(record.savedFiles)} 个文件',
                    ),
                    trailing: _openingRecordId == (record.id ?? -1)
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PlatformTag(
                                platform: record.platform,
                                savedDisplayName: record.platformDisplayName,
                              ),
                              AiLabelBadge(
                                text: record.aiLabel,
                                source: record.aiLabelSource,
                              ),
                            ],
                          ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  int? _openingRecordId;

  /// Re-parse a record from the recent list (mirrors HistoryPage._reparse).
  Future<void> _reparseRecord(HistoryRecord record) async {
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
      final outcome = await parsePostOutcome(
        record.postUrl,
        source: 'recent_refresh',
        forceRefresh: true,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      unawaited(PreviewPage.open(context, post: outcome.data, rawImages: outcome.rawImages));
      _reloadRecent();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      final isLoginRequired =
          e is ParseFailure &&
          e.code == ParseErrorCode.loginRequired &&
          loginSiteIds.contains(record.platform);
      final isUnavailable =
          e is ParseFailure && e.code == ParseErrorCode.privateOrUnavailable;

      // Try to show cached data with a warning snackbar.
      final cachedPost = PreviewPage.postFromRecord(record);
      final platform = platformFromKey(record.platform);
      if (cachedPost.items.isNotEmpty) {
        unawaited(PreviewPage.open(context, post: cachedPost));
        if (isLoginRequired) {
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
                  if (loggedIn == true && mounted) {
                    await _reparseRecord(record);
                  }
                },
              ),
            ),
          );
        } else if (isUnavailable) {
          // Not a login problem: the share link lost its `xsec_token` (or it
          // expired), so XHS can't serve the note again.
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已使用本地记录打开预览（重新解析需重新粘贴分享链接）')),
          );
        }
        return;
      }

      if (isLoginRequired) {
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
                if (loggedIn == true && mounted) {
                  await _reparseRecord(record);
                }
              },
            ),
          ),
        );
        return;
      }

      final msg = e is ParseFailure ? e.message : '$e';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('解析失败：$msg')));
    }
  }

  Future<void> _openRecord(HistoryRecord record) async {
    // Guard against tap storms: a second push while the transition is
    // still running stacks identical routes and makes "back" look dead.
    if (_openingRecordId != null) return;
    setState(() => _openingRecordId = record.id ?? -1);

    try {
      final post = PreviewPage.postFromRecord(record);
      final locator = GalleryLocatorService.instance;

      final built = await savedBrowserItems(
        record: record,
        files: record.files,
        post: post,
      );
      final items = built.items;

      if (items.isEmpty && post.items.isNotEmpty) {
        for (var i = 0; i < post.items.length; i++) {
          final postItem = post.items[i];
          items.add(
            GalleryBrowserItem.fromMediaItem(
              postItem,
              index: i,
              cachePostId: record.postId,
              status: FileStatus.unknown,
            ),
          );
        }
      }

      if (items.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未找到可查看的媒体文件')));
        }
        return;
      }

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => GalleryBrowserPage(
            items: items,
            authorName: record.authorName ?? '',
            title: (record.title?.isNotEmpty == true)
                ? record.title!
                : record.postId,
            platform: record.platform,
            postUrl: record.postUrl,
            aiLabel: record.aiLabel,
            aiLabelSource: record.aiLabelSource,
            onReparse: () {
              // Pop GalleryBrowser first, then reparse with feedback.
              Navigator.of(context).pop();
              _reparseRecord(record);
            },
            onRedownload: (index) async {
              await DownloadSheet.show(context, post, [index]);
              await locator.scanAlbum(force: true);
              await locator.syncRecord(record);
              if (mounted) setState(() {});
            },
          ),
        ),
      );
      _reloadRecent();
    } finally {
      if (mounted) {
        setState(() => _openingRecordId = null);
      } else {
        _openingRecordId = null;
      }
    }
  }

  /// 48px leading thumbnail; reads local album asset without CDN requests.
  Widget? _thumbOf(BuildContext context, HistoryRecord record) {
    final locator = GalleryLocatorService.instance;

    AssetEntity? asset;
    for (final f in record.files) {
      asset =
          locator.getAssetById(f.mediaId) ??
          locator.locateAsset(f, record.postId);
      if (asset != null) break;
    }

    if (asset != null) {
      return ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        child: Container(
          width: 48,
          height: 48,
          color: SecondaryBg.beige(context),
          child: Image(
            image: AssetEntityImageProvider(
              asset,
              isOriginal: false,
              thumbnailSize: const ThumbnailSize.square(150),
            ),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: child,
              );
            },
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image, size: 24, color: Colors.grey),
            ),
          ),
        ),
      );
    }

    final allNotFound =
        record.files.isNotEmpty &&
        record.files.every((f) => f.status == FileStatus.notFound);

    if (locator.isFullyAuthorized && locator.scanned && allNotFound) {
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

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: SecondaryBg.beige(context),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: const Icon(
        Icons.photo_outlined,
        size: 24,
        color: AppTokens.textSecondary,
      ),
    );
  }
}
