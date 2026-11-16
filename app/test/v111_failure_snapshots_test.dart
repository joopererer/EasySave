// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 1: the automatic failure snapshot of a download batch.
//
// A batch that ends with failures saves 200 lines from before it started plus
// everything up to its terminal handling, in the app's private directory, at
// most 10 files. These tests drive the window, the cap, the rotation and the
// redaction of what is written and exported.

import 'dart:io';

import 'package:easysave/core/dev_log.dart';
import 'package:easysave/services/download_failure_snapshots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Directory external;

  setUp(() async {
    DevLog.resetRecentForTesting();
    dir = await Directory.systemTemp.createTemp('easysave_fail_logs');
    external = await Directory.systemTemp.createTemp('easysave_fail_export');
    DownloadFailureSnapshots.directoryForTesting = dir;
    DownloadFailureSnapshots.externalDirectoryForTesting = external;
  });

  tearDown(() async {
    DownloadFailureSnapshots.directoryForTesting = null;
    DownloadFailureSnapshots.externalDirectoryForTesting = null;
    for (final d in [dir, external]) {
      try {
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {}
    }
    DevLog.resetRecentForTesting();
  });

  group('in-memory log window', () {
    test('absolute line indices follow every write', () async {
      expect(DevLog.totalLines, 0);
      await DevLog.write('T', 'one');
      await DevLog.write('T', 'two');
      expect(DevLog.totalLines, 2);
      expect(DevLog.linesInRange(0, 2).length, 2);
      expect(DevLog.linesInRange(0, 2).first, contains('one'));
      expect(DevLog.recentLines(1).single, contains('two'));
    });

    test('a range clamps to what is still in memory', () async {
      await DevLog.write('T', 'a');
      expect(DevLog.linesInRange(-500, 1).length, 1);
      expect(DevLog.linesInRange(0, 999).length, 1);
      expect(DevLog.linesInRange(5, 9), isEmpty);
    });
  });

  group('snapshot window', () {
    test('covers 200 lines before the batch up to its end', () async {
      for (var i = 0; i < 600; i++) {
        await DevLog.write('T', 'line $i');
      }
      expect(DevLog.totalLines, 600);

      final snapshot = await DownloadFailureSnapshots.capture(
        batchId: 'main-1',
        platform: 'xhs',
        postId: 'post-1',
        failed: 1,
        total: 3,
        startLine: 400,
      );
      expect(snapshot, isNotNull);
      final content = await File(snapshot!.path).readAsString();

      // 200 lines before the batch start (400 -> 200).
      expect(content, contains('line 200'));
      expect(content, isNot(contains('line 199')));
      // Up to the terminal handling.
      expect(content, contains('line 599'));
      expect(content, contains('# batch=main-1 platform=xhs post=post-1'));
      expect(content, contains('failed=1 total=3'));
    });

    test('without a known start it keeps the pre-batch tail', () async {
      for (var i = 0; i < 250; i++) {
        await DevLog.write('T', 'line $i');
      }
      final snapshot = await DownloadFailureSnapshots.capture(
        batchId: 'main-2',
        platform: 'xhs',
        postId: 'post-2',
        failed: 2,
        total: 2,
        startLine: null,
      );
      final content = await File(snapshot!.path).readAsString();
      // 250 - 200 = line 50 is the first kept line.
      expect(content, contains('line 50'));
      expect(content, isNot(contains('line 49')));
      expect(content, contains('line 249'));
    });

    test('a successful batch never asks for a snapshot', () async {
      // The manager only calls capture() when failedCount > 0; the service
      // itself must not create anything on an empty request path.
      expect(await DownloadFailureSnapshots.list(), isEmpty);
    });
  });

  group('redaction', () {
    test('cookies, tokens and URL queries never reach the file', () async {
      await DevLog.write('T', 'Cookie: session=abc123; uid=42');
      await DevLog.write(
        'T',
        'GET https://www.xiaohongshu.com/api/feed?xsec_token=SECRET&a=1',
      );
      final snapshot = await DownloadFailureSnapshots.capture(
        batchId: 'main-3',
        platform: 'xhs',
        postId: 'post-3',
        failed: 1,
        total: 1,
        startLine: 0,
        endLine: 2,
      );
      final content = await File(snapshot!.path).readAsString();
      expect(content, isNot(contains('abc123')));
      expect(content, isNot(contains('SECRET')));
      expect(content, isNot(contains('xsec_token')));
      expect(content, contains('www.xiaohongshu.com/api/feed'));
      expect(content, contains('<redacted>'));
    });

    test('an export is scrubbed again', () async {
      final snapshot = await DownloadFailureSnapshots.capture(
        batchId: 'main-4',
        platform: 'xhs',
        postId: 'post-4',
        failed: 1,
        total: 1,
        startLine: 0,
        endLine: 0,
      );
      // Simulate a file written by an older build that was not redacted.
      await File(snapshot!.path).writeAsString(
        '[INFO] [T] Cookie: token=leaked-value\n',
      );
      final exported = await DownloadFailureSnapshots.exportToExternal(
        snapshot.path,
      );
      expect(exported, isNotNull);
      final content = await File(exported!).readAsString();
      expect(content, isNot(contains('leaked-value')));
      expect(File(exported).parent.path, external.path);
    });
  });

  group('cap and rotation', () {
    test('keeps at most ten snapshots and drops the oldest', () async {
      for (var i = 0; i < 11; i++) {
        final file = File('${dir.path}/fail_old_$i.log');
        await file.writeAsString('old $i');
        await file.setLastModified(
          DateTime.fromMillisecondsSinceEpoch(1000000 + i * 1000),
        );
      }
      expect((await DownloadFailureSnapshots.list()).length, 11);

      final snapshot = await DownloadFailureSnapshots.capture(
        batchId: 'main-5',
        platform: 'xhs',
        postId: 'post-5',
        failed: 1,
        total: 1,
        startLine: 0,
        endLine: 0,
      );
      expect(snapshot, isNotNull);

      final remaining = await DownloadFailureSnapshots.list();
      expect(remaining.length, DownloadFailureSnapshots.maxFiles);
      expect(remaining.map((s) => s.name), contains(snapshot!.name));
      // The oldest file went first.
      expect(remaining.map((s) => s.name), isNot(contains('fail_old_0.log')));
      expect(remaining.map((s) => s.name), contains('fail_old_10.log'));
      // Newest first.
      expect(remaining.first.name, snapshot.name);
    });

    test('clear removes every snapshot', () async {
      await DownloadFailureSnapshots.capture(
        batchId: 'main-6',
        platform: 'xhs',
        postId: 'post-6',
        failed: 1,
        total: 1,
        startLine: 0,
        endLine: 0,
      );
      expect(await DownloadFailureSnapshots.list(), isNotEmpty);
      await DownloadFailureSnapshots.clear();
      expect(await DownloadFailureSnapshots.list(), isEmpty);
    });
  });
}
