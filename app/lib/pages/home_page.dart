// Home: login status, link input, clipboard prompt, share-intent entry.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../core/models.dart';
import '../services/auth.dart';
import '../services/links.dart';
import '../services/parse_service.dart';
import 'login_page.dart';
import 'preview_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _linkController = TextEditingController();
  final Map<PlatformKind, bool> _loggedIn = {
    PlatformKind.xhs: false,
    PlatformKind.instagram: false,
  };
  bool _busy = false;
  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  bool _handlingShare = false;

  @override
  void initState() {
    super.initState();
    _refreshLoginStatus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
    _initShareIntent();
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _refreshLoginStatus() async {
    final xhs = await isLoggedIn(PlatformKind.xhs);
    final ig = await isLoggedIn(PlatformKind.instagram);
    if (!mounted) return;
    setState(() {
      _loggedIn[PlatformKind.xhs] = xhs;
      _loggedIn[PlatformKind.instagram] = ig;
    });
  }

  Future<void> _checkClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final link = data?.text == null ? null : extractLink(data!.text!);
    if (link == null || !mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('检测到剪贴板链接'),
        content: Text(link, maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('忽略'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('一键解析'),
          ),
        ],
      ),
    );
    if (go == true && mounted) _resolve(link);
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
      for (final file in files) {
        final link = extractLink(file.path);
        if (link != null) {
          if (!mounted) return;
          await _resolve(link);
          return;
        }
      }
    } finally {
      _handlingShare = false;
    }
  }

  Future<void> _resolve(String link) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final post = await parsePostUrl(link);
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PreviewPage(post: post)),
      );
    } on ParseFailure catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (e.code == ParseErrorCode.loginRequired) {
        await _promptLogin();
      } else {
        _snack(e.message);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('解析失败：$e');
    }
  }

  Future<void> _promptLogin() async {
    final platform = await showDialog<PlatformKind>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('需要登录'),
        content: const Text('对方要求登录后查看，请选择要登录的平台，登录后重新解析。'),
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
            onPressed: () => Navigator.of(context).pop(PlatformKind.instagram),
            child: const Text('IG 登录'),
          ),
        ],
      ),
    );
    if (platform != null && mounted) {
      await _openLogin(platform);
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openLogin(PlatformKind platform) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LoginPage(platform: platform)),
    );
    await _refreshLoginStatus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('EasySave')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('登录状态', style: TextStyle(fontWeight: FontWeight.bold)),
          for (final platform in PlatformKind.values)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(platformLabel(platform)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _loggedIn[platform]! ? '已登录' : '未登录',
                    style: TextStyle(
                      color: _loggedIn[platform]! ? Colors.green : Colors.grey,
                    ),
                  ),
                  TextButton(
                    onPressed: () => _openLogin(platform),
                    child: const Text('去登录'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          const Text('解析链接', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _linkController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '粘贴小红书 / Instagram 链接',
            ),
            minLines: 1,
            maxLines: 3,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _busy
                  ? null
                  : () {
                      final link = extractLink(_linkController.text.trim());
                      if (link == null) {
                        _snack('没有找到支持的链接');
                        return;
                      }
                      _resolve(link);
                    },
              child: Text(_busy ? '解析中…' : '解析'),
            ),
          ),
        ],
      ),
    );
  }
}
