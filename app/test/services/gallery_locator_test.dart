// Copyright 2026 EasySave. All rights reserved.

import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/core/models.dart';
import 'package:easysave/metadata/xmp_jpeg.dart';
import 'package:easysave/metadata/xmp_model.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_header_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AssetEntity _createAsset(
  String id,
  String title, {
  String? relativePath,
  AssetType type = AssetType.image,
}) {
  return AssetEntity(
    id: id,
    typeInt: type.index,
    width: 100,
    height: 100,
    title: title,
    relativePath: relativePath,
  );
}

Uint8List _makeJpegWithXmp({
  required String assetId,
  required String platform,
  required String sourceId,
}) {
  final minimalJpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
  final prov = XmpProvenance(
    schema: 'easysave',
    assetId: assetId,
    capturedAt: DateTime.now(),
    capturedBy: 'EasySave',
    metadataDate: DateTime.now(),
    platform: platform,
    sourceId: sourceId,
  );
  return writeJpegXmp(minimalJpeg, prov);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String tempDbPath;
  late HistoryDb db;
  final locator = GalleryLocatorService.instance;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('easysave_locator');
    tempDbPath =
        '${tempDir.path}/locator_${DateTime.now().microsecondsSinceEpoch}.db';
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: tempDbPath);
    HistoryDb.setInstanceForTesting(db);
    locator.resetForTesting();
    MediaHeaderService.headerReader = null;
    MediaHeaderService.albumReader = null;
  });

  tearDown(() async {
    MediaHeaderService.headerReader = null;
    MediaHeaderService.albumReader = null;
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
    try {
      final file = File(tempDbPath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  });

  group('GalleryLocatorService Multi-Level Locating & XMP Verification', () {
    test('Level 1: Hits by exact relativePath + filename', () async {
      final asset1 = _createAsset(
        'a1',
        'xhs_post1_1.jpg',
        relativePath: 'Pictures/EasySave/',
      );
      final asset2 = _createAsset(
        'a2',
        'xhs_post1_1.jpg',
        relativePath: 'Download/Other/',
      );

      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset1, asset2],
        relativePaths: {
          'a1': 'Pictures/EasySave/',
          'a2': 'Download/Other/',
        },
      );

      final file = HistoryFile(
        filename: 'xhs_post1_1.jpg',
        relativePath: 'Pictures/EasySave',
        savedAt: 123456,
      );

      final found = await locator.locateAssetAsync(file, 'post1', platform: 'xhs');
      expect(found, isNotNull);
      expect(found!.id, 'a1');
    });

    test('Level 2: Hits by used album filename when XMP matches', () async {
      final asset = _createAsset('a_xmp', 'xhs_post2_1.jpg');
      final xmpBytes = _makeJpegWithXmp(
        assetId: 'asset_2',
        platform: 'xiaohongshu',
        sourceId: 'post2',
      );

      MediaHeaderService.headerReader = (mediaId, mime) async {
        if (mediaId == 'a_xmp') return xmpBytes;
        return Uint8List(0);
      };

      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );

      // file has no relativePath (or relativePath did not match)
      final file = HistoryFile(
        filename: 'xhs_post2_1.jpg',
        assetId: 'asset_2',
        savedAt: 123456,
      );

      final found = await locator.locateAssetAsync(file, 'post2', platform: 'xhs');
      expect(found, isNotNull);
      expect(found!.id, 'a_xmp');
    });

    test('Level 2: Hits by used album filename when file has NO XMP', () async {
      final asset = _createAsset('a_no_xmp', 'plain_image.jpg');

      MediaHeaderService.headerReader = (mediaId, mime) async {
        return Uint8List(0); // No XMP
      };

      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );

      final file = HistoryFile(
        filename: 'plain_image.jpg',
        savedAt: 123456,
      );

      final found = await locator.locateAssetAsync(file, 'post_plain', platform: 'xhs');
      expect(found, isNotNull);
      expect(found!.id, 'a_no_xmp');
    });

    test('Level 2 Rejection: Same filename but conflicting XMP is NOT associated', () async {
      final candidateWithConflict = _createAsset('a_conflict', 'common_name.jpg');
      final conflictXmp = _makeJpegWithXmp(
        assetId: 'different_asset_id',
        platform: 'instagram',
        sourceId: 'completely_different_post',
      );

      MediaHeaderService.headerReader = (mediaId, mime) async {
        if (mediaId == 'a_conflict') return conflictXmp;
        return Uint8List(0);
      };

      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [candidateWithConflict],
      );

      final file = HistoryFile(
        filename: 'common_name.jpg',
        assetId: 'my_asset_id',
        savedAt: 123456,
      );

      // Expected postId is 'my_post', but file XMP says 'completely_different_post'
      final found = await locator.locateAssetAsync(file, 'my_post', platform: 'xhs');
      expect(found, isNull, reason: 'Conflicting XMP must be rejected');
    });

    test('Level 3: Hits by fuzzy postId match when XMP matches or is absent', () async {
      // Filename in history record differs from title in gallery, but title contains postId
      final asset = _createAsset('a_fuzzy', 'download_abc123_1.jpg');

      MediaHeaderService.headerReader = (mediaId, mime) async => Uint8List(0);

      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );

      final file = HistoryFile(
        filename: 'original_abc123_1.jpg',
        savedAt: 123456,
      );

      final found = await locator.locateAssetAsync(file, 'abc123', platform: 'xhs');
      expect(found, isNotNull);
      expect(found!.id, 'a_fuzzy');
    });

    test('Level 3 Rejection: Title contains postId but XMP belongs to another post', () async {
      final asset = _createAsset('a_fuzzy_conflict', 'xhs_post777_1.jpg');
      final conflictingXmp = _makeJpegWithXmp(
        assetId: 'conflict_asset_777',
        platform: 'xiaohongshu',
        sourceId: 'post888', // Mismatch!
      );

      MediaHeaderService.headerReader = (mediaId, mime) async => conflictingXmp;

      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );

      final file = HistoryFile(
        filename: 'unmatched_file.jpg',
        savedAt: 123456,
      );

      final found = await locator.locateAssetAsync(file, 'post777', platform: 'xhs');
      expect(found, isNull, reason: 'Fuzzy match with conflicting XMP must be rejected');
    });

    test('All levels miss: Record is preserved in DB (never deleted, isDeleted remains false)', () async {
      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [], // empty gallery
      );

      final file = HistoryFile(
        filename: 'missing_file.jpg',
        savedAt: 123456,
        status: FileStatus.found,
      );

      final record = HistoryRecord(
        platform: 'xhs',
        postId: 'post_missing',
        authorName: 'author',
        title: 'Missing Post',
        caption: 'caption',
        postUrl: 'https://xhs.com/post_missing',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [file],
      );

      await db.upsert(record, restoreDeleted: false);
      final initialRecord = await db.getByPostId('post_missing');
      expect(initialRecord, isNotNull);
      expect(initialRecord!.isDeleted, isFalse);

      // Run syncRecord
      await locator.syncRecord(initialRecord);

      // Verify record is preserved in DB and NOT deleted
      final preserved = await db.getByPostId('post_missing');
      expect(preserved, isNotNull);
      expect(preserved!.isDeleted, isFalse, reason: 'Record must not be marked deleted');
      expect(preserved.files.first.status, FileStatus.notFound,
          reason: 'File status should be updated to notFound');
      expect((await db.recent()).length, 1, reason: 'Record count in DB must remain unchanged');
    });

    test('syncRecord: Backfills missing relativePath and updates DB', () async {
      final asset = _createAsset(
        'asset_backfill',
        'backfill_item.jpg',
        relativePath: 'Pictures/EasySave/',
      );

      MediaHeaderService.headerReader = (mediaId, mime) async => Uint8List(0);
      MediaHeaderService.albumReader = (mediaId) async {
        return (album: 'EasySave', relativePath: 'Pictures/EasySave/');
      };

      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );

      // Older record without relativePath
      final file = HistoryFile(
        filename: 'backfill_item.jpg',
        savedAt: 123456,
        relativePath: null,
      );

      final record = HistoryRecord(
        platform: 'xhs',
        postId: 'post_backfill',
        authorName: 'author',
        title: 'Backfill Post',
        caption: 'caption',
        postUrl: 'https://xhs.com/post_backfill',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [file],
      );

      await db.upsert(record, restoreDeleted: false);
      final savedRecord = await db.getByPostId('post_backfill');
      expect(savedRecord!.files.first.relativePath, isNull);

      // Run syncRecord
      await locator.syncRecord(savedRecord);

      // Verify relativePath was backfilled into database
      final updatedRecord = await db.getByPostId('post_backfill');
      expect(updatedRecord, isNotNull);
      expect(updatedRecord!.files.first.mediaId, 'asset_backfill');
      expect(updatedRecord.files.first.status, FileStatus.found);
      expect(updatedRecord.files.first.relativePath, 'Pictures/EasySave/');
    });
  });
}
