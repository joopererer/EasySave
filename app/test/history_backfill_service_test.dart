// Copyright 2026 EasySave. All rights reserved.
// Tests for backfill DevLog categorization by skip reason.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/models.dart';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_backfill_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:easysave/services/media_header_service.dart';

void main() {
  group('BackfillResult', () {
    test('breakdown message includes detailed skip reasons', () {
      final result = BackfillResult(
        totalFiles: 110,
        total: 100,
        success: 50,
        authRequired: 10,
        alreadyHasMetadata: 20,
        fileNotFound: 10,
        noWritePermission: 5,
        formatNotSupported: 3,
        skippedVideo: 8,
        skippedNotLocated: 2,
        otherError: 2,
      );

      final msg = result.toString();
      expect(msg, contains('50/100 written'));
      expect(msg, contains('10 required permission'));
      expect(msg, contains('20 already had metadata'));
      expect(msg, contains('10 file not found'));
      expect(msg, contains('5 no write permission'));
      expect(msg, contains('3 format not supported'));
      expect(msg, contains('8 video'));
      expect(msg, contains('2 not located'));
      expect(msg, contains('2 other errors'));
    });

    test('skipped getter sums all skip categories', () {
      final result = BackfillResult(
        totalFiles: 110,
        total: 100,
        success: 50,
        authRequired: 10,
        alreadyHasMetadata: 20,
        fileNotFound: 10,
        noWritePermission: 5,
        formatNotSupported: 3,
        skippedVideo: 8,
        skippedNotLocated: 2,
        otherError: 2,
      );

      // skipped = already + notFound + noWrite + formatNotSupported + video + notLocated + other
      expect(result.skipped, 50); // 20 + 10 + 5 + 3 + 8 + 2 + 2
      expect(result.success + result.authRequired + result.skipped, 110);
    });

    test('omits zero-count reasons from message', () {
      final result = BackfillResult(
        totalFiles: 50,
        total: 50,
        success: 50,
        authRequired: 0,
        alreadyHasMetadata: 0,
        fileNotFound: 0,
        noWritePermission: 0,
        formatNotSupported: 0,
        skippedVideo: 0,
        skippedNotLocated: 0,
        otherError: 0,
      );

      final msg = result.toString();
      expect(msg, '50/50 written');
      expect(msg.split(',').length, 1); // Only one part
    });
  });

  group('HistoryBackfillService video backfill', () {
    late Directory tempDir;
    late String tempDbPath;
    late HistoryDb db;
    final locator = GalleryLocatorService.instance;

    final minimalMp4 = Uint8List.fromList([
      0x00, 0x00, 0x00, 0x14,
      0x66, 0x74, 0x79, 0x70, // ftyp
      0x69, 0x73, 0x6F, 0x6D, // isom
      0x00, 0x00, 0x02, 0x00,
      0x69, 0x73, 0x6F, 0x6D,
    ]);

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('backfill_test_');
      tempDbPath = '${tempDir.path}/test.db';
      HistoryDb.resetInstanceForTesting();
      db = await HistoryDb.instance(dbPath: tempDbPath);
      HistoryDb.setInstanceForTesting(db);
      locator.resetForTesting();
      MediaHeaderService.headerReader = null;
      MediaHeaderService.scanner = null;
      MetadataService.embedOverride = null;
      HistoryBackfillService.assetFileResolver = null;
      MediaDeleteService.instance.requestWriteAccessOverride = null;
    });

    tearDown(() async {
      MetadataService.embedOverride = null;
      HistoryBackfillService.assetFileResolver = null;
      MediaHeaderService.headerReader = null;
      MediaHeaderService.scanner = null;
      MediaDeleteService.instance.requestWriteAccessOverride = null;
      locator.resetForTesting();
      HistoryDb.resetInstanceForTesting();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('mock asset.file returning different path (copy) fails re-read verification', () async {
      final albumFile = File('${tempDir.path}/album_video.mp4')
        ..writeAsBytesSync(minimalMp4);
      final copyFile = File('${tempDir.path}/copy_video.mp4')
        ..writeAsBytesSync(minimalMp4);

      final asset = AssetEntity(
        id: 'asset_vid_1',
        typeInt: AssetType.video.index,
        width: 100,
        height: 100,
        title: 'album_video.mp4',
        mimeType: 'video/mp4',
      );

      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );

      await db.upsert(HistoryRecord(
        postId: 'post_video_1',
        postUrl: 'https://xhs.com/post_video_1',
        platform: 'xiaohongshu',
        authorName: 'Author',
        title: 'Video Title',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'album_video.mp4',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            mediaId: 'asset_vid_1',
            status: FileStatus.found,
            isImage: false,
          ),
        ],
      ));

      // mock asset.file returns a different path (copyFile)
      HistoryBackfillService.assetFileResolver = (a) async => copyFile;
      MediaHeaderService.scanner = (path, mime) async => 'content://media/external/video/media/1';
      // Native layer re-reads from media URI, which points to albumFile without the provenance written to copyFile
      MediaHeaderService.headerReader = (mediaId, mime) async => albumFile.readAsBytesSync();

      final result = await HistoryBackfillService.instance.backfill();

      expect(result.success, 0);
      expect(result.otherError, 1);
    });

    test('permission error triggers authorization flow and retries', () async {
      final videoFile = File('${tempDir.path}/perm_video.mp4')
        ..writeAsBytesSync(minimalMp4);

      final asset = AssetEntity(
        id: 'asset_perm_1',
        typeInt: AssetType.video.index,
        width: 100,
        height: 100,
        title: 'perm_video.mp4',
        mimeType: 'video/mp4',
      );

      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );

      await db.upsert(HistoryRecord(
        postId: 'post_perm_1',
        postUrl: 'https://xhs.com/post_perm_1',
        platform: 'xiaohongshu',
        authorName: 'Author',
        title: 'Video Title',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'perm_video.mp4',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            mediaId: 'asset_perm_1',
            status: FileStatus.found,
            isImage: false,
          ),
        ],
      ));

      HistoryBackfillService.assetFileResolver = (a) async => videoFile;
      MediaHeaderService.scanner = (path, mime) async => 'content://media/external/video/media/2';

      var authRequested = false;
      MediaDeleteService.instance.requestWriteAccessOverride = (media) async {
        authRequested = true;
        return true;
      };

      var attempts = 0;
      MetadataService.embedOverride = ({
        required String filePath,
        required XmpProvenance provenance,
        bool? checkC2pa,
        Mp4WriteMode? mp4WriteMode,
      }) async {
        attempts++;
        if (attempts == 1) {
          return EmbedResult.failure(
            EmbedErrorCode.writeFailed,
            'Write failed: FileSystemException: Cannot open file, path = \'$filePath\' (OS Error: Permission denied, errno = 13)',
            cause: FileSystemException(
              'Cannot open file',
              filePath,
              const OSError('Permission denied', 13),
            ),
          );
        }
        // Second attempt succeeds
        MediaHeaderService.headerReader = (mediaId, mime) async {
          return writeMp4Xmp(minimalMp4, provenance);
        };
        return EmbedResult.embedded();
      };

      final result = await HistoryBackfillService.instance.backfill();

      expect(authRequested, isTrue);
      expect(attempts, 2);
      expect(result.success, 1);
    });

    test('non-permission write failure does not trigger authorization', () async {
      final videoFile = File('${tempDir.path}/disk_full_video.mp4')
        ..writeAsBytesSync(minimalMp4);

      final asset = AssetEntity(
        id: 'asset_disk_1',
        typeInt: AssetType.video.index,
        width: 100,
        height: 100,
        title: 'disk_full_video.mp4',
        mimeType: 'video/mp4',
      );

      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [asset],
      );

      await db.upsert(HistoryRecord(
        postId: 'post_disk_1',
        postUrl: 'https://xhs.com/post_disk_1',
        platform: 'xiaohongshu',
        authorName: 'Author',
        title: 'Video Title',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: 'disk_full_video.mp4',
            savedAt: DateTime.now().millisecondsSinceEpoch,
            mediaId: 'asset_disk_1',
            status: FileStatus.found,
            isImage: false,
          ),
        ],
      ));

      HistoryBackfillService.assetFileResolver = (a) async => videoFile;

      var authRequested = false;
      MediaDeleteService.instance.requestWriteAccessOverride = (media) async {
        authRequested = true;
        return true;
      };

      MetadataService.embedOverride = ({
        required String filePath,
        required XmpProvenance provenance,
        bool? checkC2pa,
        Mp4WriteMode? mp4WriteMode,
      }) async {
        return EmbedResult.failure(
          EmbedErrorCode.writeFailed,
          'No space left on device',
          cause: FileSystemException(
            'Write failed',
            filePath,
            const OSError('No space left on device', 28),
          ),
        );
      };

      final result = await HistoryBackfillService.instance.backfill();

      expect(authRequested, isFalse);
      expect(result.otherError, 1);
      expect(result.success, 0);
    });
  });
}
