// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 4: the three states of one media item.
//
//   在本机   — the album answered and holds the file (FileStatus.found)
//   不在本机 — the album answered and does not hold it any more (notFound)
//   已删除   — the user deleted it in the app (deleted)
//
// The rules the device reports taught: a query that times out, errors or lacks
// permission says nothing about a file and must never change its state (the HEIC
// freeze); a missing row is kept so the viewer can offer its re-download, and a
// deleted row is neither shown, counted nor offered.

import 'dart:async';
import 'dart:convert';

import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _postId = '2118566677374022101';

HistoryFile _file(
  int index, {
  FileStatus status = FileStatus.found,
  String? mediaId,
  bool image = true,
}) => HistoryFile(
  filename: '${_postId}_$index.${image ? 'jpg' : 'mp4'}',
  savedAt: 1,
  mediaId: mediaId,
  status: status,
  itemIndex: index,
  isImage: image,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HistoryDb db;
  final locator = GalleryLocatorService.instance;
  late Duration originalTimeout;

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
    locator.resetForTesting();
    originalTimeout = GalleryLocatorService.lookupTimeout;
  });

  tearDown(() {
    GalleryLocatorService.lookupTimeout = originalTimeout;
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  Future<HistoryRecord> seed(List<HistoryFile> files, {String? itemsJson}) async {
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: _postId,
        postUrl: 'https://www.xiaohongshu.com/explore/$_postId',
        title: 'Status',
        fileCount: files.length,
        createdAt: DateTime(2026),
        itemsJson: itemsJson,
        files: files,
      ),
    );
    return (await db.getByPostId(_postId))!;
  }

  group('the states round-trip through storage', () {
    test('a deleted row is stored, read back and never counted as missing', () async {
      final record = await seed([
        _file(1, mediaId: '11'),
        _file(2, status: FileStatus.notFound, mediaId: '12'),
        _file(3, status: FileStatus.deleted, mediaId: '13'),
      ]);
      expect(record.files.map((f) => f.status).toList(), [
        FileStatus.found,
        FileStatus.notFound,
        FileStatus.deleted,
      ]);
      expect(record.savedFiles.length, 1);
      expect(record.missingFiles.length, 1);
      expect(record.visibleFiles.map((f) => f.itemIndex).toList(), [1, 2]);
      // The raw total is unchanged: the deleted item still existed.
      expect(record.originalItemCount, 3);
    });

    test('a row that was never downloaded is not shown', () async {
      // An inferred row with no album identity at all: the post JSON listed the
      // media, the user never ticked it.
      final record = await seed([
        _file(1, mediaId: '11'),
        HistoryFile(filename: '${_postId}_2.jpg', savedAt: 0, itemIndex: 2),
      ]);
      expect(record.visibleFiles.map((f) => f.itemIndex).toList(), [1]);
    });
  });

  group('only a real answer changes a state', () {
    test('a lookup timeout leaves a saved row exactly as it was', () async {
      final record = await seed([_file(1, mediaId: '11')]);
      final asset = AssetEntity(
        id: '11',
        typeInt: AssetType.image.index,
        width: 1080,
        height: 1440,
        title: '${_postId}_1.jpg',
      );
      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );
      // The existence probe never answers (the HEIC freeze that stalled the
      // album channel for minutes).
      locator.presenceProbeForTesting = (_) => Completer<bool>().future;
      GalleryLocatorService.lookupTimeout = const Duration(milliseconds: 30);

      await locator.syncRecord(record);
      expect(record.files.single.status, FileStatus.found,
          reason: 'a timeout is not a verdict');
      final stored = (await db.getByPostId(_postId))!;
      expect(stored.files.single.status, FileStatus.found);
    });

    test('no album permission leaves a saved row exactly as it was', () async {
      final record = await seed([_file(1, mediaId: '11')]);
      locator.setScannedForTesting(
        scanned: false,
        permission: PermissionState.denied,
        assets: const [],
      );
      await locator.syncRecord(record);
      expect(record.files.single.status, FileStatus.found);
    });

    test('an answered lookup with the file gone marks it not on the device', () async {
      final record = await seed([_file(1)]);
      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: const [],
      );
      await locator.syncRecord(record);
      expect(record.files.single.status, FileStatus.notFound);
      // The row is kept, not deleted: it is what the viewer shows the
      // placeholder and the re-download button for.
      final stored = (await db.getByPostId(_postId))!;
      expect(stored.files, hasLength(1));
      expect(stored.missingFiles, hasLength(1));
    });

    test('a file that comes back is saved again', () async {
      await seed([_file(1, status: FileStatus.notFound, mediaId: '11')]);
      final asset = AssetEntity(
        id: '11',
        typeInt: AssetType.image.index,
        width: 1080,
        height: 1440,
        title: '${_postId}_1.jpg',
      );
      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );
      locator.presenceProbeForTesting = (_) async => true;
      final record = (await db.getByPostId(_postId))!;
      await locator.syncRecord(record);
      expect(record.files.single.status, FileStatus.found);
    });

    test('a deleted row is never looked up and never comes back', () async {
      final record = await seed([_file(1, status: FileStatus.deleted, mediaId: '11')]);
      var probes = 0;
      locator.presenceProbeForTesting = (_) async {
        probes++;
        return true;
      };
      final asset = AssetEntity(
        id: '11',
        typeInt: AssetType.image.index,
        width: 1080,
        height: 1440,
        title: '${_postId}_1.jpg',
      );
      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );
      await locator.syncRecord(record);
      expect(probes, 0, reason: 'the album scan never revisits a deleted item');
      expect(record.files.single.status, FileStatus.deleted);
    });
  });

  group('original position counting', () {
    test('the parsed item total wins', () async {
      final record = await seed(
        [_file(1, mediaId: '11'), _file(3, mediaId: '13')],
        itemsJson: jsonEncode([
          for (var i = 0; i < 8; i++) {'type': 'image', 'url': 'https://x/$i.jpg'},
        ]),
      );
      expect(record.originalItemCount, 8);
    });

    test('an old record without items falls back to the highest item index', () async {
      final record = await seed([
        _file(1, mediaId: '11'),
        _file(4, status: FileStatus.notFound, mediaId: '14'),
      ]);
      expect(record.originalItemCount, 4,
          reason: 'the highest index a post ever reached');
    });

    test('a deleted item does not shrink the fallback total', () async {
      final record = await seed([
        _file(1, mediaId: '11'),
        _file(5, status: FileStatus.deleted, mediaId: '15'),
      ]);
      expect(record.originalItemCount, 5);
    });
  });
}
