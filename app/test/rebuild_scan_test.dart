// Copyright 2026 EasySave. All rights reserved.
// Task 4 (v1.7): the rebuild scan reads only the file headers.
//
// The scan used to copy every file out of the album (photo_manager
// `originFile`) and read it completely. It now asks the native side for the
// header bytes only, skips the formats it cannot parse and can be cancelled
// without losing what it already processed.

import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_rebuild_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AssetEntity _asset(
  String id,
  String title,
  String mimeType, {
  AssetType type = AssetType.image,
  String? relativePath,
}) =>
    AssetEntity(
      id: id,
      typeInt: type.index,
      width: 100,
      height: 100,
      title: title,
      mimeType: mimeType,
      relativePath: relativePath,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late String tempDbPath;
  late HistoryDb db;
  late Uint8List jpegHeader;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('easysave_scan');
    tempDbPath =
        '${tempDir.path}/scan_${DateTime.now().microsecondsSinceEpoch}.db';
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: tempDbPath);

    // A real file with XMP: its first 128 KB are exactly what the native
    // side would return for a JPEG.
    final vectors = '${Directory.current.path}/../docs/provenance-spec/test-vectors';
    final fixture = File('$vectors/xhs-item3.jpg');
    expect(fixture.existsSync(), isTrue, reason: 'test vector not found');
    final bytes = fixture.readAsBytesSync();
    jpegHeader = bytes.length > 128 * 1024
        ? Uint8List.fromList(bytes.sublist(0, 128 * 1024))
        : bytes;
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
    try {
      final file = File(tempDbPath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Ignore cleanup errors
    }
  });

  group('MetadataService.readProvenanceFromBytes', () {
    test('parses the XMP of a JPEG header buffer', () {
      final provenance = MetadataService.readProvenanceFromBytes(jpegHeader);
      expect(provenance, isNotNull);
      expect(provenance!.platform, isNotNull);
      expect(provenance.sourceId, isNotNull);
    });

    test('an empty buffer yields nothing', () {
      expect(MetadataService.readProvenanceFromBytes(Uint8List(0)), isNull);
    });
  });

  group('HistoryRebuildService.rebuild', () {
    test('reads the header only and writes one record per post', () async {
      final readIds = <String>[];
      final assets = [
        _asset('m1', 'xhs_1_1.jpg', 'image/jpeg'),
        _asset('m2', 'xhs_1_2.jpg', 'image/jpeg'),
      ];

      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: assets,
        dbOverride: db,
        readHeader: (mediaId, mimeType) async {
          readIds.add(mediaId);
          return jpegHeader;
        },
      );

      expect(readIds, ['m1', 'm2']);
      expect(result.processed, 2);
      expect(result.skipped, 0);
      expect(result.created + result.merged, greaterThanOrEqualTo(1));
      expect(await db.recent(), isNotEmpty);
    });

    test('skips formats it cannot parse', () async {
      final readIds = <String>[];
      final assets = [
        _asset('gif1', 'anim.gif', 'image/gif'),
        _asset('heic1', 'clip.heic', 'image/heic'),
        _asset('jpg1', 'a.jpg', 'image/jpeg'),
      ];

      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: assets,
        dbOverride: db,
        readHeader: (mediaId, mimeType) async {
          readIds.add(mediaId);
          return jpegHeader;
        },
      );

      expect(readIds, ['jpg1']);
      expect(result.skipped, 2);
    });

    test('cancelling keeps what was already processed', () async {
      final assets = [
        _asset('m1', 'a_1.jpg', 'image/jpeg'),
        _asset('m2', 'b_1.jpg', 'image/jpeg'),
        _asset('m3', 'c_1.jpg', 'image/jpeg'),
      ];
      var seen = 0;

      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: assets,
        dbOverride: db,
        isCancelled: () => seen >= 2,
        readHeader: (mediaId, mimeType) async {
          seen++;
          return jpegHeader;
        },
      );

      expect(result.cancelled, isTrue);
      expect(result.processed, 2);
      expect(result.processed, lessThan(assets.length));
    });

    test('a file whose header cannot be read is skipped', () async {
      final assets = [_asset('m1', 'a_1.jpg', 'image/jpeg')];

      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: assets,
        dbOverride: db,
        readHeader: (mediaId, mimeType) async => Uint8List(0),
      );

      expect(result.skipped, 1);
      expect(result.created, 0);
    });
  });

  group('HistoryRebuildService video pairing', () {
    Uint8List makeJpeg(XmpProvenance prov) {
      final minimalJpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      return writeJpegXmp(minimalJpeg, prov);
    }

    Uint8List makeMp4(XmpProvenance prov) {
      final minimalMp4 = Uint8List.fromList([
        0x00, 0x00, 0x00, 0x14,
        0x66, 0x74, 0x79, 0x70,
        0x69, 0x73, 0x6F, 0x6D,
        0x00, 0x00, 0x02, 0x00,
        0x69, 0x73, 0x6F, 0x6D,
      ]);
      return writeMp4Xmp(minimalMp4, prov);
    }

    XmpProvenance makeProv({
      required String assetId,
      required String sourceId,
      int itemIndex = 1,
      String? pairId,
      String platform = 'xiaohongshu',
    }) =>
        XmpProvenance(
          schema: '0.1',
          assetId: assetId,
          platform: platform,
          sourceId: sourceId,
          sourceUrl: 'https://xhs.com/$sourceId',
          itemIndex: itemIndex,
          pairId: pairId,
          capturedAt: DateTime.now(),
          capturedBy: 'EasySave/1.8.2',
          metadataDate: DateTime.now(),
        );

    test('正常配对: pairs by pairId', () async {
      final imgAsset = _asset('img1', 'xhs_post1_1.jpg', 'image/jpeg');
      final vidAsset = _asset(
        'vid1',
        'xhs_post1_1.mp4',
        'video/mp4',
        type: AssetType.video,
      );

      final imgProv = makeProv(
        assetId: 'aid-img-1',
        sourceId: 'post1',
        itemIndex: 1,
        pairId: 'post1#1',
      );

      final vidProv = makeProv(
        assetId: 'aid-vid-1',
        sourceId: 'post1',
        itemIndex: 1,
        pairId: 'post1#1',
      );

      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: [imgAsset, vidAsset],
        dbOverride: db,
        readHeader: (mediaId, mimeType) async {
          if (mediaId == 'img1') return makeJpeg(imgProv);
          if (mediaId == 'vid1') return makeMp4(vidProv);
          return Uint8List(0);
        },
      );

      expect(result.created, 1);
      final records = await db.recent();
      expect(records.length, 1);
      final record = records.first;
      expect(record.files.length, 2);
      expect(record.files.any((f) => f.isImage && f.itemIndex == 1), isTrue);
      expect(record.files.any((f) => !f.isImage && f.itemIndex == 1), isTrue);
    });

    test('无 pairId 回退配对: pairs when same album, same stem, single candidate', () async {
      final imgAsset = _asset(
        'img2',
        'post2_1.jpg',
        'image/jpeg',
        relativePath: 'Pictures/EasySave/',
      );
      final vidAsset = _asset(
        'vid2',
        'post2_1.mp4',
        'video/mp4',
        type: AssetType.video,
        relativePath: 'Pictures/EasySave/',
      );

      final imgProv = makeProv(
        assetId: 'aid-img-2',
        sourceId: 'post2',
        itemIndex: 1,
      );

      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: [imgAsset, vidAsset],
        dbOverride: db,
        readHeader: (mediaId, mimeType) async {
          if (mediaId == 'img2') return makeJpeg(imgProv);
          // Video has no XMP header
          return Uint8List(0);
        },
      );

      expect(result.created, 1);
      final records = await db.recent();
      expect(records.length, 1);
      final record = records.first;
      expect(record.files.length, 2);
      expect(record.files.any((f) => f.isImage && f.mediaId == 'img2'), isTrue);
      expect(record.files.any((f) => !f.isImage && f.mediaId == 'vid2'), isTrue);
    });

    test('多个候选时不配对: does not pair when multiple candidate videos exist', () async {
      final imgAsset = _asset(
        'img3',
        'post3_1.jpg',
        'image/jpeg',
        relativePath: 'Pictures/EasySave/',
      );
      final vidAsset1 = _asset(
        'vid3_a',
        'post3_1.mp4',
        'video/mp4',
        type: AssetType.video,
        relativePath: 'Pictures/EasySave/',
      );
      final vidAsset2 = _asset(
        'vid3_b',
        'post3_1.mov',
        'video/quicktime',
        type: AssetType.video,
        relativePath: 'Pictures/EasySave/',
      );

      final imgProv = makeProv(
        assetId: 'aid-img-3',
        sourceId: 'post3',
        itemIndex: 1,
      );

      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: [imgAsset, vidAsset1, vidAsset2],
        dbOverride: db,
        readHeader: (mediaId, mimeType) async {
          if (mediaId == 'img3') return makeJpeg(imgProv);
          return Uint8List(0);
        },
      );

      expect(result.created, 1);
      expect(result.skipped, 2);
      final records = await db.recent();
      expect(records.length, 1);
      expect(records.first.files.length, 1);
      expect(records.first.files.first.isImage, isTrue);
    });

    test('视频 XMP 与图片不符时不配对: does not pair when video XMP belongs to different post', () async {
      final imgAsset = _asset(
        'img4',
        'same_stem.jpg',
        'image/jpeg',
        relativePath: 'Pictures/EasySave/',
      );
      final vidAsset = _asset(
        'vid4',
        'same_stem.mp4',
        'video/mp4',
        type: AssetType.video,
        relativePath: 'Pictures/EasySave/',
      );

      final imgProv = makeProv(
        assetId: 'aid-img-4',
        sourceId: 'post_img',
        itemIndex: 1,
      );

      final vidProv = makeProv(
        assetId: 'aid-vid-4',
        sourceId: 'post_other',
        itemIndex: 1,
      );

      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: [imgAsset, vidAsset],
        dbOverride: db,
        readHeader: (mediaId, mimeType) async {
          if (mediaId == 'img4') return makeJpeg(imgProv);
          if (mediaId == 'vid4') return makeMp4(vidProv);
          return Uint8List(0);
        },
      );

      expect(result.created, 2);
      final records = await db.recent();
      expect(records.length, 2);
      final imgRec = records.firstWhere((r) => r.postId == 'post_img');
      final vidRec = records.firstWhere((r) => r.postId == 'post_other');
      expect(imgRec.files.length, 1);
      expect(imgRec.files.first.isImage, isTrue);
      expect(vidRec.files.length, 1);
      expect(vidRec.files.first.isImage, isFalse);
    });
  });
}
