// Copyright 2026 EasySave. All rights reserved.
// Unit and widget tests for Step 5: BackupRestorePage, RestorePreviewSheet,
// download lock guard, and startup restore logic.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:easysave/pages/backup_restore_page.dart';
import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/backup/saf_service.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:easysave/widgets/restore_preview_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  group('Step 5: RestorePreviewSheet', () {
    testWidgets('renders preview metadata and toggles settings checkbox', (tester) async {
      final preview = BackupPreview(
        exportedAt: '2026-10-22T10:30:00+08:00',
        appVersion: '1.8.0',
        postCount: 5,
        fileCount: 12,
        formatVersion: 1,
        settings: BackupSettings(
          albumName: 'MyAlbum',
          usedAlbumNames: ['MyAlbum'],
          namePattern: '{id}_{seq}',
          saveProvenanceInImages: true,
          bubbleEnabled: true,
          bubbleAutoHide: true,
          backgroundToast: true,
          autoClipboard: true,
          saveCaptionTxt: false,
          historyView: 'posts',
          historyLayout: 'waterfall',
          historySort: 'latest',
        ),
      );

      RestorePreviewResult? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await RestorePreviewSheet.show(
                    context,
                    preview: preview,
                    defaultRestoreSettings: true,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      // Open sheet
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('确认从备份恢复'), findsOneWidget);
      expect(find.text('5 条'), findsOneWidget);
      expect(find.text('12 个'), findsOneWidget);
      expect(find.text('EasySave v1.8.0'), findsOneWidget);
      expect(find.text('MyAlbum'), findsOneWidget);

      // Checkbox is checked by default
      final checkboxFinder = find.byType(Checkbox);
      expect(checkboxFinder, findsOneWidget);
      expect(tester.widget<Checkbox>(checkboxFinder).value, isTrue);

      // Toggle checkbox to false
      await tester.tap(checkboxFinder);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(checkboxFinder).value, isFalse);

      // Confirm
      await tester.tap(find.text('确认恢复'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.restoreSettings, isFalse);
    });

    testWidgets('clicking 取消 returns null', (tester) async {
      final preview = BackupPreview(
        exportedAt: '2026-10-22T10:30:00+08:00',
        appVersion: '1.8.0',
        postCount: 2,
        fileCount: 3,
        formatVersion: 1,
      );

      RestorePreviewResult? result;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await RestorePreviewSheet.show(
                    context,
                    preview: preview,
                    defaultRestoreSettings: false,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(result, isNull);
    });
  });

  group('Step 5: BackupRestorePage UI & State', () {
    late Directory tempDir;
    late HistoryDb testDb;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('backup_restore_ui_');
      final dbPath = '${tempDir.path}/test_history.db';
      testDb = await HistoryDb.instance(dbPath: dbPath);
      await testDb.clear();
      HistoryDb.setInstanceForTesting(testDb);
      SafService.resetThrottleForTest();
    });

    tearDown(() async {
      HistoryDb.setInstanceForTesting(null);
      HistoryDb.resetInstanceForTesting();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets('renders 未设置 when backupTreeUri is null', (tester) async {
      final settings = await AppSettings.load();
      settings.backupTreeUri = null;
      await settings.save();

      await tester.pumpWidget(
        const MaterialApp(
          home: BackupRestorePage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('备份与恢复'), findsOneWidget);
      expect(find.text('备份文件夹'), findsOneWidget);
      expect(find.text('未设置'), findsOneWidget);
      expect(find.text('选择文件夹'), findsOneWidget);
    });

    testWidgets('shows warning and button when folder permission is lost', (tester) async {
      const safChannel = MethodChannel('easysave/saf');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(safChannel, (call) async {
        if (call.method == 'checkDirectoryAccess') {
          return false; // Permission lost or folder deleted
        }
        return null;
      });

      final settings = await AppSettings.load();
      settings.backupTreeUri = 'content://tree/lost_folder';
      await settings.save();

      await tester.pumpWidget(
        const MaterialApp(
          home: BackupRestorePage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('文件夹权限失效或文件夹已被删除'), findsOneWidget);
      expect(find.text('重新选择文件夹'), findsOneWidget);
    });

    testWidgets('shows prompt confirmation when clicking 立即备份 with empty history', (tester) async {
      final settings = await AppSettings.load();
      settings.backupTreeUri = 'content://tree/valid_folder';
      await settings.save();

      const safChannel = MethodChannel('easysave/saf');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(safChannel, (call) async {
        if (call.method == 'checkDirectoryAccess') {
          return true;
        }
        return null;
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: BackupRestorePage(),
        ),
      );
      await tester.pumpAndSettle();

      final backupBtnFinder = find.byKey(const Key('manual_backup_btn'));
      await tester.tap(backupBtnFinder);
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      // Confirmation dialog should appear
      expect(find.text('当前没有任何记录，备份将是空的，确定要导出吗？'), findsOneWidget);
      expect(find.text('确定导出'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      // Dismiss dialog
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(find.text('当前没有任何记录，备份将是空的，确定要导出吗？'), findsNothing);
    });

    testWidgets('disables 从文件恢复 button with reason when download is active', (tester) async {
      final activeBatch = DownloadBatch(
        batchId: 'active_batch_1',
        album: 'Test',
        postUrl: 'https://test.com',
        platform: 'xhs',
        postId: 'p1',
        jobs: [
          DownloadJob(
            key: 'job1',
            label: 'job1',
            filename: 'test.jpg',
            urls: ['https://test.com/1.jpg'],
            isImage: true,
            itemIndex: 1,
          )..state = JobState.active,
        ],
      );
      DownloadManager.instance.setBatchForTesting(activeBatch);

      try {
        await tester.pumpWidget(
          const MaterialApp(
            home: BackupRestorePage(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('有下载任务正在进行，暂时无法恢复数据'), findsOneWidget);
        final restoreBtnFinder = find.widgetWithText(FilledButton, '从文件恢复');
        expect(restoreBtnFinder, findsOneWidget);
        expect(tester.widget<FilledButton>(restoreBtnFinder).onPressed, isNull);
      } finally {
        DownloadManager.instance.clearBatchesForTesting();
      }
    });

    testWidgets('renders readable folder path in UI, never raw URI', (tester) async {
      final settings = await AppSettings.load();
      settings.backupTreeUri = 'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FEasySave';
      await settings.save();

      const safChannel = MethodChannel('easysave/saf');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(safChannel, (call) async {
        if (call.method == 'checkDirectoryAccess') return true;
        return null;
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: BackupRestorePage(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('内部存储/Documents/EasySave'), findsOneWidget);
      expect(find.textContaining('content://'), findsNothing);
    });

    testWidgets('autoFolderBackupEnabled switch: opening when no folder set triggers picker; cancelling keeps it OFF', (tester) async {
      final settings = await AppSettings.load();
      settings.backupTreeUri = null;
      settings.autoFolderBackupEnabled = false;
      await settings.save();

      var pickCalled = false;
      const safChannel = MethodChannel('easysave/saf');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(safChannel, (call) async {
        if (call.method == 'pickDirectory') {
          pickCalled = true;
          return null; // User cancelled
        }
        if (call.method == 'checkDirectoryAccess') return true;
        return null;
      });

      await tester.pumpWidget(
        const MaterialApp(home: BackupRestorePage()),
      );
      await tester.pumpAndSettle();

      final switchFinder = find.byKey(const Key('auto_folder_backup_switch'));
      expect(switchFinder, findsOneWidget);
      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(pickCalled, isTrue);
      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
      final reloaded = await AppSettings.load();
      expect(reloaded.autoFolderBackupEnabled, isFalse);
    });

    testWidgets('closing switch preserves backupTreeUri; re-opening does not prompt picker', (tester) async {
      final settings = await AppSettings.load();
      settings.backupTreeUri = 'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FEasySave';
      settings.autoFolderBackupEnabled = true;
      await settings.save();

      var pickCalled = false;
      const safChannel = MethodChannel('easysave/saf');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(safChannel, (call) async {
        if (call.method == 'pickDirectory') {
          pickCalled = true;
          return null;
        }
        if (call.method == 'checkDirectoryAccess') return true;
        return null;
      });

      await tester.pumpWidget(
        const MaterialApp(home: BackupRestorePage()),
      );
      await tester.pumpAndSettle();

      final switchFinder = find.byKey(const Key('auto_folder_backup_switch'));
      expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);

      // 1. Turn switch OFF
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
      var reloaded = await AppSettings.load();
      expect(reloaded.autoFolderBackupEnabled, isFalse);
      expect(reloaded.backupTreeUri, isNotNull, reason: 'backupTreeUri must be preserved when switch is closed');

      // 2. Turn switch back ON: must NOT call pickDirectory
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
      expect(pickCalled, isFalse, reason: 'Re-opening switch must not re-prompt folder picker if treeUri is set');
      reloaded = await AppSettings.load();
      expect(reloaded.autoFolderBackupEnabled, isTrue);
      expect(reloaded.backupTreeUri, 'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FEasySave');
    });

    testWidgets('rechecks directory access on AppLifecycleState.resumed', (tester) async {
      final settings = await AppSettings.load();
      settings.backupTreeUri = 'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FEasySave';
      settings.autoFolderBackupEnabled = true;
      await settings.save();

      var hasAccess = true;
      const safChannel = MethodChannel('easysave/saf');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(safChannel, (call) async {
        if (call.method == 'checkDirectoryAccess') return hasAccess;
        return null;
      });

      await tester.pumpWidget(
        const MaterialApp(home: BackupRestorePage()),
      );
      await tester.pumpAndSettle();

      // Initially valid, no warning
      expect(find.text('文件夹权限失效或文件夹已被删除'), findsNothing);

      // Access is revoked externally (e.g. folder deleted)
      hasAccess = false;

      // App resumes
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      // Warning and re-select button appear
      expect(find.text('文件夹权限失效或文件夹已被删除'), findsOneWidget);
      expect(find.text('重新选择文件夹'), findsOneWidget);
    });
  });
}
