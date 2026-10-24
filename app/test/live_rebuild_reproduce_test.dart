// Copyright 2026 EasySave. All rights reserved.
// Reproduction test for Live Photo rebuild failure (Combinations a, b, c).

import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_rebuild_service.dart';
import 'package:easysave/widgets/history_cards.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:provenance_dart/provenance_dart.dart';
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
  late Uint8List baseJpeg;
  late Uint8List baseMp4;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('easysave_live_reproduce');
    tempDbPath = '${tempDir.path}/live_${DateTime.now().microsecondsSinceEpoch}.db';
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: tempDbPath);

    final vectors = '${Directory.current.path}/../docs/provenance-spec/test-vectors';
    final jpegFixture = File('$vectors/no-metadata.jpg');
    final mp4Fixture = File('$vectors/mp4-no-xmp.mp4');
    expect(jpegFixture.existsSync(), isTrue, reason: 'JPEG test vector not found');
    expect(mp4Fixture.existsSync(), isTrue, reason: 'MP4 test vector not found');

    baseJpeg = jpegFixture.readAsBytesSync();
    baseMp4 = mp4Fixture.readAsBytesSync();
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
    try {
      final file = File(tempDbPath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  });

  XmpProvenance makeProv({
    required String assetId,
    required String sourceId,
    required int itemIndex,
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
        itemCount: 2,
        pairId: pairId,
        capturedAt: DateTime(2026, 10, 24, 10, 0, 0),
        capturedBy: 'EasySave/1.8.2',
        metadataDate: DateTime(2026, 10, 24, 10, 0, 0),
      );

  group('Live Photo 重建测试 (组合 a, b, c)', () {
    test('组合 c: 新下载的帖子，图片和视频 pairId 一致 (2 项 Live 图)', () async {
      final sourceId = 'note_comb_c';

      // Item 1
      final img1Prov = makeProv(
        assetId: 'aid-c-img1',
        sourceId: sourceId,
        itemIndex: 1,
        pairId: '$sourceId#1',
      );
      final vid1Prov = makeProv(
        assetId: 'aid-c-vid1',
        sourceId: sourceId,
        itemIndex: 1,
        pairId: '$sourceId#1',
      );

      // Item 2
      final img2Prov = makeProv(
        assetId: 'aid-c-img2',
        sourceId: sourceId,
        itemIndex: 2,
        pairId: '$sourceId#2',
      );
      final vid2Prov = makeProv(
        assetId: 'aid-c-vid2',
        sourceId: sourceId,
        itemIndex: 2,
        pairId: '$sourceId#2',
      );

      final img1Bytes = writeJpegXmp(baseJpeg, img1Prov);
      final vid1Bytes = writeMp4Xmp(baseMp4, vid1Prov);
      final img2Bytes = writeJpegXmp(baseJpeg, img2Prov);
      final vid2Bytes = writeMp4Xmp(baseMp4, vid2Prov);

      final assets = [
        _asset('c_img1', 'xhs_c_1.jpg', 'image/jpeg'),
        _asset('c_vid1', 'xhs_c_1.mp4', 'video/mp4', type: AssetType.video),
        _asset('c_img2', 'xhs_c_2.jpg', 'image/jpeg'),
        _asset('c_vid2', 'xhs_c_2.mp4', 'video/mp4', type: AssetType.video),
      ];

      final fileBytes = <String, Uint8List>{
        'c_img1': img1Bytes,
        'c_vid1': vid1Bytes,
        'c_img2': img2Bytes,
        'c_vid2': vid2Bytes,
      };

      // 走真实的解析和重建代码路径
      final result = await HistoryRebuildService.instance.rebuild(
        assetsOverride: assets,
        dbOverride: db,
        readHeader: (mediaId, mimeType) async => fileBytes[mediaId] ?? Uint8List(0),
      );

      expect(result.created, 1);
      final record = await db.getByPostId(sourceId);
      expect(record, isNotNull);

      // 界面使用的媒体信息
      final post = record!.toPost();

      // 断言：每个序号只有一项 (共 2 项，而非拆成 4 项)
      expect(post.items.length, 2, reason: '每个序号应只有一项，2 项 Live 图不应拆成 4 项');

      // 第一项: itemIndex 1
      final item1 = post.items[0];
      expect(item1.type, 'live', reason: '第 1 项应被标记为 Live');
      expect(item1.url.toLowerCase(), endsWith('.jpg'), reason: '图片地址应为图片类型');
      expect(item1.videoUrl, isNotNull);
      expect(item1.videoUrl!.toLowerCase(), endsWith('.mp4'), reason: '视频媒体地址应为视频类型');

      // 第二项: itemIndex 2
      final item2 = post.items[1];
      expect(item2.type, 'live', reason: '第 2 项应被标记为 Live');
      expect(item2.url.toLowerCase(), endsWith('.jpg'), reason: '图片地址应为图片类型');
      expect(item2.videoUrl, isNotNull);
      expect(item2.videoUrl!.toLowerCase(), endsWith('.mp4'), reason: '视频媒体地址应为视频类型');

      // 封面与标记检查
      expect(coverItemFor(record)?.type, 'live');
      expect(postKindLabel(record), 'Live 图');
    });

    test('组合 a: 旧帖，图片无 pairId，补写后视频有 pairId', () async {
      final sourceId = 'note_comb_a';

      // Item 1: 图片无 pairId，视频有 pairId
      final img1Prov = makeProv(
        assetId: 'aid-a-img1',
        sourceId: sourceId,
        itemIndex: 1,
        pairId: null,
      );
      final vid1Prov = makeProv(
        assetId: 'aid-a-vid1',
        sourceId: sourceId,
        itemIndex: 1,
        pairId: '$sourceId#1',
      );

      final img1Bytes = writeJpegXmp(baseJpeg, img1Prov);
      final vid1Bytes = writeMp4Xmp(baseMp4, vid1Prov);

      final assets = [
        _asset('a_img1', 'xhs_a_1.jpg', 'image/jpeg'),
        _asset('a_vid1', 'xhs_a_1.mp4', 'video/mp4', type: AssetType.video),
      ];

      final fileBytes = <String, Uint8List>{
        'a_img1': img1Bytes,
        'a_vid1': vid1Bytes,
      };

      await HistoryRebuildService.instance.rebuild(
        assetsOverride: assets,
        dbOverride: db,
        readHeader: (mediaId, mimeType) async => fileBytes[mediaId] ?? Uint8List(0),
      );

      final record = await db.getByPostId(sourceId);
      expect(record, isNotNull);

      final post = record!.toPost();
      expect(post.items.length, 1, reason: '组合 a 应成功配成 1 项 Live 图');
      expect(post.items[0].type, 'live');
      expect(post.items[0].url.toLowerCase(), endsWith('.jpg'));
      expect(post.items[0].videoUrl?.toLowerCase(), endsWith('.mp4'));
    });

    test('组合 b: 图片无 pairId，视频无 pairId，sourceId 和 itemIndex 相同', () async {
      final sourceId = 'note_comb_b';

      // Item 1: 双方都无 pairId，文件名主干不同（例如不同后缀）
      final img1Prov = makeProv(
        assetId: 'aid-b-img1',
        sourceId: sourceId,
        itemIndex: 1,
        pairId: null,
      );
      final vid1Prov = makeProv(
        assetId: 'aid-b-vid1',
        sourceId: sourceId,
        itemIndex: 1,
        pairId: null,
      );

      final img1Bytes = writeJpegXmp(baseJpeg, img1Prov);
      final vid1Bytes = writeMp4Xmp(baseMp4, vid1Prov);

      // 主干不同：xhs_b_photo vs xhs_b_motion
      final assets = [
        _asset('b_img1', 'xhs_b_photo.jpg', 'image/jpeg'),
        _asset('b_vid1', 'xhs_b_motion.mp4', 'video/mp4', type: AssetType.video),
      ];

      final fileBytes = <String, Uint8List>{
        'b_img1': img1Bytes,
        'b_vid1': vid1Bytes,
      };

      await HistoryRebuildService.instance.rebuild(
        assetsOverride: assets,
        dbOverride: db,
        readHeader: (mediaId, mimeType) async => fileBytes[mediaId] ?? Uint8List(0),
      );

      final record = await db.getByPostId(sourceId);
      expect(record, isNotNull);

      final post = record!.toPost();
      expect(post.items.length, 1, reason: '组合 b 应成功配成 1 项 Live 图');
      expect(post.items[0].type, 'live');
      expect(post.items[0].url.toLowerCase(), endsWith('.jpg'));
      expect(post.items[0].videoUrl?.toLowerCase(), endsWith('.mp4'));
    });
  });
}
