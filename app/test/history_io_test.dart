import 'dart:async';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_deletion.dart';
import 'package:easysave/services/history_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HistoryDb db;
  final manager = DownloadManager.instance;
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    await db.clear();
    await db.upsert(
      HistoryRecord(
        platform: 'tiktok',
        postId: '123',
        postUrl: 'https://example.invalid',
        fileCount: 0,
        createdAt: DateTime.now(),
      ),
    );
  });
  tearDown(() async {
    await historyBackgroundSettled();
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
  });
  test(
    'unresponsive other engine and queue cleanup cannot hold database deletion',
    () async {
      final cancel = Completer<void>(), queue = Completer<void>();
      final records = await db.recent();
      await deleteHistoryRecords(
        db,
        records,
        cancelDownloads: (_) => cancel.future,
        clearQueue: (_) => queue.future,
        maintenanceTimeout: const Duration(milliseconds: 20),
      ).timeout(const Duration(seconds: 1));
      expect(await db.recent(), isEmpty);
      expect(cancel.isCompleted, isFalse);
      await historyBackgroundSettled().timeout(const Duration(seconds: 1));
      expect(queue.isCompleted, isFalse);
    },
  );
  test(
    'failed downloads and hung media refresh do not hold refresh; concurrent refreshes coalesce',
    () async {
      final failed = DownloadBatch(
        batchId: 'failed',
        album: 'EasySave',
        platform: 'tiktok',
        postId: '123',
        postUrl: 'https://example.invalid',
        jobs: [
          DownloadJob(
            key: 'j',
            label: '图片',
            filename: 'a.jpg',
            urls: [],
            isImage: true,
            itemIndex: 1,
          )..state = JobState.failed,
        ],
      );
      manager.setBatchForTesting(failed);
      final controller = HistoryRefreshController(
        mediaTimeout: const Duration(milliseconds: 20),
      );
      final media = Completer<void>();
      var loads = 0, count = 0;
      Future<void> load() async {
        loads++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        count = (await db.recent()).length;
      }

      await Future.wait([
        for (var i = 0; i < 10; i++)
          controller.refresh(load, () => media.future),
      ]).timeout(const Duration(seconds: 1));
      expect(loads, 1);
      expect(count, 1);
      expect(media.isCompleted, isFalse);
      expect((await manager.liveBatches()).single.failedCount, 1);
    },
  );
  test(
    'failed record refresh releases its in-flight guard for retry',
    () async {
      final controller = HistoryRefreshController();
      await expectLater(
        controller.refresh(() async => throw StateError('db'), () async {}),
        throwsStateError,
      );
      var loaded = false;
      await controller.refresh(() async {
        loaded = true;
      }, () async {});
      expect(loaded, isTrue);
    },
  );
  test(
    'disposing a page cancels deadlines without waiting for native I/O',
    () async {
      final controller = HistoryRefreshController();
      final native = Completer<void>();
      final work = controller.refresh(() => native.future, () async {});
      controller.dispose();
      await work.timeout(const Duration(seconds: 1));
      expect(native.isCompleted, isFalse);
    },
  );
}
