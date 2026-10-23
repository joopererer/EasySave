// Copyright 2026 EasySave. All rights reserved.
// Backup and Restore settings management page (v1.8 Step 5).

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/backup/backup_model.dart';
import '../services/backup/backup_service.dart';
import '../services/backup/saf_service.dart';
import '../services/bubble_service.dart';
import '../services/download_manager.dart';
import '../services/history_rebuild_service.dart';
import '../services/settings.dart';
import '../widgets/restore_preview_sheet.dart';

class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({super.key});

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> with WidgetsBindingObserver {
  AppSettings _settings = AppSettings();
  bool _loading = true;
  bool _hasFolderAccess = true;
  bool _backingUp = false;

  String? _folderDisplayName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadState();
    }
  }

  Future<void> _loadState() async {
    final settings = await AppSettings.load();
    bool hasAccess = true;
    String? folderDisplay;
    if (settings.backupTreeUri != null && settings.backupTreeUri!.isNotEmpty) {
      final tree = settings.backupTreeUri!;
      final parsed = parseTreeDocumentPath(tree);
      if (parsed != null && parsed.isNotEmpty) {
        folderDisplay = parsed;
      } else {
        final docName = await SafService.getDirectoryDisplayName(tree);
        folderDisplay = SafService.formatReadableDirectoryPath(tree, fallbackName: docName);
      }
      try {
        hasAccess = await SafService.checkDirectoryAccess(tree);
      } catch (_) {
        hasAccess = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _hasFolderAccess = hasAccess;
      _folderDisplayName = folderDisplay;
      _loading = false;
    });
  }

  String _formatDateTime(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  String _displayPath(String uri) {
    return _folderDisplayName ?? SafService.formatReadableDirectoryPath(uri);
  }

  Future<String?> _pickFolder() async {
    try {
      final uri = await SafService.pickDirectory();
      if (uri != null && mounted) {
        _settings.backupTreeUri = uri;
        await _settings.save();
        await _loadState();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已设置外部备份文件夹')),
          );
        }
        return uri;
      }
      return null;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件夹失败：$e')),
        );
      }
      return null;
    }
  }

  Future<void> _handleManualBackup() async {
    if (_backingUp) return;

    // 1. Check if history is empty
    final isHistoryEmpty = await BackupService.isHistoryEmpty();
    if (isHistoryEmpty && mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('备份提示'),
          content: const Text('当前没有任何记录，备份将是空的，确定要导出吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确定导出'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    // 2. Check if external folder is set
    final treeUri = _settings.backupTreeUri;
    if (treeUri == null || treeUri.isEmpty) {
      if (!mounted) return;
      final shouldPick = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('未设置备份文件夹'),
          content: const Text('立即备份需要先选择保存备份文件的文件夹。是否现在选择？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('选择文件夹'),
            ),
          ],
        ),
      );
      if (shouldPick == true) {
        await _pickFolder();
      }
      return;
    }

    if (!_hasFolderAccess) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('备份文件夹权限已失效，请先重新选择文件夹')),
      );
      return;
    }

    setState(() => _backingUp = true);
    try {
      final result = await SafService.performManualBackupToDirectory(
        treeUri,
        settings: _settings,
      );
      await _loadState();
      if (mounted) {
        if (result.isIdentical) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('与上一份备份相同，未新建文件')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('备份成功，已写入外部文件夹')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('备份失败：$e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _backingUp = false);
      }
    }
  }

  Future<void> _handleRestoreFromFile() async {
    // 1. Guard against concurrent active downloads
    if (DownloadManager.instance.hasActiveDownloads) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('无法恢复数据'),
          content: const Text('有下载任务正在进行，暂时无法恢复数据。请等待下载完成后再试。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
      return;
    }

    // 2. Pick backup file via system picker
    final fileUri = await SafService.pickBackupFile();
    if (fileUri == null || !mounted) return;

    // 3. Read content
    String jsonStr;
    try {
      jsonStr = await SafService.readDocumentContent(fileUri);
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('读取文件失败'),
          content: Text('无法读取所选文件：$e'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }

    // 4. Validate version & preview
    BackupPreview preview;
    try {
      preview = BackupService.previewBackup(jsonStr);
    } on IncompatibleBackupVersionException {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('版本不兼容'),
          content: const Text('备份来自更新的版本，请先升级 App'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('我知道了'),
            ),
          ],
        ),
      );
      return;
    } catch (_) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('文件损坏'),
          content: const Text('文件损坏或不是 EasySave 备份，未导入任何数据。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      return;
    }

    // 5. Show Preview Sheet
    final isHistoryEmpty = await BackupService.isHistoryEmpty();
    if (!mounted) return;
    final previewResult = await RestorePreviewSheet.show(
      context,
      preview: preview,
      defaultRestoreSettings: isHistoryEmpty,
    );
    if (previewResult == null || !mounted) return;

    // 6. Execute Import
    try {
      final result = await BackupService.importBackup(
        jsonStr,
        settings: _settings,
        restoreSettings: previewResult.restoreSettings,
        checkOverlayPermission: (_) => BubbleService.hasPermission(),
      );

      await _loadState();
      if (!mounted) return;

      // 7. Show Result
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('恢复结果'),
          content: Text(
            '恢复完成！\n\n'
            '· 新增记录：${result.insertedPosts} 条\n'
            '· 合并记录：${result.mergedPosts} 条\n'
            '· 跳过记录：${result.skippedPosts} 条\n'
            '· 恢复媒体文件：${result.restoredFiles} 个'
            '${result.overlayNotice ? '\n\n提示：由于系统未授予悬浮窗权限，悬浮球已设为关闭，可在权限管理中授权后开启。' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('完成'),
            ),
          ],
        ),
      );

      // 8. Ask whether to scan and rebuild immediately
      if (!mounted) return;
      final shouldScan = await showDialog<bool>(
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

      if (shouldScan == true && mounted) {
        await _triggerRebuildScan();
      }
    } catch (e) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('恢复失败'),
            content: Text('恢复过程中发生错误：$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _triggerRebuildScan() async {
    final progressText = ValueNotifier<String>('准备中…');
    final cancelled = ValueNotifier<bool>(false);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在扫描相册'),
        content: ValueListenableBuilder<String>(
          valueListenable: progressText,
          builder: (_, val, _) => Text(val),
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
      final usedAlbums = _settings.effectiveAlbumNames.toSet();
      final result = await HistoryRebuildService.instance.rebuild(
        albums: usedAlbums,
        includeAllAlbums: false,
        onProgress: (current, total, filename) {
          progressText.value = '已扫描 $current / $total\n$filename';
        },
        isCancelled: () => cancelled.value,
      );

      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss progress

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('备份与恢复')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final hasTreeUri = _settings.backupTreeUri != null && _settings.backupTreeUri!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('备份与恢复'),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Section 1: 外部自选目录备份
          _buildSectionHeader('外部文件夹自动归档'),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                SwitchListTile(
                  key: const Key('auto_folder_backup_switch'),
                  title: const Text('自动备份到文件夹'),
                  subtitle: Text(
                    _settings.autoFolderBackupEnabled
                        ? '下载完成后及每天打开时自动保存到所选文件夹'
                        : '已关闭（关闭期间仍可手动立即备份）',
                  ),
                  value: _settings.autoFolderBackupEnabled,
                  onChanged: (enabled) async {
                    if (enabled) {
                      if (_settings.backupTreeUri == null || _settings.backupTreeUri!.isEmpty) {
                        final picked = await _pickFolder();
                        if (picked != null && mounted) {
                          setState(() => _settings.autoFolderBackupEnabled = true);
                          await _settings.save();
                        }
                      } else {
                        setState(() => _settings.autoFolderBackupEnabled = true);
                        await _settings.save();
                      }
                    } else {
                      setState(() => _settings.autoFolderBackupEnabled = false);
                      await _settings.save();
                    }
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('备份文件夹'),
                  subtitle: Text(
                    hasTreeUri ? _displayPath(_settings.backupTreeUri!) : '未设置',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: OutlinedButton(
                    onPressed: _pickFolder,
                    child: Text(hasTreeUri ? '更换' : '选择文件夹'),
                  ),
                ),
                if (hasTreeUri && !_hasFolderAccess) ...[
                  const Divider(height: 1),
                  Container(
                    margin: const EdgeInsets.all(12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: theme.colorScheme.error),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '文件夹权限失效或文件夹已被删除',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onErrorContainer,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '自动备份已暂停，请重新授权文件夹。',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onErrorContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                        FilledButton.tonal(
                          onPressed: _pickFolder,
                          child: const Text('重新选择文件夹'),
                        ),
                      ],
                    ),
                  ),
                ] else if (hasTreeUri && _hasFolderAccess && _settings.autoFolderBackupEnabled) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline, color: Colors.green.shade600, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '文件夹权限正常，自动备份已就绪（保留最新 7 份）',
                            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section 2: 备份状态与手动备份
          _buildSectionHeader('备份操作'),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.access_time),
                  title: const Text('上次备份时间'),
                  subtitle: Text(
                    _settings.lastBackupTime != null
                        ? _formatDateTime(_settings.lastBackupTime!)
                        : '从未备份',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.cloud_upload_outlined),
                  title: const Text('立即备份'),
                  subtitle: const Text('将当前所有有效历史与个性化设置写入备份'),
                  trailing: _backingUp
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          key: const Key('manual_backup_btn'),
                          onPressed: _handleManualBackup,
                          child: const Text('立即备份'),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section 3: 数据恢复
          _buildSectionHeader('数据恢复'),
          ListenableBuilder(
            listenable: DownloadManager.instance,
            builder: (context, _) {
              final isDownloading = DownloadManager.instance.hasActiveDownloads;

              return Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('从文件恢复'),
                  subtitle: Text(
                    isDownloading
                        ? '有下载任务正在进行，暂时无法恢复数据'
                        : '选择 JSON 备份文件恢复历史记录与个性化设置',
                    style: TextStyle(
                      color: isDownloading ? theme.colorScheme.error : null,
                    ),
                  ),
                  trailing: FilledButton(
                    onPressed: isDownloading ? null : _handleRestoreFromFile,
                    child: const Text('从文件恢复'),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 16),

          // Section 4: 说明
          _buildSectionHeader('备份机制说明'),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '· 第 2 层系统备份：Android Auto Backup 自动将私有备份同步至云端与换机迁移。',
                    style: TextStyle(fontSize: 13, height: 1.5),
                  ),
                  SizedBox(height: 6),
                  Text(
                    '· 第 3 层外部归档：自选外部文件夹自动保存快照，严格保留最新 7 份。',
                    style: TextStyle(fontSize: 13, height: 1.5),
                  ),
                  SizedBox(height: 6),
                  Text(
                    '· 空历史安全保护：本地记录为空时自动备份不执行，杜绝误覆盖或清空已有备份。',
                    style: TextStyle(fontSize: 13, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
