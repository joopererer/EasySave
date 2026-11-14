// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 4: a schema-v2 backup carries the three on-device states.
//
// A restore has to keep them apart: an item the user deleted in the app comes
// back as deleted (never as "missing", never as a file to re-download), an item
// the album had already reported gone comes back missing, and a file the
// restoring device can see is saved again. A backup written before the field
// existed behaves exactly as it used to.

import 'dart:convert';

import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/backup/backup_restore_matcher.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provenance_dart/provenance_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _postId = '2118566677374022101';

class _EmptyAlbum implements RestoreAlbum {
  _EmptyAlbum([this.assets = const []]);

  @override
  final List<AssetEntity> assets;

  @override
  Future<bool> ensureIndexed() async => true;

  @override
  AssetEntity? byId(String id) => assets.where((a) => a.id == id).firstOrNull;

  @override
  Future<XmpProvenance?> provenance(AssetEntity asset) async => null;

  @override
  Future<int?> size(AssetEntity asset) async => null;
}

HistoryFile _file(int index, FileStatus status, {String? mediaId}) => HistoryFile(
  filename: '${_postId}_$index.jpg',
  savedAt: DateTime.utc(2026, 10, 1).millisecondsSinceEpoch,
  mediaId: mediaId,
  status: status,
  itemIndex: index,
  isImage: true,
  assetId: 'asset-$index',
  relativePath: 'Pictures/EasySave/',
);

Future<HistoryRecord> _seed(HistoryDb db, List<HistoryFile> files, {String? itemsJson}) async {
  await db.upsert(
    HistoryRecord(
      platform: 'xhs',
      postId: _postId,
      authorName: 'Author',
      title: 'Note',
      postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
      fileCount: files.length,
      createdAt: DateTime(2026, 10, 1),
      itemsJson: itemsJson ??
          jsonEncode([
            for (var i = 0; i < 4; i++)
              {'type': 'image', 'url': 'https://sns-img.xhscdn.com/$i.jpg'},
          ]),
      files: files,
    ),
  );
  return (await db.getByPostId(_postId))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HistoryDb db;
  late AppSettings settings;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    HistoryDb.setInstanceForTesting(db);
    await db.clear();
    settings = AppSettings();
  });

  tearDown(() => HistoryDb.resetInstanceForTesting());

  test('export writes the state of every file, deleted ones included', () async {
    await _seed(db, [
      _file(1, FileStatus.found, mediaId: '11'),
      _file(2, FileStatus.notFound, mediaId: '12'),
      _file(3, FileStatus.deleted),
    ]);

    final exported = await BackupService.exportBackup(db: db, settings: settings);
    final root = jsonDecode(exported) as Map<String, dynamic>;
    final post = (root['posts'] as List).single as Map<String, dynamic>;
    final files = {
      for (final f in post['files'] as List)
        (f as Map)['itemIndex'] as int: f['status'],
    };
    expect(files, {1: 'inDevice', 2: 'missing', 3: 'deleted'});
  });

  test('restore keeps deleted items deleted and never calls them missing', () async {
    await _seed(db, [
      _file(1, FileStatus.found, mediaId: '11'),
      _file(2, FileStatus.notFound, mediaId: '12'),
      _file(3, FileStatus.deleted),
    ]);
    final exported = await BackupService.exportBackup(db: db, settings: settings);
    await db.clear();

    // The restoring device holds nothing at all.
    final result = await BackupService.importBackup(
      exported,
      db: db,
      settings: settings,
      album: _EmptyAlbum(),
    );
    expect(result.restoredPosts, 1);
    expect(result.notOnDevice, 2,
        reason: 'the saved file and the missing one are the ones without a match');

    final restored = (await db.getByPostId(_postId))!;
    final byIndex = {for (final f in restored.files) f.itemIndex: f.status};
    expect(byIndex[1], FileStatus.notFound);
    expect(byIndex[2], FileStatus.notFound);
    expect(byIndex[3], FileStatus.deleted,
        reason: 'an item the user deleted is not a missing file');
    expect(restored.missingFiles.map((f) => f.itemIndex).toList(), [1, 2]);
    expect(restored.visibleFiles.map((f) => f.itemIndex).toList(), [1, 2]);
    // A v2 backup carries identity, not the post's item list, so the restored
    // record has no parse-time total and reports the highest index it knows —
    // the documented fallback for a record without that data.
    expect(restored.originalItemCount, 3);
  });

  test('restore puts a file the device holds back to saved', () async {
    await _seed(db, [
      _file(1, FileStatus.notFound, mediaId: '11'),
    ]);
    final exported = await BackupService.exportBackup(db: db, settings: settings);
    await db.clear();

    final asset = AssetEntity(
      id: '11',
      typeInt: AssetType.image.index,
      width: 1080,
      height: 1440,
      title: '${_postId}_1.jpg',
      relativePath: 'Pictures/EasySave/',
    );
    await BackupService.importBackup(
      exported,
      db: db,
      settings: settings,
      album: _EmptyAlbum([asset]),
    );
    final restored = (await db.getByPostId(_postId))!;
    expect(restored.files.single.status, FileStatus.found);
  });

  test('a backup without the field still restores the old way', () async {
    final legacy = jsonEncode({
      'format': BackupData.currentFormat,
      'schemaVersion': 2,
      'formatVersion': 2,
      'exportedAt': '2026-10-01T09:00:00+08:00',
      'appVersion': '1.10.0',
      'settings': BackupSettings().toMap(),
      'posts': [
        {
          'platform': 'xiaohongshu',
          'sourceId': _postId,
          'originalUrl': 'https://www.xiaohongshu.com/explore/$_postId',
          'title': 'Note',
          'savedAt': '2026-10-01T09:00:00+08:00',
          'status': 'success',
          'files': [
            {
              'itemIndex': 1,
              'mediaType': 'image',
              'filename': '${_postId}_1.jpg',
              'relativePath': 'Pictures/EasySave/',
              'savedAt': '2026-10-01T09:00:00+08:00',
              'mediaIdHint': '11',
            },
          ],
        },
      ],
    });

    await BackupService.importBackup(
      legacy,
      db: db,
      settings: settings,
      album: _EmptyAlbum(),
    );
    final restored = (await db.getByPostId(_postId))!;
    expect(restored.files.single.status, FileStatus.notFound,
        reason: 'no field means "let the album decide", as before');
    expect(restored.files.single.itemIndex, 1);
  });

  test('an unknown state is written as no field at all', () {
    final json = BackupFile(
      itemIndex: 1,
      mediaType: 'image',
      filename: 'x.jpg',
      savedAt: '2026-10-01T09:00:00+08:00',
      status: BackupFileStatus.unknown,
    ).toMap();
    expect(json.containsKey('status'), isFalse);
    expect(BackupFile.fromMap(json).status, BackupFileStatus.unknown);
  });

  test('the restore preview does not promise deleted items', () async {
    await _seed(db, [
      _file(1, FileStatus.found, mediaId: '11'),
      _file(2, FileStatus.deleted),
    ]);
    final exported = await BackupService.exportBackup(db: db, settings: settings);
    final preview = BackupService.previewBackup(exported);
    expect(preview.fileCount, 1, reason: 'the deleted item is not coming back');
    expect(preview.postCount, 1);
  });
}
