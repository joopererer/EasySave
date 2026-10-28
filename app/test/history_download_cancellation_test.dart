import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_deletion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  late HistoryDb db;
  DownloadBatch batch() => DownloadBatch(
    batchId: 'b-${DateTime.now().microsecondsSinceEpoch}',
    album: 'EasySave',
    platform: 'tiktok',
    postId: '123',
    postUrl: 'https://example.invalid/post',
    jobs: [
      DownloadJob(
        key: 'job',
        label: '图片',
        filename: 'a.jpg',
        urls: ['https://example.invalid/a'],
        isImage: true,
        itemIndex: 1,
      )..state = JobState.active,
    ],
  );
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
  });
  tearDown(() {
    manager.clearBatchesForTesting();
    HistoryDb.resetInstanceForTesting();
  });
  test(
    'deleting an active download cancels it and late stale-engine writes cannot restore history',
    () async {
      final running = batch();
      final stale = DownloadBatch.fromJson(running.toJson());
      manager.setBatchForTesting(running);
      await writePlaceholderHistory(db, running);
      final record = (await db.recent()).single;
      await deleteHistoryRecords(db, [record]);
      expect(running.cancelledByDeletion, isTrue);
      expect(running.jobs.single.state, JobState.canceled);
      stale.jobs.single
        ..state = JobState.done
        ..saved = true;
      await writePlaceholderHistory(db, stale);
      await writeBatchHistory(db, stale, recovered: false);
      expect(await db.recent(), isEmpty);
    },
  );
  test(
    'database barrier also rejects a start paused before its first placeholder',
    () async {
      final pending = batch();
      await db.upsert(
        HistoryRecord(
          platform: pending.platform,
          postId: pending.postId,
          postUrl: pending.postUrl,
          fileCount: 0,
          createdAt: DateTime.now(),
        ),
      );
      await db.delete((await db.recent()).single.id!);
      await writePlaceholderHistory(db, pending);
      expect(await db.recent(), isEmpty);
      final fresh = batch();
      await writePlaceholderHistory(db, fresh);
      expect(await db.recent(), hasLength(1));
    },
  );
}
