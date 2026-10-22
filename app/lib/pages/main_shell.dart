import '../services/backup/backup_model.dart';
import '../services/backup/backup_service.dart';
import '../services/backup/startup_backup_coordinator.dart';
import '../services/bubble_service.dart';
import '../services/download_manager.dart';
import '../services/history_rebuild_service.dart';
import '../services/host_bridge.dart';
import '../services/settings.dart';
import 'backup_restore_page.dart';
import 'history_page.dart';
import 'mine_page.dart';
import 'parse_page.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _historySelectionMode = false;
  final _historyKey = GlobalKey<HistoryPageState>();
  final _parseKey = GlobalKey<ParsePageState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HostBridge.parseError.addListener(_consumeHostError);
    HostBridge.openRequest.addListener(_consumeHostOpen);
    // A cold-start error may already be present before the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumeHostError();
      _consumeHostOpen();
      _checkStartupRestoreGuide();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HostBridge.parseError.removeListener(_consumeHostError);
    HostBridge.openRequest.removeListener(_consumeHostOpen);
    super.dispose();
  }

  /// Show a background error on the parse tab, using the same error page as a
  /// manual parse. Consumed once.
  void _consumeHostError() {
    final err = HostBridge.parseError.value;
    if (err == null) return;
    HostBridge.parseError.value = null;
    _select(0);
    _parseKey.currentState?.showExternalError(err.url, err.code, err.message);
  }

  /// Open a url (e.g. the bubble's "打开 EasySave") on the parse tab.
  void _consumeHostOpen() {
    final url = HostBridge.openRequest.value;
    if (url == null || url.isEmpty) return;
    HostBridge.openRequest.value = null;
    _select(0);
    _parseKey.currentState?.showExternalUrl(url);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pick up downloads that completed while the app was suspended.
    if (state == AppLifecycleState.resumed) {
      DownloadManager.instance.reconcile();
    }
  }

  void _select(int i) {
    setState(() => _index = i);
    if (i == 1) _historyKey.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          ParsePage(
            key: _parseKey,
            onSeeAll: () => _select(1),
            isVisible: () => _index == 0,
            onShowSelf: () => _select(0),
          ),
          HistoryPage(
            key: _historyKey,
            onGoParse: () => _select(0),
            onSelectionModeChanged: (active) {
              if (mounted) setState(() => _historySelectionMode = active);
            },
          ),
          const MinePage(),
        ],
      ),
      // Hide the nav bar while history multi-select is active; the history page
      // supplies its own share/delete action bar in that state.
      bottomNavigationBar: _historySelectionMode
          ? null
          : BottomNavigationBar(
              currentIndex: _index,
              onTap: _select,
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.search), label: '解析'),
                BottomNavigationBarItem(icon: Icon(Icons.history), label: '历史'),
                BottomNavigationBarItem(icon: Icon(Icons.person), label: '我的'),
              ],
            ),
    );
  }

  String _formatBackupTime(String isoStr) {
    final dt = DateTime.tryParse(isoStr);
    if (dt == null) return isoStr;
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  Future<void> _checkStartupRestoreGuide() async {
    // 1. Mandatory check: Is active history empty?
    final isHistoryEmpty = await BackupService.isHistoryEmpty();
    if (!isHistoryEmpty || !mounted) return;

    final coordinatorResult =
        await StartupBackupCoordinator.evaluateAndRunStartupBackup(
      skipAutoBackupExecution: true,
    );

    if (coordinatorResult.decision == StartupRestoreDecision.promptRestore &&
        coordinatorResult.backupFile != null) {
      final file = coordinatorResult.backupFile!;
      String? jsonStr;
      try {
        jsonStr = await file.readAsString();
      } catch (_) {}

      if (jsonStr != null && mounted) {
        BackupPreview? preview;
        try {
          preview = BackupService.previewBackup(jsonStr);
        } catch (_) {}

        final timeStr = preview != null
            ? _formatBackupTime(preview.exportedAt)
            : '未知时间';
        final count = preview?.postCount ?? 0;

        final doRestore = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('发现备份'),
            content: Text('发现备份（$timeStr、$count 条记录），是否恢复？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('暂不'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('恢复'),
              ),
            ],
          ),
        );

        if (doRestore == true && mounted) {
          final settings = await AppSettings.load();
          final importResult = await BackupService.importBackup(
            jsonStr,
            settings: settings,
            restoreSettings: true,
            checkOverlayPermission: (_) => BubbleService.hasPermission(),
          );

          if (!mounted) return;
          _historyKey.currentState?.reload();

          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('恢复结果'),
              content: Text(
                '恢复完成！\n\n'
                '· 新增记录：${importResult.insertedPosts} 条\n'
                '· 合并记录：${importResult.mergedPosts} 条\n'
                '· 跳过记录：${importResult.skippedPosts} 条\n'
                '· 恢复媒体文件：${importResult.restoredFiles} 个',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('确定'),
                ),
              ],
            ),
          );

          if (!mounted) return;
          final askScan = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('重建扫描'),
              content: const Text('是否立即扫描相册重建媒体关联与文件状态？'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('暂不'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('立即扫描'),
                ),
              ],
            ),
          );

          if (askScan == true && mounted) {
            await _triggerRebuildScan();
          }
        }
      }
      return;
    }

    if (coordinatorResult.decision ==
        StartupRestoreDecision.emptyHistoryNoBackup) {
      final settings = await AppSettings.load();
      if (settings.skipRestoreHint) return;

      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('欢迎使用 EasySave'),
          content: const Text('当前暂无下载记录，你可以选择恢复之前的数据或直接开始使用：'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop('skip'),
              child: const Text('跳过'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop('rebuild'),
              child: const Text('扫描相册重建'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop('restore'),
              child: const Text('从文件恢复'),
            ),
          ],
        ),
      );

      if (choice == 'skip') {
        settings.skipRestoreHint = true;
        await settings.save();
      } else if (choice == 'rebuild') {
        if (mounted) await _triggerRebuildScan();
      } else if (choice == 'restore') {
        if (mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const BackupRestorePage()),
          );
          _historyKey.currentState?.reload();
        }
      }
    }
  }

  Future<void> _triggerRebuildScan() async {
    final settings = await AppSettings.load();
    final usedAlbums = settings.effectiveAlbumNames.toSet();

    if (!mounted) return;
    final progressText = ValueNotifier<String>('准备中…');
    final cancelled = ValueNotifier<bool>(false);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在扫描相册'),
        content: ValueListenableBuilder<String>(
          valueListenable: progressText,
          builder: (_, val, __) => Text(val),
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
        albums: usedAlbums,
        includeAllAlbums: false,
        onProgress: (current, total, filename) {
          progressText.value = '已扫描 $current / $total\n$filename';
        },
        isCancelled: () => cancelled.value,
      );

      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss progress dialog
      _historyKey.currentState?.reload();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.cancelled
                ? '已取消扫描：${result.created} 新增，${result.merged} 合并，${result.skipped} 跳过'
                : '扫描完成：${result.created} 新增，${result.merged} 合并，${result.skipped} 跳过',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('相册扫描失败：$e')),
      );
    }
  }
}
