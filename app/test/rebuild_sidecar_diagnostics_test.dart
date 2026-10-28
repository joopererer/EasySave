import 'dart:typed_data';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_rebuild_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('easysave/provenance_pair');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final locator = GalleryLocatorService.instance;
  const name1 =
      '7674898126922140959_1_d16e3f95-5dcb-43f4-b0dd-9cea903110b6.jpg';
  const name3 =
      '7674898126922140959_3_b799ce81-9b24-4e38-bbd7-9e2c98d7cff5.jpg';
  late HistoryDb db;
  var mode = 'success';
  var mime = 'image/jpeg';
  String xml(int index) => buildXmpXml(
    XmpProvenance(
      schema: '0.1',
      assetId: 'asset-$index',
      capturedAt: DateTime.utc(2026),
      metadataDate: DateTime.utc(2026),
      capturedBy: 'EasySave/1.9.0',
      platform: 'tiktok',
      sourceId: '7674898126922140959',
      sourceUrl: 'https://www.tiktok.com/@/video/7674898126922140959',
      itemIndex: index,
      itemCount: 6,
      aiLabel: 'Creator labeled as AI-generated',
      aiLabelSource: 'author',
    ),
  );
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mode = 'success';
    mime = 'image/jpeg';
    locator.resetForTesting();
    locator.setScannedForTesting(
      scanned: true,
      permission: PermissionState.authorized,
      assets: [],
    );
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: ':memory:');
    await db.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'queryFixedMedia')
        return [
          for (final entry in {'1': name1, '3': name3}.entries)
            {
              'id': entry.key,
              'title': entry.value,
              'typeInt': 1,
              'mimeType': mime,
              'relativePath': 'Download/EasySave/',
            },
          {
            'diagnostic': true,
            'stage': 'query-Files',
            'visible': true,
            'owned': false,
            'count': 2,
          },
        ];
      if (call.method == 'readSidecarDetailed') {
        final args = call.arguments as Map;
        expect(args['relativePath'], 'Download/EasySave/');
        expect(args['filename'], args['mediaId'] == '1' ? name1 : name3);
        if (mode == 'error')
          return {
            'status': 'error',
            'found': true,
            'stage': 'sidecar-read',
            'errorClass': 'SecurityException',
            'requiresAccess': true,
          };
        return {
          'status': 'success',
          'found': true,
          'stage': 'authorized-sidecar-read',
          'xml': mode == 'malformed'
              ? '<broken'
              : xml(int.parse(args['mediaId'] as String)),
        };
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
  });
  Future<RebuildResult> rebuild() => HistoryRebuildService.instance.rebuild(
    albums: {},
    dbOverride: db,
    readHeader: (_, _) async => Uint8List(0),
  );
  test(
    'UUID names and non-owned visible media group by XMP ID/index rather than filename',
    () async {
      final result = await rebuild();
      expect(result.created, 1);
      expect(result.readFailures, 0);
      final record = (await db.recent()).single;
      expect(record.files.map((f) => f.itemIndex).toSet(), {1, 3});
      expect(record.files.length, 2);
    },
  );
  test(
    'sidecar access errors are counted separately and request fixed directory authorization',
    () async {
      mode = 'error';
      final result = await rebuild();
      expect(result.created, 0);
      expect(result.readFailures, 2);
      expect(result.skipped, 0);
      expect(result.needsFixedDirectoryAccess, isTrue);
    },
  );
  test(
    'sidecar metadata restores unsupported embedded formats without reading the image header',
    () async {
      mime = 'image/heic';
      final result = await rebuild();
      expect(result.created, 1);
      expect(result.readFailures, 0);
    },
  );
  test(
    'invalid sidecar XML is a read/parse failure rather than silently absent provenance',
    () async {
      mode = 'malformed';
      final result = await rebuild();
      expect(result.readFailures, 2);
      expect(result.created, 0);
      expect(result.skipped, 0);
    },
  );
}
