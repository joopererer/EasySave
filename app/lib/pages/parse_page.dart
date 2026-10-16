// Parse tab: gradient header with overlapping input card, clipboard
// auto-detect, progress/cancel and error states, recent history.

import 'dart:async';

import 'package:easysave/generated/parser_version.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/error_copy.dart';
import '../core/models.dart';
import '../services/auth.dart';
import '../services/history_db.dart';
import '../services/links.dart';
import '../services/parse_service.dart';
import '../services/saver.dart';
import '../services/seal.dart';
import '../services/settings.dart';
import '../theme/app_theme.dart';
import '../widgets/shared.dart';
import 'batch_page.dart';
import 'login_page.dart';
import 'preview_page.dart';

class ParsePage extends StatefulWidget {
  const ParsePage({super.key, this.onSeeAll});

  final VoidCallback? onSeeAll;

  @override
  State<ParsePage> createState() => _ParsePageState();
}

class _ParsePageState extends State<ParsePage> with WidgetsBindingObserver {
  final _linkController = TextEditingController();
  final _inputFocus = FocusNode();
  bool _busy = false;
  bool _cancelRequested = false;
  String? _errorCode;
  String _lastLink = '';
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

  Future<void> _resolve(String link) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _cancelRequested = false;
      _errorCode = null;
    });
    try {
      final outcome = await parsePostOutcome(link);
      if (!mounted || _cancelRequested) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              PreviewPage(post: outcome.data, rawImages: outcome.rawImages),
        ),
      );
      _reloadRecent();
    } on ParseFailure catch (e) {
      if (!mounted || _cancelRequested) return;
      setState(() {
        _busy = false;
        _errorCode = e.code;
      });
      if (e.code == ParseErrorCode.loginRequired) {
        LoginExpiredBus.notify(e.code);
      }
    } catch (_) {
      if (!mounted || _cancelRequested) return;
      setState(() {
        _busy = false;
        _errorCode = ParseErrorCode.invalidPage;
      });
    }
  }

  Future<void> _onErrorAction(ErrorAction action) async {
    switch (action) {
      case ErrorAction.goLogin:
        final platform = await showDialog<PlatformKind>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('需要登录'),
            content: const Text('请选择要登录的平台，登录后重新解析。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(null),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(PlatformKind.xhs),
                child: const Text('小红书登录'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(PlatformKind.instagram),
                child: const Text('IG 登录'),
              ),
            ],
          ),
        );
        if (platform != null && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => LoginPage(platform: platform),
            ),
          );
        }
      case ErrorAction.backHome:
        setState(() => _errorCode = null);
      case ErrorAction.retry:
        _handleLinks(_linkController.text.trim());
      case ErrorAction.repaste:
        _inputFocus.requestFocus();
    }
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
                onAction: _onErrorAction,
                diagnostics: () =>
                    'platform=?, code=$_errorCode, url=${_linkController.text.trim()}, app=$_appVersion, parser=${ParserVersion.version}',
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

  void _openRecord(HistoryRecord record) {
    // Guard against tap storms: a second push while the transition is
    // still running stacks identical routes and makes "back" look dead.
    if (_openingRecord) return;
    _openingRecord = true;
    final post = PreviewPage.postFromRecord(record);
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => PreviewPage(post: post)))
        .then((_) {
          _openingRecord = false;
          _reloadRecent();
        });
  }

  /// 48px leading thumbnail; null-safe — a video URL is never rendered.
  Widget? _thumbOf(BuildContext context, HistoryRecord record) {
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
