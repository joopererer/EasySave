// Mine tab: account group, download settings, other.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/auth.dart';
import '../services/settings.dart';
import '../services/update_service.dart';
import 'login_page.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  final Map<PlatformKind, bool> _loggedIn = {
    for (final p in PlatformKind.values) p: false,
  };
  bool _checkingLogin = true;
  AppSettings _settings = AppSettings();
  String _version = '';
  String _nickname = '';
  Set<PlatformKind> _lastExpired = const {};

  @override
  void initState() {
    super.initState();
    _lastExpired = LoginExpiredBus.expired.value;
    _load();
    LoginExpiredBus.expired.addListener(_onExpired);
  }

  @override
  void dispose() {
    LoginExpiredBus.expired.removeListener(_onExpired);
    super.dispose();
  }

  void _onExpired() {
    if (!mounted) return;
    final now = LoginExpiredBus.expired.value;
    final newlyExpired = now.difference(_lastExpired);
    final recovered = _lastExpired.difference(now);
    _lastExpired = now;
    if (newlyExpired.isNotEmpty || recovered.isNotEmpty) {
      setState(() {
        // A parse just proved these stored sessions are dead: show it now.
        for (final p in newlyExpired) {
          _loggedIn[p] = false;
        }
      });
    }
    // "Recovered" means a login succeeded elsewhere (e.g. from the history
    // tab); refresh those rows so the tab isn't stuck on "未登录".
    for (final p in recovered) {
      _refreshPlatform(p);
    }
  }

  Future<void> _refreshPlatform(PlatformKind platform) async {
    final ok = await checkLogin(platform);
    if (!mounted) return;
    if (ok) LoginExpiredBus.clear(platform);
    final account = platform == PlatformKind.xhs
        ? XhsAccountCache.value ?? await XhsAccountCache.load()
        : null;
    setState(() {
      _loggedIn[platform] = ok;
      if (account != null) _nickname = account.nickname ?? '';
    });
  }

  Future<void> _load() async {
    final settings = await AppSettings.load();
    // Cached page-state answer first: instant, and it survives app restarts.
    final cachedXhs = await XhsAccountCache.load();
    final ig = await isLoggedIn(PlatformKind.instagram);
    final x = await isLoggedIn(PlatformKind.x);
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _loggedIn[PlatformKind.xhs] = cachedXhs?.loggedIn ?? false;
      _loggedIn[PlatformKind.instagram] = ig;
      _loggedIn[PlatformKind.x] = x;
      _nickname = cachedXhs?.nickname ?? '';
      _checkingLogin = false;
      _version = '${info.version}+${info.buildNumber}';
    });
    // No cached answer (never logged in through the login page, or the cache
    // was cleared): fall back to the cookie jar plus a network probe. This
    // runs after the first paint, so the tab still renders instantly.
    if (cachedXhs == null) {
      final cookieLogin = await checkLogin(PlatformKind.xhs);
      if (!mounted) return;
      setState(() => _loggedIn[PlatformKind.xhs] = cookieLogin);
    }
  }


  Future<void> _saveSettings() => _settings.save();

  Future<void> _openLogin(PlatformKind platform) async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => LoginPage(platform: platform)),
    );
    if (!mounted) return;
    setState(() => _checkingLogin = true);
    // Trust the login page result after a successful flow (it verified the
    // session end-to-end); otherwise re-check the cookie store.
    final loggedIn = ok == true ? true : await checkLogin(platform);
    if (!mounted) return;
    if (loggedIn) {
      LoginExpiredBus.clear(platform);
    } else {
      LoginExpiredBus.markExpired(platform);
    }
    final account = platform == PlatformKind.xhs
        ? XhsAccountCache.value ?? await XhsAccountCache.load()
        : null;
    setState(() {
      _loggedIn[platform] = loggedIn;
      if (account != null) _nickname = account.nickname ?? '';
      _checkingLogin = false;
    });
  }

  Future<void> _logout(PlatformKind platform) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: Text('确定退出${platformLabel(platform)}登录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await logout(platform);
      if (!mounted) return;
      setState(() {
        _loggedIn[platform] = false;
        if (platform == PlatformKind.xhs) _nickname = '';
      });
    }
  }

  Future<void> _editText({
    required String title,
    required String initial,
    required ValueChanged<String> onSave,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      setState(() => onSave(result));
      await _saveSettings();
    }
  }

  Future<void> _clearCache() async {
    PaintingBinding.instance.imageCache.clear();
    final temp = Directory.systemTemp;
    var removed = 0;
    try {
      await for (final entity in temp.list()) {
        if (entity.path.contains('easysave_')) {
          try {
            await entity.delete(recursive: true);
            removed++;
          } catch (_) {
            // Best effort per file.
          }
        }
      }
    } catch (_) {
      // Listing temp is best effort.
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已清理缓存（$removed 个临时文件）')));
  }

  /// Subtitle for a platform row: "已登录" / "未登录", plus a hint when a
  /// parse recently proved the stored session is dead.
  Widget _loginSubtitle(PlatformKind platform) {
    final loggedIn = _loggedIn[platform]!;
    final expired = LoginExpiredBus.expired.value.contains(platform);
    if (expired) {
      return const Text(
        '登录已失效，请重新登录',
        style: TextStyle(color: Colors.orange),
      );
    }
    if (loggedIn &&
        platform == PlatformKind.xhs &&
        _nickname.trim().isNotEmpty) {
      return Text(
        '已登录（${_nickname.trim()}）',
        style: const TextStyle(color: Colors.green),
      );
    }
    return Text(
      loggedIn ? '已登录' : '未登录',
      style: TextStyle(color: loggedIn ? Colors.green : Colors.grey),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _GroupTitle('账号'),
          Card(
            child: Column(
              children: [
                for (final platform in PlatformKind.values)
                  if (_checkingLogin)
                    ListTile(
                      title: Text(platformLabel(platform)),
                      subtitle: const Text('检查中…'),
                      trailing: const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    ListTile(
                      title: Text(platformLabel(platform)),
                      subtitle: _loginSubtitle(platform),
                      trailing: _loggedIn[platform]!
                          ? TextButton(
                              onPressed: () => _logout(platform),
                              child: const Text('退出登录'),
                            )
                          : TextButton(
                              onPressed: () => _openLogin(platform),
                              child: const Text('去登录'),
                            ),
                    ),
              ],
            ),
          ),
          const _GroupTitle('下载设置'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('相册名称'),
                  subtitle: Text(_settings.albumName),
                  onTap: () => _editText(
                    title: '相册名称',
                    initial: _settings.albumName,
                    onSave: (v) => _settings.albumName = v,
                  ),
                ),
                ListTile(
                  title: const Text('文件名格式'),
                  subtitle: Text(_settings.namePattern),
                  onTap: () => _editText(
                    title: '文件名格式（{id} {seq} {date} {author}）',
                    initial: _settings.namePattern,
                    onSave: (v) => _settings.namePattern = v,
                  ),
                ),
                SwitchListTile(
                  title: const Text('同时保存文案为 txt'),
                  value: _settings.saveCaptionTxt,
                  onChanged: (v) async {
                    setState(() => _settings.saveCaptionTxt = v);
                    await _saveSettings();
                  },
                ),
                SwitchListTile(
                  title: const Text('自动检测剪贴板'),
                  value: _settings.autoClipboard,
                  onChanged: (v) async {
                    setState(() => _settings.autoClipboard = v);
                    await _saveSettings();
                  },
                ),
              ],
            ),
          ),
          const _GroupTitle('其他'),
          Card(
            child: Column(
              children: [
                ListTile(title: const Text('清除缓存'), onTap: _clearCache),
                ListTile(title: const Text('版本号'), subtitle: Text(_version)),
                ListTile(
                  title: const Text('解析器版本'),
                  subtitle: Text(
                    '${ParserManager.instance.activeVersion} (${ParserManager.instance.activeSourceLabel})',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: '检查更新',
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      messenger.showSnackBar(
                        const SnackBar(content: Text('正在检查解析器更新…')),
                      );
                      final updated = await ParserManager.instance.checkForUpdates(force: true);
                      if (!mounted) return;
                      setState(() {});
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            updated ? '解析器已更新到最新版本' : '当前已是最新解析器',
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const _GroupTitle('v1.6 技术验证（临时）'),
          const Card(child: _V16ValidationCard()),
        ],
      ),
    );
  }
}

/// Temporary v1.6 validation controls (remove after the approach is chosen).
class _V16ValidationCard extends StatefulWidget {
  const _V16ValidationCard();

  @override
  State<_V16ValidationCard> createState() => _V16ValidationCardState();
}

class _V16ValidationCardState extends State<_V16ValidationCard> {
  static const _channel = MethodChannel('easysave/v16test');
  final _xhs = TextEditingController();
  final _ig = TextEditingController();
  final _x = TextEditingController();
  bool _overlayOn = false;

  @override
  void dispose() {
    _xhs.dispose();
    _ig.dispose();
    _x.dispose();
    super.dispose();
  }

  void _toast(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  Future<void> _startBgParse() async {
    final urls = [_xhs.text.trim(), _ig.text.trim(), _x.text.trim()]
        .where((u) => u.isNotEmpty)
        .toList();
    if (urls.isEmpty) {
      _toast('请至少填写一个链接');
      return;
    }
    await _channel.invokeMethod('startBgParse', {'urls': urls});
    _toast('已启动后台解析，结果见 Logcat: V16VAL 或通知栏');
  }

  Future<void> _toggleOverlay() async {
    if (_overlayOn) {
      await _channel.invokeMethod('stopOverlay');
      if (mounted) setState(() => _overlayOn = false);
    } else {
      final ok = await _channel.invokeMethod<bool>('startOverlay') ?? false;
      if (mounted) setState(() => _overlayOn = ok);
      if (!ok) _toast('请授予"显示在其他应用上层"权限后再次点击');
    }
  }

  Widget _field(String label, TextEditingController c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: TextField(
      controller: c,
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '仅用于技术验证，方法回调结果在 Logcat 过滤 V16VAL。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        _field('小红书链接', _xhs),
        _field('Instagram 链接', _ig),
        _field('X 链接', _x),
        ListTile(
          title: const Text('① 后台解析（独立引擎，无 Activity）'),
          subtitle: const Text('同时验证 cookie 共享，结果见 Logcat/通知栏'),
          trailing: const Icon(Icons.play_arrow),
          onTap: _startBgParse,
        ),
        ListTile(
          title: const Text('② 悬浮球 + 剪贴板 + 原生面板'),
          subtitle: Text(_overlayOn ? '运行中，点击关闭' : '未运行'),
          trailing: Icon(_overlayOn ? Icons.stop : Icons.play_arrow),
          onTap: _toggleOverlay,
        ),
      ],
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(
        text,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }
}
