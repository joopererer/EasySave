import 'dart:convert';
import 'dart:io';

import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/metadata/url_normalizer.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:easysave/services/history_backfill_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'fixtures/v110_metadata/builders_24fb900.dart' as legacy;

// Deliberately exclude only generated identity and write-time fields.
// publishedAt is deterministic input and is still compared.
Map<String, dynamic> fields(XmpProvenance value) => value.toXmpJson()
  ..remove('prov:assetId')
  ..remove('prov:capturedAt')
  ..remove('xmp:MetadataDate');

const urls = {
  'xhs':
      'https://www.xiaohongshu.com/explore/670f1a2b000000001e028b12?xsec_token=share-token&xsec_source=pc_feed',
  'instagram': 'https://www.instagram.com/p/Ddl1WWnGyCN/?igsh=share',
  'x': 'https://x.com/creator/status/1234567890123456789?s=20',
  'tiktok':
      'https://www.tiktok.com/@creator/video/1234567890123456789?is_from_webapp=1',
};

DownloadBatch batch(String platform, String type, String? authorId) =>
    DownloadBatch(
      batchId: 'metadata-comparison',
      album: 'EasySave',
      platform: platform,
      postId: '1234567890123456789',
      postUrl: urls[platform] ?? 'https://example.invalid/post/123',
      authorId: authorId,
      authorName: '作者 & <Creator>',
      title: '标题 <Title>',
      caption: List.filled(2100, '文').join(),
      aiLabel: '作者声明：含 AI 内容  ',
      aiLabelSource: 'author',
      publishedAt: DateTime.utc(2026, 10, 1, 12, 34),
      postItemCount: 5,
      itemsJson: jsonEncode([
        {
          'type': type == 'video' ? 'video' : 'image',
          'url': 'https://example.invalid/media',
          if (type == 'live') 'videoUrl': 'https://example.invalid/motion',
        },
      ]),
      jobs: [],
    );

HistoryRecord history(
  DownloadBatch b,
  String type, {
  bool missingItems = false,
}) => HistoryRecord(
  platform: b.platform,
  postId: b.postId,
  postUrl: b.postUrl,
  authorName: b.authorName,
  title: b.title,
  caption: b.caption,
  aiLabel: b.aiLabel,
  aiLabelSource: b.aiLabelSource,
  fileCount: type == 'live' ? 2 : 1,
  createdAt: DateTime.utc(2026, 10, 2),
  itemsJson: missingItems ? null : b.itemsJson,
  files: [
    HistoryFile(
      filename: 'image.jpg',
      savedAt: 1790899200000,
      itemIndex: 0,
      isImage: type != 'video',
    ),
    if (type == 'live')
      HistoryFile(
        filename: 'motion.mp4',
        savedAt: 1790899200000,
        itemIndex: 0,
        isImage: false,
      ),
  ],
);

AssetEntity asset(bool image) => AssetEntity(
  id: 'metadata-fixture',
  typeInt: (image ? AssetType.image : AssetType.video).index,
  width: 100,
  height: 100,
);

Future<void> compareWritten(
  XmpProvenance before,
  XmpProvenance after,
  bool image, {
  bool instagramException = false,
}) async {
  // Complete field-set equality catches additions, omissions and value changes.
  Map<String, dynamic> expected(XmpProvenance value) {
    final result = fields(value);
    if (instagramException) {
      expect(value.platform, 'instagram');
      expect(value.authorId, before.authorId);
      expect(result.remove('prov:authorId'), before.authorId);
    }
    return result;
  }

  expect(fields(after), expected(before));
  final dir = await Directory.systemTemp.createTemp('v110_metadata_');
  try {
    final name = image ? 'no-metadata.jpg' : 'mp4-no-xmp.mp4';
    final source = File('../docs/provenance-spec/test-vectors/$name');
    final oldFile = await source.copy('${dir.path}/before_$name');
    final newFile = await source.copy('${dir.path}/after_$name');
    await MetadataService.embedProvenance(
      filePath: oldFile.path,
      provenance: before,
    );
    await MetadataService.embedProvenance(
      filePath: newFile.path,
      provenance: after,
    );
    final oldRead = await MetadataService.readProvenance(oldFile.path);
    final newRead = await MetadataService.readProvenance(newFile.path);
    expect(oldRead, isNotNull);
    expect(newRead, isNotNull);
    expect(fields(newRead!), expected(oldRead!));
  } finally {
    await dir.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(SiteRegistry.useBuiltin);
  tearDown(SiteRegistry.useBuiltin);

  for (final platform in urls.keys) {
    for (final type in ['image', 'video', 'live']) {
      test('$platform $type: download and backfill match 24fb900', () async {
        final b = batch(
          platform,
          type,
          platform == 'xhs' ? 'opaque-author' : '0012345',
        );
        for (final image
            in type == 'live' ? [true, false] : [type == 'image']) {
          final pair = type == 'live' ? '${b.postId}#0' : null;
          await compareWritten(
            legacy.legacyBatchProvenance(b, itemIndex: 4, pairId: pair),
            provenanceForBatchItem(b, itemIndex: 4, pairId: pair),
            image,
          );
          final record = history(b, type);
          final file = record.files.firstWhere((f) => f.isImage == image);
          await compareWritten(
            legacy.legacyHistoryProvenance(record, file, asset(image))!,
            provenanceForHistoryFile(record, file, asset(image))!,
            image,
          );
        }
      });
    }
    for (final id in <String?>[
      null,
      '',
      '12345',
      '0012345',
      if (platform != 'instagram') ...['creator_name', ' 123 ', '-123', '１２３'],
    ]) {
      test("$platform authorId ${id ?? '<null>'} matches 24fb900", () {
        final b = batch(platform, 'image', id);
        expect(
          fields(provenanceForBatchItem(b, itemIndex: 2)),
          fields(legacy.legacyBatchProvenance(b, itemIndex: 2)),
        );
      });
    }
    for (final type in ['image', 'video', 'live']) {
      test('$platform missing items $type: backfill matches 24fb900', () {
        final record = history(
          batch(platform, type, null),
          type,
          missingItems: true,
        );
        for (final file in record.files) {
          expect(
            fields(
              provenanceForHistoryFile(record, file, asset(file.isImage))!,
            ),
            fields(
              legacy.legacyHistoryProvenance(
                record,
                file,
                asset(file.isImage),
              )!,
            ),
          );
        }
      });
    }
  }

  test(
    'ONLY approved exception: Instagram nonnumeric authorId was written before; now omitted',
    () async {
      for (final id in ['creator_name', ' 123 ', '-123', '１２３']) {
        final b = batch('instagram', 'image', id);
        final before = legacy.legacyBatchProvenance(b, itemIndex: 4);
        final after = provenanceForBatchItem(b, itemIndex: 4);
        expect(before.authorId, id);
        expect(after.authorId, isNull);
        // This exception removes exactly one known field from the old output.
        final expected = fields(before);
        expect(expected.remove('prov:authorId'), id);
        expect(fields(after), expected);
        await compareWritten(before, after, true, instagramException: true);
      }
    },
  );

  test(
    'active manifest controls credit, platform aliases and author rule in both writers',
    () {
      SiteRegistry.activate([
        {
          'id': 'future_site',
          'platform': 'future_provenance',
          'displayName': 'UI name',
          'creditName': 'Metadata credit',
          'enabled': false,
          'metadata': {'authorIdRule': 'opaque'},
        },
      ]);
      final b = batch('future_site', 'image', 'stable-opaque');
      final download = provenanceForBatchItem(b, itemIndex: 1);
      final record = history(b, 'image');
      final backfill = provenanceForHistoryFile(
        record,
        record.files.single,
        asset(true),
      )!;
      for (final value in [download, backfill]) {
        expect(value.platform, 'future_provenance');
        expect(value.credit, '作者 & <Creator> / Metadata credit');
      }
      expect(download.authorId, 'stable-opaque');
      expect(backfill.authorId, isNull); // history has no authorId evidence
      expect(toSpecPlatform('future_site'), 'future_provenance');
      expect(toAppPlatform('future_provenance'), 'future_site');
      expect(platformDisplayName('future_provenance'), 'Metadata credit');
      expect(toSpecPlatform('retired'), 'retired');
      expect(toAppPlatform('retired'), 'retired');
      expect(platformDisplayName('retired'), 'retired');
      SiteRegistry.activate([
        {
          'id': 'future_site',
          'platform': 'future_provenance',
          'displayName': 'UI name',
          'creditName': 'Changed credit',
          'metadata': {'authorIdRule': 'numeric'},
        },
      ]);
      expect(provenanceForBatchItem(b, itemIndex: 1).authorId, isNull);
      expect(
        provenanceForHistoryFile(
          record,
          record.files.single,
          asset(true),
        )!.credit,
        '作者 & <Creator> / Changed credit',
      );
    },
  );
}
