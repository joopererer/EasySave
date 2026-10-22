// Mine tab: account group, download settings, other.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/dev_log.dart';
import '../services/album_name_registry.dart';
import '../services/auth.dart';
import '../services/bubble_service.dart';
import '../services/gallery_locator_service.dart';
import '../services/history_backfill_service.dart';
import '../services/history_rebuild_service.dart';
import '../services/settings.dart';
import '../services/tile_service.dart';
import '../services/update_service.dart';
import 'login_page.dart';

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> with WidgetsBindingObserver {
  final Map<PlatformKind, bool> _loggedIn = {
    for (final p in PlatformKind.values) p: false,
  };
  bool _checkingLogin = true;
  AppSettings _settings = AppSettings();
  String _version = '';
  String _nickname = '';
  Set<PlatformKind> _lastExpired = const {};
  bool _pendingBubbleEnable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastExpired = LoginExpiredBus.expired.value;
    _load();
    LoginExpiredBus.expired.addListener(_onExpired);
    // Reconcile the bubble toggle with the actual service state on first frame
    // (covers a cold start where the bubble was closed via drag elsewhere).
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncBubbleState());
    // Reconcile while the app stays in the foreground: dragging the bubble to
    // the close zone sends a native push (no lifecycle transition happens).
    BubbleService.startListening();
    BubbleService.stateTick.addListener(_onBubbleTick);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    BubbleService.stateTick.removeListener(_onBubbleTick);
    LoginExpiredBus.expired.removeListener(_onExpired);
    super.dispose();
  }

  /// Native pushed a bubble state change: reconcile the toggle right away.
  void _onBubbleTick() => _syncBubbleState();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncBubbleState();
    }
  }

  /// Keep the bubble toggle in sync with the ACTUAL bubble service. The service
  /// is the source of truth: closing the bubble by dragging it to the close
  /// zone stops the service, and starting/undoing it starts the service, so the
  /// switch always reflects reality regardless of how/where it was changed.
  Future<void> _syncBubbleState() async {
    final granted = await BubbleService.hasPermission();
    if (_pendingBubbleEnable) {
      _pendingBubbleEnable = false;
      if (granted) {
        final started = await BubbleService.start();
        if (!mounted) return;
        setState(() => _settings.bubbleEnabled = started);
        await _saveSettings();
        if (started) await _maybeShowAutostartHint();
      } else {
        // User came back without granting the overlay permission.
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未授予"显示在其他应用上层"权限，悬浮球未开启')),
        );
      }
      return;
    }
    final running = granted && await BubbleService.isRunning();
    if (!mounted) return;
    if (_settings.bubbleEnabled != running) {
      setState(() => _settings.bubbleEnabled = running);
      await _saveSettings();
    }
  }

  /// One-time hint to allow autostart so the bubble survives a swipe-away.
  Future<void> _maybeShowAutostartHint() async {
    if (_settings.bubbleAutoStartHintShown) return;
    if (!mounted) return;
    setState(() => _settings.bubbleAutoStartHintShown = true);
    await _saveSettings();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('让悬浮球常驻（建议）'),
        content: const Text(
          '悬浮窗权限已就绪。\n\n'
          '为了让悬浮球在「划掉 App」后仍然显示，请在系统设置里为 EasySave 打开'
          '「自启动 / 后台运行」权限。不同机型路径不同，例如：\n'
          '· 小米：应用设置 → 权限管理 → 自启动\n'
          '· 华为：应用启动管理 → 允许后台活动\n'
          '· OPPO / vivo：自启动管理 / 后台高耗电允许',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              BubbleService.openAppSettings();
            },
            child: const Text('去设置'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleBubble(bool v) async {
    if (v) {
      if (!await BubbleService.hasPermission()) {
        _pendingBubbleEnable = true;
        await BubbleService.requestPermission();
        return;
      }
      final started = await BubbleService.start();
      if (!mounted) return;
      setState(() => _settings.bubbleEnabled = started);
      await _saveSettings();
      if (started) await _maybeShowAutostartHint();
    } else {
      await BubbleService.stop();
      if (!mounted) return;
      setState(() => _settings.bubbleEnabled = false);
      await _saveSettings();
    }
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

  Future<void> _addTileToControlCenter() async {
    final added = await TileService.addTile();
    if (!mounted) return;
    if (added) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已添加到控制中心')),
      );
      return;
    }
    // Android 12 and below (or a cancelled dialog): show manual steps.
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加到控制中心'),
        content: const Text(
          '1. 从屏幕顶部下拉，展开控制中心\n'
          '2. 点击右上角「编辑」（铅笔图标）\n'
          '3. 找到「EasySave 下载」磁贴，拖到上方控制区\n\n'
          '添加后，复制帖子链接再点磁贴即可后台下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

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

  /// Ask which albums the rebuild should scan.
  ///
  /// Used albums are pre-selected; every other album can be added. Scanning
  /// the whole library is offered as an explicit, clearly slower option.
  Future<({Set<String> albums, bool allAlbums})?> _pickRebuildAlbums() async {
    final locator = GalleryLocatorService.instance;
    // Make sure the used-album list is complete before showing it.
    try {
      await AlbumNameRegistry.completeFromHistory(_settings);
      await _saveSettings();
    } catch (e) {
      await DevLog.write(
        'V16DL',
        'WARN: failed to prepare rebuild album names: $e',
        level: DevLogLevel.warn,
      );
    }

    final used = _settings.effectiveAlbumNames;
    if (!mounted) return null;
    var options = await locator.albumOptions();
    var allCount = 0;
    try {
      allCount = await locator.allAlbumCount();
    } catch (e) {
      await DevLog.write(
        'V16DL',
        'WARN: failed to count albums for rebuild picker: $e',
        level: DevLogLevel.warn,
      );
    }
    for (final album in used) {
      if (!options.any((option) => option.name.toLowerCase() == album.toLowerCase())) {
        options = [...options, (name: album, count: 0)];
      }
    }
    if (!mounted) return null;

    final selected = <String>{...used};
    var allAlbums = false;

    final result = await showDialog<({Set<String> albums, bool allAlbums})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          title: const Text('选择要扫描的相册'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final option in options)
                  CheckboxListTile(
                    value: selected.contains(option.name),
                    title: Text(option.name),
                    subtitle: Text('${option.count} 张图片'),
                    onChanged: (checked) => setLocal(() {
                      if (checked == true) {
                        selected.add(option.name);
                      } else {
                        selected.remove(option.name);
                      }
                    }),
                  ),
                CheckboxListTile(
                  value: allAlbums,
                  title: const Text('全部相册'),
                  subtitle: Text('较慢，约 $allCount 张图片'),
                  onChanged: (checked) =>
                      setLocal(() => allAlbums = checked == true),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                (albums: selected, allAlbums: allAlbums),
              ),
              child: const Text('开始重建'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  Future<void> _rebuildHistory() async {
    final selection = await _pickRebuildAlbums();
    if (selection == null || !mounted) return;
    if (!selection.allAlbums && selection.albums.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少选择一个相册')),
      );
      return;
    }

    // Show progress dialog
    final progressText = ValueNotifier<String>('准备中…');
    final cancelled = ValueNotifier<bool>(false);
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('正在重建历史'),
        content: ValueListenableBuilder<String>(
          valueListenable: progressText,
          builder: (_, value, __) => Text(value),
        ),
        actions: [
          TextButton(
            onPressed: () => cancelled.value = true,
            child: const Text('取消'),
          ),
        ],
      ),
    );

    try {
      final result = await HistoryRebuildService.instance.rebuild(
        albums: selection.albums,
        includeAllAlbums: selection.allAlbums,
        onProgress: (current, total, filename) {
          progressText.value = '已扫描 $current / $total\n$filename';
        },
        isCancelled: () => cancelled.value,
      );

      if (!mounted) return;
      Navigator.of(context).pop(); // Close progress dialog

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.cancelled
                ? '已取消：${result.created} 新建，${result.merged} 合并，${result.skipped} 跳过'
                : '已完成：${result.created} 新建，${result.merged} 合并，${result.skipped} 跳过',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // Close progress dialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重建失败：$e')),
      );
    }
  }

  Future<void> _backfillMetadata() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('为旧文件补写来源信息'),
        content: const Text(
          '为历史记录中已保存但没有来源信息的文件写入元数据。\n\n'
          '需要相册访问权限，部分文件可能需要授权写入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开始写入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Show progress dialog
    final progressText = ValueNotifier<String>('准备中…');
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
      Navigator.of(context).pop(); // Close progress dialog

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已完成：${result.success} 写入，${result.authRequired} 需要授权，${result.skipped} 跳过',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // Close progress dialog
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('写入失败：$e')),
      );
    }
  }

  /// Copy the (already redacted) log file out of the app's private directory
  /// so it can be read with `adb shell cat .../files/v16dl.log`.
  Future<void> _exportLog() async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await DevLog.exportToExternal();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          path == null ? '没有可导出的日志' : '日志已导出：$path',
        ),
      ),
    );
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
                  subtitle: Text(
                    _settings.effectiveAlbumNames.join(' / '),
                  ),
                  onTap: () => _editText(
                    title: '相册名称',
                    initial: _settings.albumName,
                    onSave: (v) {
                      // Renaming must not lose the old album: the files are
                      // still there, so the rebuild keeps looking in it.
                      _settings.rememberAlbum(_settings.albumName);
                      _settings.albumName = v;
                      _settings.rememberAlbum(v);
                    },
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
                  title: const Text('在图片中保存来源信息'),
                  subtitle: const Text(
                    '下载的图片中会记录来源链接、作者和标题，方便以后整理和溯源',
                  ),
                  value: _settings.saveProvenanceInImages,
                  onChanged: (v) async {
                    setState(() => _settings.saveProvenanceInImages = v);
                    await _saveSettings();
                  },
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
          const _GroupTitle('快捷入口'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('悬浮球'),
                  subtitle: Text(
                    _settings.bubbleEnabled
                        ? '已开启，可拖动吸附到屏幕边缘'
                        : '复制链接后点气泡即可后台下载',
                  ),
                  value: _settings.bubbleEnabled,
                  onChanged: _toggleBubble,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    '部分手机（如 MIUI）需在系统设置中允许 EasySave 自启动，重启手机后悬浮球才会自动出现；否则打开一次 EasySave 即可恢复。',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                SwitchListTile(
                  title: const Text('闲置时贴边隐藏'),
                  subtitle: Text(
                    _settings.bubbleAutoHide
                        ? '闲置 2.5 秒后贴边半隐藏，透明度降为 60%'
                        : '保持贴边完整显示，80% 透明度',
                  ),
                  value: _settings.bubbleAutoHide,
                  onChanged: (v) async {
                    setState(() => _settings.bubbleAutoHide = v);
                    await _saveSettings();
                    await BubbleService.updateAutoHide(v);
                  },
                ),
                SwitchListTile(
                  title: const Text('后台下载结果提示'),
                  subtitle: const Text('用 Toast 显示准备、开始、结果'),
                  value: _settings.backgroundToast,
                  onChanged: (v) async {
                    setState(() => _settings.backgroundToast = v);
                    await _saveSettings();
                  },
                ),
                ListTile(
                  title: const Text('添加到控制中心'),
                  subtitle: const Text('复制链接后点磁贴即可后台下载'),
                  onTap: _addTileToControlCenter,
                ),
              ],
            ),
          ),
          const _GroupTitle('其他'),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('从相册重建历史'),
                  subtitle: const Text('扫描相册中的图片，读取来源信息'),
                  onTap: _rebuildHistory,
                ),
                ListTile(
                  title: const Text('为旧文件补写来源信息'),
                  subtitle: const Text('为已保存但没有来源信息的文件写入元数据'),
                  onTap: _backfillMetadata,
                ),
                ListTile(title: const Text('清除缓存'), onTap: _clearCache),
                ListTile(
                  title: const Text('导出日志'),
                  subtitle: const Text('调试用：把脱敏后的运行日志复制到可读取目录'),
                  onTap: _exportLog,
                ),
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
