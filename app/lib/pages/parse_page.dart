// Parse tab: gradient header with overlapping input card, clipboard
// auto-detect, progress/cancel and error states, recent history.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/error_copy.dart';
import '../core/models.dart';
import '../services/auth.dart';
import '../services/gallery_locator_service.dart';
import '../services/history_db.dart';
import '../services/links.dart';
import '../services/parse_service.dart';
import '../services/seal.dart';
import '../services/settings.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/download_sheet.dart';
import '../widgets/gallery_browser.dart';
import '../widgets/shared.dart';
import 'batch_page.dart';
import 'login_page.dart';
import 'preview_page.dart';

class ParsePage extends StatefulWidget {
  const ParsePage({super.key, this.onSeeAll});

  final VoidCallback? onSeeAll;

  @override
  State<ParsePage> createState() => ParsePageState();
}

class ParsePageState extends State<ParsePage> with WidgetsBindingObserver {
  final _linkController = TextEditingController();
  final _inputFocus = FocusNode();
  bool _busy = false;
  bool _cancelRequested = false;
  String? _errorCode;
  String? _errorMessage;
  String _lastLink = '';
  String _currentLink = '';
  String _appVersion = '';
  List<HistoryRecord> _recent = [];
  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  bool _handlingShare = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkClipboard();
      _reloadRecent();
      _loadVersion();
    });
    _initShareIntent();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _appVersion = '${info.version}+${info.buildNumber}');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
      _reloadRecent();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareSub?.cancel();
    _linkController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _reloadRecent() async {
    final records = await HistoryDb.instance().then(
      (db) => db.recent(limit: 3),
    );
    if (!mounted) return;
    setState(() => _recent = records);
    final locator = GalleryLocatorService.instance;
    await locator.checkPermission();
    if (locator.hasAccess) {
      await locator.preloadMediaIds(records);
      if (mounted) setState(() {});
      await locator.syncAll(records);
      if (mounted) setState(() {});
    }
  }

  /// Single entry for clipboard dialog, paste button and share intents:
  /// YouTube links detour to Seal, multiple links open the batch queue,
  /// exactly one supported link resolves directly.
  Future<void> _handleLinks(String text) async {
    final yt = extractYouTubeLink(text);
    if (yt != null) {
      await _showYouTubeSheet(yt);
      return;
    }
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
      await _resolve(links.first);
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

  Future<void> _checkClipboard() async {
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
      if (go == true && mounted) _handleLinks(text);
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
    // Same URL as the input box or the latest history entry: already
    // parsed or one tap away, don't nag again.
    if (link == _linkController.text.trim()) return;
    if (_recent.isNotEmpty && link == _recent.first.postUrl) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('检测到剪贴板链接'),
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
      await _handleLinks(text);
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
      if (platform != null) LoginExpiredBus.markExpired(platform);
    }
  }

  /// Parse + open the given url (e.g. the bubble's "打开 EasySave").
  void showExternalUrl(String url) {
    if (url.trim().isEmpty) return;
    _handleLinks(url);
  }

  Future<void> _resolve(String link) async {
    if (_busy) return;
    _currentLink = link;
    // Reflect the link actually being parsed (it may come from a share intent,
    // not the box), so retry / login flows re-use the correct one.
    if (_linkController.text != link) {
      _linkController.value = TextEditingValue(
        text: link,
        selection: TextSelection.collapsed(offset: link.length),
      );
    }
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _errorCode = null;
      _errorMessage = null;
    });
    try {
      final outcome = await parsePostOutcome(link);
      if (!mounted || _cancelRequested) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PreviewPage(
            post: outcome.data,
            rawImages: outcome.rawImages,
            onSaved: () {
              if (mounted) _linkController.clear();
            },
          ),
        ),
      );
      _reloadRecent();
    } on ParseFailure catch (e) {
      if (!mounted || _cancelRequested) return;
      setState(() {
        _busy = false;
        _errorCode = e.code;
        _errorMessage = e.message;
      });
      if (e.code == ParseErrorCode.loginRequired) {
        final platform = platformFromUrl(link);
        if (platform != null) LoginExpiredBus.markExpired(platform);
      }
    } catch (_) {
      if (!mounted || _cancelRequested) return;
      setState(() {
        _busy = false;
        _errorCode = ParseErrorCode.invalidPage;
        _errorMessage = null;
      });
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
        final platform = platformFromUrl(link) ?? await _chooseLoginPlatform();
        if (platform != null && mounted) {
          final loggedIn = await Navigator.of(context).push<bool>(
            MaterialPageRoute<bool>(
              builder: (_) => LoginPage(platform: platform),
            ),
          );
          // Re-run the failed parse as soon as the session is confirmed.
          if (loggedIn == true && mounted) {
            _handleLinks(link);
          }
        }
      case ErrorAction.backHome:
        setState(() => _errorCode = null);
      case ErrorAction.retry:
        _handleLinks(
          _currentLink.isNotEmpty ? _currentLink : _linkController.text.trim(),
        );
      case ErrorAction.repaste:
        _inputFocus.requestFocus();
    }
  }

  /// Fallback platform chooser (only shown when the link's platform is
  /// unknown). A scrollable list scales to any number of platforms.
  Future<PlatformKind?> _chooseLoginPlatform() {
    return showModalBottomSheet<PlatformKind>(
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
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('小红书'),
              onTap: () => Navigator.of(context).pop(PlatformKind.xhs),
            ),
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('Instagram'),
              onTap: () => Navigator.of(context).pop(PlatformKind.instagram),
            ),
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text('X'),
              onTap: () => Navigator.of(context).pop(PlatformKind.x),
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
                        hintText: '粘贴小红书 / Instagram 链接',
                        filled: true,
                        fillColor: Theme.of(context).scaffoldBackgroundColor,
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(16)),
                          borderSide: BorderSide.none,
                        ),
                        suffixIcon: IconButton(
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
                        onPressed: () =>
                            _handleLinks(_linkController.text.trim()),
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
          if (_recent.isEmpty)
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
                    onTap: () => _openRecord(record),
                    leading: _thumbOf(context, record),
                    title: Text(
                      (record.title?.isNotEmpty == true)
                          ? record.title!
                          : '无标题',
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
      ),
    );
  }

  bool _openingRecord = false;

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
      _reloadRecent();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      final isLoginRequired =
          e is ParseFailure && e.code == ParseErrorCode.loginRequired;
      final isUnavailable =
          e is ParseFailure && e.code == ParseErrorCode.privateOrUnavailable;

      // Try to show cached data with a warning snackbar.
      final cachedPost = PreviewPage.postFromRecord(record);
      final platform = platformFromKey(record.platform);
      if (cachedPost.items.isNotEmpty) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PreviewPage(post: cachedPost),
          ),
        );
        if (isLoginRequired) {
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
            const SnackBar(
              content: Text('已使用本地记录打开预览（重新解析需重新粘贴分享链接）'),
            ),
          );
        }
        return;
      }

      if (isLoginRequired) {
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('解析失败：$msg')),
      );
    }
  }

  void _openRecord(HistoryRecord record) {
    // Guard against tap storms: a second push while the transition is
    // still running stacks identical routes and makes "back" look dead.
    if (_openingRecord) return;
    _openingRecord = true;

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
          posterUrl: postItem.posterUrl,
          fallbacks: postItem.fallbacks,
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
        )
        .then((_) {
          _openingRecord = false;
          _reloadRecent();
        });
  }

  /// 48px leading thumbnail; reads local album asset without CDN requests.
  Widget? _thumbOf(BuildContext context, HistoryRecord record) {
    final locator = GalleryLocatorService.instance;

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

    // Show shimmering loading box while preloading known mediaIds or scanning album
    final hasPendingFiles = record.files.any(
      (f) => f.status != FileStatus.notFound,
    );
    if (hasPendingFiles && (locator.isScanning || !locator.scanned)) {
      return const ShimmerBox(width: 48, height: 48);
    }

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
