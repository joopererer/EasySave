// Mine tab: account group, download settings, other.

import 'dart:io';

import 'package:flutter/material.dart';
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
    PlatformKind.xhs: false,
    PlatformKind.instagram: false,
  };
  bool _checkingLogin = true;
  AppSettings _settings = AppSettings();
  String _version = '';

  @override
  void initState() {
    super.initState();
    _load();
    LoginExpiredBus.code.addListener(_onExpired);
  }

  @override
  void dispose() {
    LoginExpiredBus.code.removeListener(_onExpired);
    super.dispose();
  }

  void _onExpired() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final settings = await AppSettings.load();
    final xhs = await isLoggedIn(PlatformKind.xhs);
    final ig = await isLoggedIn(PlatformKind.instagram);
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _loggedIn[PlatformKind.xhs] = xhs;
      _loggedIn[PlatformKind.instagram] = ig;
      _checkingLogin = false;
      _version = '${info.version}+${info.buildNumber}';
    });
  }

  Future<void> _saveSettings() => _settings.save();

  Future<void> _openLogin(PlatformKind platform) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LoginPage(platform: platform)),
    );
    setState(() => _checkingLogin = true);
    final loggedIn = await isLoggedIn(platform);
    if (!mounted) return;
    setState(() {
      _loggedIn[platform] = loggedIn;
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
      setState(() => _loggedIn[platform] = false);
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

  @override
  Widget build(BuildContext context) {
    final expired = LoginExpiredBus.code.value;
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
                  ListTile(
                    title: Text(platformLabel(platform)),
                    subtitle: _checkingLogin
                        ? const Text('检查中…')
                        : Text(
                            _loggedIn[platform]! ? '已登录' : '未登录',
                            style: TextStyle(
                              color: _loggedIn[platform]!
                                  ? Colors.green
                                  : Colors.grey,
                            ),
                          ),
                    trailing: _checkingLogin
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : _loggedIn[platform]!
                        ? TextButton(
                            onPressed: () => _logout(platform),
                            child: const Text('退出登录'),
                          )
                        : TextButton(
                            onPressed: () => _openLogin(platform),
                            child: const Text('去登录'),
                          ),
                  ),
                if (expired == 'LOGIN_REQUIRED')
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(
                      '登录已过期，请重新登录',
                      style: TextStyle(color: Colors.orange),
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
        ],
      ),
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
