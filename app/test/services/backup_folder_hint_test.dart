// Copyright 2026 EasySave. All rights reserved.
// Tests for Feedback 8: Gentle backup folder hint on download completion.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:easysave/pages/main_shell.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('hint_test_');
    db = await HistoryDb.instance(dbPath: '${tempDir.path}/test.db');
    await db.clear();
    HistoryDb.setInstanceForTesting(db);
    MainShell.resetSessionHintForTesting();
    DownloadManager.instance.onBatchSuccess.value = null;
  });

  tearDown(() async {
    HistoryDb.setInstanceForTesting(null);
    HistoryDb.resetInstanceForTesting();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  DownloadBatch createCompletedBatch(String id) {
    return DownloadBatch(
      batchId: id,
      album: 'Test',
      postUrl: 'https://test.com',
      platform: 'xhs',
      postId: id,
      jobs: [
        DownloadJob(
          key: 'job_$id',
          label: 'job',
          filename: 'f.jpg',
          urls: ['https://test.com/img.jpg'],
          isImage: true,
          itemIndex: 1,
        )..state = JobState.done,
      ],
    );
  }

  testWidgets('shows gentle hint on first batch success when folder backup is off', (tester) async {
    final settings = await AppSettings.load();
    settings.backupTreeUri = null;
    settings.autoFolderBackupEnabled = false;
    settings.backupFolderHintDismissed = false;
    await settings.save();

    await tester.pumpWidget(
      const MaterialApp(home: MainShell()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('设置备份文件夹，换机或重装时可恢复记录'), findsNothing);

    // Trigger download success
    DownloadManager.instance.onBatchSuccess.value = createCompletedBatch('b1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('设置备份文件夹，换机或重装时可恢复记录'), findsOneWidget);
    expect(find.text('去设置'), findsOneWidget);
    expect(find.text('不再提示'), findsOneWidget);

    // Tap "不再提示"
    await tester.tap(find.text('不再提示'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final reloaded = await AppSettings.load();
    expect(reloaded.backupFolderHintDismissed, isTrue);
  });

  testWidgets('throttled to at most once per session', (tester) async {
    final settings = await AppSettings.load();
    settings.backupTreeUri = null;
    settings.autoFolderBackupEnabled = false;
    settings.backupFolderHintDismissed = false;
    await settings.save();

    await tester.pumpWidget(
      const MaterialApp(home: MainShell()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 1. First batch triggers hint
    DownloadManager.instance.onBatchSuccess.value = createCompletedBatch('b1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('设置备份文件夹，换机或重装时可恢复记录'), findsOneWidget);

    // Dismiss snackbar
    tester.binding.scheduleFrame();
    ScaffoldMessenger.of(tester.element(find.byType(MainShell))).hideCurrentSnackBar();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 2. Second batch in same session does NOT trigger hint even if not dismissed permanently
    DownloadManager.instance.onBatchSuccess.value = createCompletedBatch('b2');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('设置备份文件夹，换机或重装时可恢复记录'), findsNothing);
  });

  testWidgets('does not show hint if autoFolderBackupEnabled is true and folder configured', (tester) async {
    final settings = await AppSettings.load();
    settings.backupTreeUri = 'content://tree/target';
    settings.autoFolderBackupEnabled = true;
    settings.backupFolderHintDismissed = false;
    await settings.save();

    await tester.pumpWidget(
      const MaterialApp(home: MainShell()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    DownloadManager.instance.onBatchSuccess.value = createCompletedBatch('b1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('设置备份文件夹，换机或重装时可恢复记录'), findsNothing);
  });
}
