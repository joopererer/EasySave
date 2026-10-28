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
  test(
    'legacy pairs are repaired before fixed media are enumerated and grouped',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      final locator = GalleryLocatorService.instance;
      locator.resetForTesting();
      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
        assets: [],
      );
      HistoryDb.resetInstanceForTesting();
      final db = await HistoryDb.instance(dbPath: ':memory:');
      await db.clear();
      const channel = MethodChannel('easysave/provenance_pair');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var repaired = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'repairLegacyNames') {
          expect((call.arguments['albums'] as List), contains('EasySave'));
          repaired = true;
          return [
            for (final index in [1, 3])
              {
                'file': '123_${index}_550e8400-e29b-41d4-a716-446655440000.jpg',
                'path': 'Download/EasySave/',
                'status': 'renamed',
                'target': '123_$index.jpg',
                'mediaId': '$index',
              },
          ];
        }
        if (call.method == 'queryFixedMedia') {
          expect(repaired, isTrue);
          return [
            for (final index in [1, 3])
              {
                'id': '$index',
                'title': '123_$index.jpg',
                'typeInt': 1,
                'mimeType': 'image/jpeg',
                'relativePath': 'Download/EasySave/',
              },
          ];
        }
        if (call.method == 'readSidecarDetailed') {
          final index = int.parse(call.arguments['mediaId'] as String);
          expect(call.arguments['filename'], '123_$index.jpg');
          return {
            'status': 'success',
            'found': true,
            'stage': 'sidecar-read',
            'xml': buildXmpXml(
              XmpProvenance(
                schema: '0.1',
                assetId: 'asset-$index',
                capturedAt: DateTime.utc(2026),
                metadataDate: DateTime.utc(2026),
                capturedBy: 'EasySave/1.9.0',
                platform: 'tiktok',
                sourceId: '123',
                sourceUrl: 'https://www.tiktok.com/@/video/123',
                itemIndex: index,
                itemCount: 6,
              ),
            ),
          };
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        locator.resetForTesting();
        HistoryDb.resetInstanceForTesting();
      });
      final result = await HistoryRebuildService.instance.rebuild(
        albums: {},
        dbOverride: db,
        readHeader: (_, _) async => Uint8List(0),
      );
      expect(result.renamedMedia, 2);
      expect(result.renameFailures, 0);
      expect(result.created, 1);
      expect((await db.recent()).single.files.map((f) => f.filename).toSet(), {
        '123_1.jpg',
        '123_3.jpg',
      });
    },
  );
}
