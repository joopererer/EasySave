// Copyright 2026 EasySave. All rights reserved.
// Failure snapshots viewer (v1.11 batch 1): 「我的 → 日志」.
//
// A download batch that ends with failures saves the log around it (200 lines
// before the batch, everything up to its terminal handling) into the app's
// private directory. This page lists those snapshots, shows one on tap and
// exports a redacted copy for a bug report.

import 'package:flutter/material.dart';

import '../core/dev_log.dart';
import '../services/download_failure_snapshots.dart';
import '../theme/app_theme.dart';

class FailureLogPage extends StatefulWidget {
  const FailureLogPage({super.key});

  @override
  State<FailureLogPage> createState() => _FailureLogPageState();
}

class _FailureLogPageState extends State<FailureLogPage> {
  List<FailureSnapshot> _snapshots = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final snapshots = await DownloadFailureSnapshots.list();
    if (!mounted) return;
    setState(() {
      _snapshots = snapshots;
      _loading = false;
    });
  }

  String _label(FailureSnapshot snapshot) {
    final t = snapshot.createdAt;
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }

  Future<void> _open(FailureSnapshot snapshot) async {
    final content = await DownloadFailureSnapshots.load(snapshot.path);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_label(snapshot)),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: Scrollbar(
            child: SingleChildScrollView(
              child: SelectableText(
                content.isEmpty ? '（无法读取该快照）' : content,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _export(FailureSnapshot snapshot) async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await DownloadFailureSnapshots.exportToExternal(snapshot.path);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(path == null ? '导出失败' : '已导出：$path')),
    );
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除失败快照'),
        content: const Text('确定删除全部下载失败日志快照？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await DownloadFailureSnapshots.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载失败日志'),
        actions: [
          if (_snapshots.isNotEmpty)
            IconButton(
              tooltip: '删除全部',
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _snapshots.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  '还没有失败快照。\n某次下载批次出现失败时，会在这里自动保存一份脱敏日志。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTokens.textSecondary, height: 1.6),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _snapshots.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final snapshot = _snapshots[index];
                return ListTile(
                  leading: const Icon(Icons.receipt_long_outlined),
                  title: Text(_label(snapshot)),
                  subtitle: Text(
                    '${snapshot.name} · ${(snapshot.bytes / 1024).toStringAsFixed(1)} KB',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () => _open(snapshot),
                  trailing: TextButton(
                    onPressed: () => _export(snapshot),
                    child: const Text('导出'),
                  ),
                );
              },
            ),
    );
  }
}

/// Opens the snapshot list from 「我的 → 日志」.
Future<void> openFailureLogs(BuildContext context) async {
  DevLog.write('FailureLogs', 'event=open');
  await Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const FailureLogPage()),
  );
}
