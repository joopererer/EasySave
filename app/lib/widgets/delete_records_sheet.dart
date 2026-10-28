// Delete confirmation bottom sheet (ui-spec §2.4.11).
//
// Records are always removed; album files are optional and, when chosen, go
// through the OS confirmation flow and cannot be undone. The sheet only
// reports intent — the page performs the actual deletion.

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class DeleteSheetResult {
  const DeleteSheetResult({required this.deleteFiles});
  final bool deleteFiles;
}

/// [recordCount] records are about to be deleted; [fileCount] of their files
/// were located (status == found) and can optionally be removed from the album.
Future<DeleteSheetResult?> showDeleteRecordsSheet(
  BuildContext context, {
  required int recordCount,
  required int fileCount,
  bool cancelDownloads = false,
}) {
  return showModalBottomSheet<DeleteSheetResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).cardColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => _DeleteSheet(
      recordCount: recordCount,
      fileCount: fileCount,
      cancelDownloads: cancelDownloads,
    ),
  );
}

class _DeleteSheet extends StatefulWidget {
  const _DeleteSheet({required this.recordCount, required this.fileCount, required this.cancelDownloads});
  final bool cancelDownloads;

  final int recordCount;
  final int fileCount;

  @override
  State<_DeleteSheet> createState() => _DeleteSheetState();
}

class _DeleteSheetState extends State<_DeleteSheet> {
  bool _deleteFiles = false;

  @override
  Widget build(BuildContext context) {
    final canDeleteFiles = widget.fileCount > 0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '删除 ${widget.recordCount} 条记录？',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              '记录会从历史中移除，可以撤销。',
              style: TextStyle(fontSize: 12, color: AppTokens.textSecondary),
            ),
            const SizedBox(height: 16),
            if (widget.cancelDownloads) const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('同时取消正在进行的下载'),
            ),
            if (canDeleteFiles)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: SecondaryBg.beige(context),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: () =>
                          setState(() => _deleteFiles = !_deleteFiles),
                      child: Row(
                        children: [
                          Checkbox(
                            value: _deleteFiles,
                            onChanged: (v) =>
                                setState(() => _deleteFiles = v ?? false),
                          ),
                          Expanded(
                            child: Text(
                              '同时删除相册中的 ${widget.fileCount} 个文件',
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Text(
                        '相册中的文件删除后无法撤销，系统会再弹一次确认',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTokens.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: SecondaryBg.beige(context),
                      foregroundColor: AppTokens.textPrimary,
                      side: BorderSide.none,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTokens.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: () => Navigator.of(context).pop(
                      DeleteSheetResult(deleteFiles: _deleteFiles),
                    ),
                    child: const Text('删除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
