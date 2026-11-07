import 'dart:convert';

import 'package:easysave/pages/backup_restore_page.dart';
import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:easysave/widgets/restore_progress_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _backup(int posts) => jsonEncode(BackupData(
  exportedAt: '2026-11-07T10:00:00+01:00',
  settings: BackupSettings(),
  posts: [
    for (var i = 0; i < posts; i++)
      BackupPost(
        platform: 'xiaohongshu',
        sourceId: '6ad2f705000000001203404$i',
        originalUrl: 'https://www.xiaohongshu.com/explore/6ad2f705000000001203404$i',
        savedAt: '2026-11-07T09:00:00+01:00',
        files: [
          BackupFile(itemIndex: 1, mediaType: 'image',
              filename: '6ad2f705000000001203404${i}_1.jpg', savedAt: '2026-11-07T09:00:00+01:00'),
        ],
      ),
  ],
).toMap());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('restore reports progress post by post', () async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    final db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    addTearDown(HistoryDb.resetInstanceForTesting);
    final steps = <(int, int)>[];
    final result = await BackupService.importBackup(_backup(3),
        db: db, settings: AppSettings(), onProgress: (d, t) => steps.add((d, t)));
    expect(steps, [(0, 3), (1, 3), (2, 3), (3, 3)]);
    expect(result.restoredPosts, 3);
  });

  testWidgets('progress dialog shows x / y posts and cannot be dismissed',
      (tester) async {
    final progress = ValueNotifier<(int, int)>((0, 5));
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => TextButton(
        onPressed: () => showDialog<void>(context: context, barrierDismissible: false,
            builder: (_) => RestoreProgressDialog(progress: progress)),
        child: const Text('go'),
      )),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.text('正在恢复 0 / 5 个帖子'), findsOneWidget);
    progress.value = (3, 5);
    await tester.pump();
    expect(find.text('正在恢复 3 / 5 个帖子'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.6);
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.byType(RestoreProgressDialog), findsOneWidget, reason: 'barrier does not close it');
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pump();
    expect(find.byType(RestoreProgressDialog), findsOneWidget, reason: 'back does not close it');
  });

  test('summary lists posts, files and files not on this device', () {
    final text = restoreSummaryText(ImportResult(
      restoredPosts: 4, restoredFiles: 9, restoredSettings: false,
      insertedPosts: 3, mergedPosts: 1, notOnDevice: 2,
    ));
    expect(text, contains('恢复帖子：4 个'));
    expect(text, contains('恢复文件：9 个'));
    expect(text, contains('不在本机：2 个'));
  });

  testWidgets('the restore button is disabled for the whole flow and the '
      'summary follows the restore', (tester) async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    GalleryLocatorService.instance.resetForTesting();
    DownloadManager.instance.clearBatchesForTesting();
    await tester.runAsync(() async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      HistoryDb.setInstanceForTesting(db);
      await db.clear();
    });
    const saf = MethodChannel('easysave/saf');
    var picks = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(saf, (call) async {
      switch (call.method) {
        case 'pickBackupFile':
          picks++;
          return 'content://test/backup.json';
        case 'readDocumentContent':
          return _backup(3);
        case 'checkDirectoryAccess':
          return false;
      }
      return null;
    });
    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(saf, null);
      GalleryLocatorService.instance.resetForTesting();
      HistoryDb.resetInstanceForTesting();
    });
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.pumpWidget(const MaterialApp(home: BackupRestorePage()));
    await settle();
    final button = find.byWidgetPredicate((w) => w is FilledButton &&
        (w.child is Text) && ((w.child as Text).data == '从文件恢复' || (w.child as Text).data == '恢复中…'));
    await tester.tap(button);
    await settle();

    // The preview sheet is open: the flow is running, a second tap is blocked.
    expect(find.text('确认恢复'), findsOneWidget);
    expect(find.text('恢复中…'), findsOneWidget);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(picks, 1);

    await tester.tap(find.text('确认恢复'));
    var sawProgress = false;
    for (var i = 0; i < 100 && find.text('恢复结果').evaluate().isEmpty; i++) {
      if (find.byType(RestoreProgressDialog).evaluate().isNotEmpty) sawProgress = true;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(sawProgress, isTrue, reason: 'progress is visible while restoring');
    expect(find.text('恢复结果'), findsOneWidget);
    expect(find.textContaining('恢复帖子：3 个'), findsOneWidget);
    expect(find.textContaining('不在本机：'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 400)); // dialog exit animation
    expect(find.byType(RestoreProgressDialog), findsNothing, reason: 'closed when done');

    await tester.tap(find.text('完成'));
    await settle();
    if (find.text('暂不').evaluate().isNotEmpty) {
      await tester.tap(find.text('暂不'));
      await settle();
    }
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    expect(find.text('从文件恢复'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
