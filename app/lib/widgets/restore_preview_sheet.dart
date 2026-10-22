// Copyright 2026 EasySave. All rights reserved.
// Restore preview bottom sheet dialog for verifying backup metadata before importing.

import 'package:flutter/material.dart';

import '../services/backup/backup_model.dart';
import '../theme/app_theme.dart';

class RestorePreviewResult {
  final bool restoreSettings;
  const RestorePreviewResult({required this.restoreSettings});
}

class RestorePreviewSheet extends StatefulWidget {
  final BackupPreview preview;
  final bool defaultRestoreSettings;

  const RestorePreviewSheet({
    super.key,
    required this.preview,
    required this.defaultRestoreSettings,
  });

  static Future<RestorePreviewResult?> show(
    BuildContext context, {
    required BackupPreview preview,
    required bool defaultRestoreSettings,
  }) {
    return showModalBottomSheet<RestorePreviewResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => RestorePreviewSheet(
        preview: preview,
        defaultRestoreSettings: defaultRestoreSettings,
      ),
    );
  }

  @override
  State<RestorePreviewSheet> createState() => _RestorePreviewSheetState();
}

class _RestorePreviewSheetState extends State<RestorePreviewSheet> {
  late bool _restoreSettings;

  @override
  void initState() {
    super.initState();
    _restoreSettings = widget.defaultRestoreSettings;
  }

  String _formatDateTime(String isoStr) {
    final dt = DateTime.tryParse(isoStr);
    if (dt == null) return isoStr;
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = widget.preview;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.restore, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                '确认从备份恢复',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Metadata Cards
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildMetaRow('备份时间', _formatDateTime(preview.exportedAt)),
                  const Divider(height: 16),
                  _buildMetaRow('应用版本', 'EasySave v${preview.appVersion}'),
                  const Divider(height: 16),
                  _buildMetaRow('帖子数量', '${preview.postCount} 条'),
                  const Divider(height: 16),
                  _buildMetaRow('媒体文件', '${preview.fileCount} 个'),
                  if (preview.settings != null) ...[
                    const Divider(height: 16),
                    _buildMetaRow(
                      '保存相册',
                      preview.settings!.albumName.isNotEmpty
                          ? preview.settings!.albumName
                          : 'EasySave',
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Settings Restore Checkbox
          CheckboxListTile(
            value: _restoreSettings,
            onChanged: (val) {
              setState(() => _restoreSettings = val ?? false);
            },
            title: const Text('同时恢复设置'),
            subtitle: const Text('包含相册名称、命名模板、悬浮球首选项等（历史为空时建议勾选）'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 20),

          // Action Buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).pop(
                      RestorePreviewResult(restoreSettings: _restoreSettings),
                    );
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('确认恢复'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetaRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 14,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}
