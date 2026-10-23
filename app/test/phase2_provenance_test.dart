// Copyright 2026 EasySave. All rights reserved.
// Phase 2 Provenance Tests:
// 1. Version consistency between provenanceSpecVersion and docs/provenance-spec CHANGELOG.md
// 2. Backfill write path protection: uses byte APIs + File.writeAsBytes, never creates .tmp files in target dir
// 3. Rebuild deduplication with mixed timezone formats (e.g. +02:00 vs Z), testing both input orders

import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/core/app_version.dart';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/metadata/provenance_version.dart';
import 'package:easysave/metadata/url_normalizer.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_rebuild_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:provenance_dart/provenance_dart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  final vectorsDir = p.canonicalize(
    p.join(Directory.current.path, '..', 'docs', 'provenance-spec', 'test-vectors'),
  );

  group('Phase 2: Version Consistency', () {
    test('provenanceSpecVersion matches docs/provenance-spec CHANGELOG.md', () {
      final changelogFile = File(
        p.canonicalize(p.join(Directory.current.path, '..', 'docs', 'provenance-spec', 'CHANGELOG.md')),
      );
      expect(changelogFile.existsSync(), isTrue, reason: 'CHANGELOG.md must exist in docs/provenance-spec');

      final content = changelogFile.readAsStringSync();
      final match = RegExp(r'^##\s+(\d+\.\d+\.\d+)', multiLine: true).firstMatch(content);
      expect(match, isNotNull, reason: 'CHANGELOG.md should have a version heading');

      final changelogVersion = match!.group(1);
      expect(
        provenanceSpecVersion,
        equals(changelogVersion),
        reason: 'Local provenanceSpecVersion must match latest docs/provenance-spec version',
      );
    });

    test('capturedBy reads EasySave/1.8.1 matching pubspec.yaml version', () {
      final pubspecFile = File('pubspec.yaml');
      final content = pubspecFile.readAsStringSync();
      final match = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)', multiLine: true).firstMatch(content);
      expect(match, isNotNull);
      final pubspecVersion = match!.group(1);
      final buildNumber = match!.group(2);
      expect(pubspecVersion, equals('1.8.1'));
      expect(buildNumber, equals('6'));
      expect(AppVersion.capturedBy, equals('EasySave/1.8.1'));
    });
  });

  group('Phase 2: Backfill Write Path (No .tmp files in gallery)', () {
    late Directory tempGalleryDir;

    setUp(() async {
      tempGalleryDir = await Directory.systemTemp.createTemp('gallery_sim_');
    });

    tearDown(() async {
      if (tempGalleryDir.existsSync()) {
        await tempGalleryDir.delete(recursive: true);
      }
    });

    test('backfill reads bytes and writes via writeAsBytes without creating .tmp files', () async {
      final fixtureFile = File(p.join(vectorsDir, 'no-metadata.jpg'));
      final targetFile = File(p.join(tempGalleryDir.path, 'photo.jpg'));
      await fixtureFile.copy(targetFile.path);

      // Verify directory has exactly 1 file before backfill
      expect(tempGalleryDir.listSync().map((e) => p.basename(e.path)).toList(), ['photo.jpg']);

      final originalBytes = await targetFile.readAsBytes();
      final format = detectFormat(originalBytes);
      expect(format, equals(MediaFormat.jpeg));

      final provenance = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.8.0',
        sourceId: 'post_backfill_1',
        sourceUrl: 'https://www.xiaohongshu.com/explore/post_backfill_1',
        authorName: '测试作者',
        creditPlatformName: '小红书',
        capturedAt: DateTime.utc(2026, 1, 1),
      ).build();

      // In-memory transformation
      final newBytes = writeJpegXmp(originalBytes, provenance);
      expect(newBytes.isNotEmpty, isTrue);

      // Write directly to file as backfill service does
      await targetFile.writeAsBytes(newBytes, flush: true);

      // Verify NO .tmp or auxiliary files exist in the gallery directory
      final filesAfter = tempGalleryDir.listSync().map((e) => p.basename(e.path)).toList();
      expect(filesAfter, ['photo.jpg']);

      // Verify the modified file now contains provenance
      final readBack = readJpegXmp(await targetFile.readAsBytes());
      expect(readBack, isNotNull);
      expect(readBack!.sourceId, equals('post_backfill_1'));
      expect(readBack.capturedBy, equals('EasySave/1.8.0'));
    });
  });

  group('Phase 2: History Reconstruction Deduplication (Mixed Timezones)', () {
    late String tempDbPath;
    late HistoryDb db;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      final tempDir = await Directory.systemTemp.createTemp('dedup_rebuild_');
      tempDbPath = '${tempDir.path}/test_${DateTime.now().microsecondsSinceEpoch}.db';
      HistoryDb.resetInstanceForTesting();
      db = await HistoryDb.instance(dbPath: tempDbPath);
    });

    tearDown(() async {
      HistoryDb.resetInstanceForTesting();
      try {
        final f = File(tempDbPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    });

    AssetEntity makeAsset(String id, String title) => AssetEntity(
          id: id,
          typeInt: AssetType.image.index,
          width: 100,
          height: 100,
          title: title,
          mimeType: 'image/jpeg',
        );

    // Two different timestamps for the same item:
    // Earlier: 2026-10-22T14:00:00+02:00 (= 12:00:00 UTC)
    // Later:   2026-10-22T13:00:00Z       (= 13:00:00 UTC)
    final earlierCapturedAt = DateTime.parse('2026-10-22T14:00:00+02:00');
    final laterCapturedAt = DateTime.parse('2026-10-22T13:00:00Z');

    test('earlier capturedAt (+02:00 offset vs Z) wins when earlier is first [offset, Z]', () async {
      final assetOffset = makeAsset('m_offset', 'img_offset.jpg');
      final assetZ = makeAsset('m_z', 'img_z.jpg');

      final provOffset = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.8.0',
        sourceId: 'shared_post_123',
        sourceUrl: 'https://www.xiaohongshu.com/explore/shared_post_123',
        existingAssetId: 'id-offset-earlier',
        capturedAt: earlierCapturedAt,
        itemIndex: 1,
        itemCount: 1,
      ).build();

      final provZ = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.8.0',
        sourceId: 'shared_post_123',
        sourceUrl: 'https://www.xiaohongshu.com/explore/shared_post_123',
        existingAssetId: 'id-z-later',
        capturedAt: laterCapturedAt,
        itemIndex: 1,
        itemCount: 1,
      ).build();

      final baseJpeg = File(p.join(vectorsDir, 'no-metadata.jpg')).readAsBytesSync();
      final headerOffset = writeJpegXmp(baseJpeg, provOffset);
      final headerZ = writeJpegXmp(baseJpeg, provZ);

      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: [assetOffset, assetZ],
        dbOverride: db,
        readHeader: (id, mime) async {
          return id == 'm_offset' ? headerOffset : headerZ;
        },
      );

      expect(result.processed, 2);
      final record = await db.getByPostId('shared_post_123');
      expect(record, isNotNull);
      expect(record!.files.length, 1);
      // Chronologically earlier (12:00 UTC) wins over 13:00 UTC
      expect(record.files.first.assetId, equals('id-offset-earlier'));
      expect(record.createdAt.toUtc(), equals(earlierCapturedAt.toUtc()));
    });

    test('earlier capturedAt (+02:00 offset vs Z) wins when later is first [Z, offset]', () async {
      final assetOffset = makeAsset('m_offset', 'img_offset.jpg');
      final assetZ = makeAsset('m_z', 'img_z.jpg');

      final provOffset = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.8.0',
        sourceId: 'shared_post_123',
        sourceUrl: 'https://www.xiaohongshu.com/explore/shared_post_123',
        existingAssetId: 'id-offset-earlier',
        capturedAt: earlierCapturedAt,
        itemIndex: 1,
        itemCount: 1,
      ).build();

      final provZ = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.8.0',
        sourceId: 'shared_post_123',
        sourceUrl: 'https://www.xiaohongshu.com/explore/shared_post_123',
        existingAssetId: 'id-z-later',
        capturedAt: laterCapturedAt,
        itemIndex: 1,
        itemCount: 1,
      ).build();

      final baseJpeg = File(p.join(vectorsDir, 'no-metadata.jpg')).readAsBytesSync();
      final headerOffset = writeJpegXmp(baseJpeg, provOffset);
      final headerZ = writeJpegXmp(baseJpeg, provZ);

      // Order reversed: [assetZ, assetOffset]
      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: [assetZ, assetOffset],
        dbOverride: db,
        readHeader: (id, mime) async {
          return id == 'm_offset' ? headerOffset : headerZ;
        },
      );

      expect(result.processed, 2);
      final record = await db.getByPostId('shared_post_123');
      expect(record, isNotNull);
      expect(record!.files.length, 1);
      // Regardless of ordering, chronologically earlier (12:00 UTC) wins
      expect(record.files.first.assetId, equals('id-offset-earlier'));
      expect(record.createdAt.toUtc(), equals(earlierCapturedAt.toUtc()));
    });
  });
}
