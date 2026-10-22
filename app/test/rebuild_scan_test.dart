// Copyright 2026 EasySave. All rights reserved.
// Task 4 (v1.7): the rebuild scan reads only the file headers.
//
// The scan used to copy every file out of the album (photo_manager
// `originFile`) and read it completely. It now asks the native side for the
// header bytes only, skips the formats it cannot parse and can be cancelled
// without losing what it already processed.

import 'dart:io';
import 'dart:typed_data';

import 'package:easysave/core/models.dart';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/history_rebuild_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AssetEntity _asset(String id, String title, String mimeType) => AssetEntity(
      id: id,
      typeInt: AssetType.image.index,
      width: 100,
      height: 100,
      title: title,
      mimeType: mimeType,
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
    final vectors = p.normalize(
      p.join(Directory.current.path, '..', 'docs', 'provenance-spec', 'test-vectors'),
    );
    final fixture = File(p.join(vectors, 'xhs-item3.jpg'));
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
}
