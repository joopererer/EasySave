// Copyright 2026 EasySave. All rights reserved.
// Failure snapshots for a download batch (v1.11 batch 1).
//
// When a batch ends with at least one failed file, the log around it — 200
// lines from before the batch started plus everything up to the terminal
// handling — is written to its own file in the app's private directory. The
// last 10 snapshots are kept; older ones are removed. Nothing here changes how
// a download runs: the snapshot is taken after the batch reached its terminal
// state and never blocks it.
//
// Every line already went through DevLog's scrubber (cookies, tokens and URL
// queries are removed there); [load] scrubs again so a snapshot can never be
// exported with sensitive data even if it was written by an older build.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/dev_log.dart';

class FailureSnapshot {
  const FailureSnapshot({
    required this.name,
    required this.path,
    required this.createdAt,
    required this.bytes,
  });

  final String name;
  final String path;
  final DateTime createdAt;
  final int bytes;
}

abstract final class DownloadFailureSnapshots {
  /// Lines taken from before the batch started.
  static const int preLines = 200;

  /// Lines taken after the batch ended.
  static const int postLines = 50;

  /// Snapshots kept on disk; the oldest is removed beyond this.
  static const int maxFiles = 10;

  static const String _dirName = 'failure_snapshots';

  /// Directory override for tests.
  @visibleForTesting
  static Directory? directoryForTesting;

  /// External directory override for tests.
  @visibleForTesting
  static Directory? externalDirectoryForTesting;

  static Future<Directory> _directory() async {
    final override = directoryForTesting;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      return override;
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Writes a snapshot for a failed batch and rotates old ones.
  ///
  /// [startLine] is [DevLog.totalLines] when the batch started; [endLine]
  /// defaults to the current line count, i.e. the terminal handling that just
  /// ran. A batch of which the start is unknown falls back to the last
  /// [preLines] lines.
  static Future<FailureSnapshot?> capture({
    required String batchId,
    required String platform,
    required String postId,
    required int failed,
    required int total,
    int? startLine,
    int? endLine,
  }) async {
    try {
      final end = endLine ?? DevLog.totalLines;
      final from = startLine != null ? startLine - preLines : end - preLines;
      final lines = DevLog.linesInRange(from, end + postLines);
      final buffer = StringBuffer()
        ..writeln('# EasySave 下载失败日志快照')
        ..writeln('# batch=$batchId platform=$platform post=$postId')
        ..writeln('# failed=$failed total=$total '
            'lines=${lines.length} range=${from < 0 ? 0 : from}-${end + postLines}')
        ..writeln('# 已脱敏：不含 cookie、账号、完整 URL 或 query')
        ..writeln('# ----');
      for (final line in lines) {
        buffer.writeln(DevLog.scrub(line));
      }
      // The post-end window is best effort: nothing waits for later lines.
      if (lines.length < postLines && startLine == null) {
        buffer.writeln('# （批次起点未知，仅保留最近 $preLines 行）');
      }

      final dir = await _directory();
      final stamp = DateTime.now();
      final name = 'fail_${_stamp(stamp)}_${_safe(batchId)}.log';
      final file = File('${dir.path}/$name');
      await file.writeAsString(buffer.toString(), flush: true);
      await _rotate(dir);
      return FailureSnapshot(
        name: name,
        path: file.path,
        createdAt: stamp,
        bytes: await file.length(),
      );
    } catch (_) {
      // A snapshot must never break a download or crash the app.
      return null;
    }
  }

  /// Snapshots on disk, newest first.
  static Future<List<FailureSnapshot>> list() async {
    try {
      final dir = await _directory();
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.log'))
          .cast<File>()
          .toList();
      final out = <FailureSnapshot>[];
      for (final file in files) {
        try {
          final stat = await file.stat();
          out.add(FailureSnapshot(
            name: file.uri.pathSegments.last,
            path: file.path,
            createdAt: stat.modified,
            bytes: stat.size,
          ));
        } catch (_) {
          // Skip a file that disappeared meanwhile.
        }
      }
      out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return out;
    } catch (_) {
      return const <FailureSnapshot>[];
    }
  }

  /// Redacted content of one snapshot (empty when it cannot be read).
  static Future<String> load(String path) async {
    try {
      final text = await File(path).readAsString();
      return '${DevLog.scrub(text)}\n';
    } catch (_) {
      return '';
    }
  }

  /// Copies one snapshot, redacted, to the app's external files directory —
  /// the same destination the normal log export uses.
  static Future<String?> exportToExternal(String path) async {
    try {
      final source = File(path);
      if (!await source.exists()) return null;
      final external =
          externalDirectoryForTesting ?? await getExternalStorageDirectory();
      if (external == null) return null;
      if (!await external.exists()) await external.create(recursive: true);
      final target = File('${external.path}/${source.uri.pathSegments.last}');
      await target.writeAsString(await load(path), flush: true);
      return target.path;
    } catch (_) {
      return null;
    }
  }

  /// Removes every snapshot.
  static Future<void> clear() async {
    try {
      final dir = await _directory();
      await for (final entry in dir.list()) {
        if (entry is File) await entry.delete();
      }
    } catch (_) {
      // Best effort.
    }
  }

  static Future<void> _rotate(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.log'))
          .cast<File>()
          .toList();
      if (files.length <= maxFiles) return;
      final stats = <MapEntry<File, DateTime>>[];
      for (final file in files) {
        try {
          stats.add(MapEntry(file, (await file.stat()).modified));
        } catch (_) {}
      }
      stats.sort((a, b) => a.value.compareTo(b.value));
      final excess = stats.length - maxFiles;
      for (var i = 0; i < excess; i++) {
        try {
          await stats[i].key.delete();
        } catch (_) {}
      }
    } catch (_) {
      // Rotation is best effort; the cap is retried on the next snapshot.
    }
  }

  static String _stamp(DateTime time) =>
      '${time.year}${_two(time.month)}${_two(time.day)}-'
      '${_two(time.hour)}${_two(time.minute)}${_two(time.second)}-'
      '${time.millisecond.toString().padLeft(3, '0')}';

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _safe(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
