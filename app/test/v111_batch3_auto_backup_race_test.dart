// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 3: two automatic backups may finish in the same instant.
//
// The download manager starts one unawaited auto backup per finished batch, so
// two batches can end together. Both used to write the same
// `<dir>/backup/easysave-backup.json.tmp` and then rename it; on Windows the
// second rename found the file still open and the test (and the app) saw
// `Cannot rename …backup.json.tmp`, while on Android the same race silently
// dropped one of the two writes.
//
// This is a test of the writer, not of a test file's temp directory: the batches
// really do overlap.

import 'dart:io';

import 'package:easysave/services/backup/local_auto_backup.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    LocalAutoBackup.resetThrottleForTest();
    tempDir = await Directory.systemTemp.createTemp('easysave_concurrent_');
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Best effort: a stray handle must not fail the test.
    }
  });

  test('two overlapping auto backups both succeed and leave one valid file',
      () async {
    final db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: 'p1',
        postUrl: 'https://example.test/p1',
        title: 'Post',
        fileCount: 1,
        createdAt: DateTime(2026, 1, 1),
        files: [
          HistoryFile(
            filename: 'f_1.jpg',
            savedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
            itemIndex: 1,
            mediaId: 'media-1',
            status: FileStatus.found,
            relativePath: 'Pictures/EasySave/',
          ),
        ],
      ),
    );

    final settings = await AppSettings.load();
    final first = LocalAutoBackup.performAutoBackup(
      db: db,
      settings: settings,
      force: true,
      customSupportDirPath: tempDir.path,
    );
    final second = LocalAutoBackup.performAutoBackup(
      db: db,
      settings: settings,
      force: true,
      customSupportDirPath: tempDir.path,
    );

    // Neither may throw, and both report a written backup.
    expect(await Future.wait([first, second]), [isTrue, isTrue]);
    final file = await LocalAutoBackup.getBackupFile(
      customSupportDirPath: tempDir.path,
    );
    expect(await file.exists(), isTrue);
    final content = await file.readAsString();
    expect(content, contains('"posts"'));
    // No temp file is left behind.
    final leftovers = file.parent
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('a second backup started while the first writes still produces one file',
      () async {
    final db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: 'p2',
        postUrl: 'https://example.test/p2',
        title: 'Post 2',
        fileCount: 1,
        createdAt: DateTime(2026, 1, 2),
        files: [
          HistoryFile(
            filename: 'f_2.jpg',
            savedAt: DateTime(2026, 1, 2).millisecondsSinceEpoch,
            itemIndex: 1,
            mediaId: 'media-2',
            status: FileStatus.found,
            relativePath: 'Pictures/EasySave/',
          ),
        ],
      ),
    );

    final settings = await AppSettings.load();
    final writes = [
      for (var i = 0; i < 4; i++)
        LocalAutoBackup.performAutoBackup(
          db: db,
          settings: settings,
          force: true,
          customSupportDirPath: tempDir.path,
        ),
    ];
    final results = await Future.wait(writes);
    expect(results.every((written) => written), isTrue);

    final file = await LocalAutoBackup.getBackupFile(
      customSupportDirPath: tempDir.path,
    );
    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), contains('"posts"'));
  });
}
