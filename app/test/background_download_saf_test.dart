import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/backup/local_auto_backup.dart';
import 'package:easysave/services/backup/saf_service.dart';
import 'package:easysave/services/download_claims.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:file/memory.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common/src/factory.dart' show SqfliteDatabaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MemoryDatabaseFactory implements SqfliteDatabaseFactory {
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) =>
      databaseFactoryFfi.openDatabase(inMemoryDatabasePath, options: options);
  @override
  Future<String> getDatabasesPath() async => '/isolated-background-saf';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected DB operation ${invocation.memberName}');
}

class _FakePaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => '/support';
  @override
  Future<String?> getTemporaryPath() async => '/temporary';
}

/// The local automatic backup also runs after completion. Keep its file writes
/// in memory while SAF crosses only its real default MethodChannel boundary.
final class _MemoryIo extends IOOverrides {
  _MemoryIo(this.fs);
  final MemoryFileSystem fs;
  @override
  File createFile(String path) => fs.file(path);
  @override
  Directory createDirectory(String path) => fs.directory(path);
  @override
  Directory getCurrentDirectory() => fs.currentDirectory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = DownloadManager.instance;
  const safChannel = MethodChannel('easysave/saf');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final originalOwner = DownloadManager.owner;
  final originalPathProvider = PathProviderPlatform.instance;
  final originalIo = IOOverrides.current;
  late HistoryDb db;
  late MemoryFileSystem fs;
  late List<String> operations;
  late List<Map<String, dynamic>> written;
  late Completer<void> checked;
  late Completer<void> verified;
  var access = true;
  var saveSucceeds = true;

  setUpAll(() async {
    sqfliteFfiInit();
    // Resolve SQLite before enabling the in-memory file overrides.
    final warm = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await warm.close();
    databaseFactory = _MemoryDatabaseFactory();
    PathProviderPlatform.instance = _FakePaths();
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SiteRegistry.useBuiltin();
    fs = MemoryFileSystem();
    IOOverrides.global = _MemoryIo(fs);
    LocalAutoBackup.resetThrottleForTest();
    SafService.resetThrottleForTest();
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance();
    await db.clear();
    manager.clearBatchesForTesting();
    DownloadManager.owner = DownloadBatch.sourceBackground;
    manager.prepareStartForTesting = () async {};
    saveSucceeds = true;
    manager.enqueueForTesting = (_, job) async {
      job.state = saveSucceeds ? JobState.done : JobState.failed;
      job.saved = saveSucceeds;
      job.mediaId = saveSucceeds ? 'synthetic_media_id' : null;
    };
    operations = [];
    written = [];
    checked = Completer<void>();
    verified = Completer<void>();
    access = true;
    messenger.setMockMethodCallHandler(safChannel, (call) async {
      operations.add(call.method);
      final args = call.arguments as Map? ?? const {};
      switch (call.method) {
        case 'checkDirectoryAccess':
          expect(args['treeUri'], 'content://fixture/tree/backup');
          if (!checked.isCompleted) checked.complete();
          return access;
        case 'writeBackupToDirectory':
          expect(args['treeUri'], 'content://fixture/tree/backup');
          expect(args['fileName'], matches(kBackupFilenameRegExp));
          written.add(Map<String, dynamic>.from(args));
          return 'content://fixture/document/backup.json';
        case 'readDocumentContent':
          expect(args['uri'], 'content://fixture/document/backup.json');
          return written.last['content'];
        case 'listBackupDirectory':
          // The second listing is rotation and happens only after read-back
          // passed SafService's format/version/post-count validation.
          if (operations.contains('readDocumentContent') && !verified.isCompleted) {
            verified.complete();
          }
          return <Map<String, dynamic>>[];
        default:
          fail('Unexpected SAF I/O: ${call.method}');
      }
    });
  });
  tearDown(() async {
    // Drain auto-backup futures before dropping their shared DB/settings.
    await Future<void>.delayed(Duration.zero);
    await db.getAllActiveForBackup();
    await Future<void>.delayed(Duration.zero);
    for (final batch in await manager.liveBatches()) {
      await DownloadClaims.release(batch.batchId);
    }
    manager.clearBatchesForTesting();
    manager.prepareStartForTesting = null;
    manager.enqueueForTesting = null;
    DownloadManager.owner = originalOwner;
    messenger.setMockMethodCallHandler(safChannel, null);
    HistoryDb.resetInstanceForTesting();
    IOOverrides.global = originalIo;
    SiteRegistry.useBuiltin();
  });
  tearDownAll(() => PathProviderPlatform.instance = originalPathProvider);

  Future<void> configure({bool enabled = true, bool folder = true}) async {
    await (AppSettings()
          ..autoFolderBackupEnabled = enabled
          ..backupTreeUri = folder ? 'content://fixture/tree/backup' : null)
        .save();
  }

  Future<DownloadBatch> completeBackground(String id) => manager.startBatch(
        ParsedPost(platform: 'xhs', id: id,
          url: 'https://www.xiaohongshu.com/explore/$id', author: PostAuthor(),
          items: [MediaItem(type: 'image', url: 'https://sns-webpic-qc.xhscdn.com/$id.jpg')]),
        [0], album: 'EasySave', nameFor: (_, _, _) => id,
        requestGalleryAccess: false,
      );

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await db.getAllActiveForBackup();
    await Future<void>.delayed(Duration.zero);
    await db.getAllActiveForBackup();
    await Future<void>.delayed(Duration.zero);
  }

  test('background terminal download writes and verifies SAF through the default channel', () async {
    await configure();
    final batch = await completeBackground('background_saf');
    expect(batch.source, DownloadBatch.sourceBackground);
    expect(batch.jobs.single.saved, isTrue);
    expect(batch.jobs.single.state, JobState.done);
    await verified.future.timeout(const Duration(seconds: 5));
    await settle();
    expect(operations, ['checkDirectoryAccess', 'listBackupDirectory',
      'writeBackupToDirectory', 'readDocumentContent', 'listBackupDirectory']);
    final backup = jsonDecode(written.single['content'] as String) as Map;
    expect(backup['format'], 'easysave-backup');
    expect(backup['formatVersion'], 1);
    final post = (backup['posts'] as List).single as Map;
    expect(post['sourceId'], 'background_saf');
    expect(post['files'], hasLength(1));
    expect((await AppSettings.load()).lastBackupTime, isNotNull);
  });

  for (final scenario in ['disabled', 'no_folder', 'permission_lost', 'empty_history']) {
    test('background completion preserves auto-backup guard: $scenario', () async {
      await configure(enabled: scenario != 'disabled', folder: scenario != 'no_folder');
      access = scenario != 'permission_lost';
      saveSucceeds = scenario != 'empty_history';
      await completeBackground('guard_$scenario');
      if (scenario == 'permission_lost' || scenario == 'empty_history') {
        await checked.future.timeout(const Duration(seconds: 5));
      }
      await settle();
      expect(written, isEmpty);
      expect(operations.where((op) => op != 'checkDirectoryAccess'), isEmpty);
      if (scenario == 'disabled' || scenario == 'no_folder') {
        expect(operations, isEmpty);
      } else {
        expect(operations, ['checkDirectoryAccess']);
      }
      if (scenario == 'empty_history') {
        expect(await db.getAllActiveForBackup(), isEmpty);
      }
    });
  }

  test('a second completed background post respects the one-hour SAF throttle', () async {
    await configure();
    await completeBackground('first_background');
    await verified.future.timeout(const Duration(seconds: 5));
    await settle();
    expect(written, hasLength(1));
    operations.clear();
    checked = Completer<void>();
    await completeBackground('second_background');
    await checked.future.timeout(const Duration(seconds: 5));
    await settle();
    expect(await db.getAllActiveForBackup(), hasLength(2));
    expect(written, hasLength(1));
    expect(operations, ['checkDirectoryAccess']);
  });
}
