// Copyright 2026 EasySave. All rights reserved.
//
// Regression coverage for the duplicated history file row that made the first
// item of a saved post appear twice.
//
// Real evidence from a device backup (build 12) — one Instagram post with four
// images stored five rows: an inferred 0-based row sharing the physical file of
// item 1 (no prov:assetId, savedAt = record.createdAt, i.e. about two seconds
// before the real write) next to the 1-based row written with the provenance.
// Everything below is a database-level check: no album file is touched.

import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/app_version.dart';
import 'package:easysave/services/backup/backup_model.dart';
import 'package:easysave/services/backup/backup_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _postId = 'DfE4G_WiP52';
const _postUrl = 'https://www.instagram.com/p/DfE4G_WiP52/';
final _createdAt = DateTime.fromMillisecondsSinceEpoch(1793325917000);
final _realWrite = DateTime.fromMillisecondsSinceEpoch(1793325919000);

void main() {
  late String tempDbPath;
  late Directory tempDir;
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('easysave_row_repair_');
    tempDbPath =
        '${tempDir.path}/history_${DateTime.now().microsecondsSinceEpoch}.db';
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: tempDbPath);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    HistoryDb.resetInstanceForTesting();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// The saved rows exactly as the four images were recorded (1-based, with the
  /// provenance values that were written into the files).
  List<HistoryFile> savedRows() => [
    HistoryFile(
      filename: '${_postId}_1.jpg',
      savedAt: _realWrite.millisecondsSinceEpoch,
      mediaId: '76514',
      itemIndex: 1,
      isImage: true,
      assetId: '7bd50820-6e68-4236-8d59-eb55dd16ec58',
      relativePath: 'Pictures/EasySave/',
      itemCount: 4,
      capturedBy: 'EasySave/1.10.0',
    ),
    HistoryFile(
      filename: '${_postId}_2.jpg',
      savedAt: _realWrite.millisecondsSinceEpoch,
      mediaId: '76511',
      itemIndex: 2,
      isImage: true,
      assetId: 'bea7cdd1-5c4d-4b5c-b96c-149ac0b130e1',
      relativePath: 'Pictures/EasySave/',
      itemCount: 4,
      capturedBy: 'EasySave/1.10.0',
    ),
    HistoryFile(
      filename: '${_postId}_3.jpg',
      savedAt: _realWrite.millisecondsSinceEpoch,
      mediaId: '76513',
      itemIndex: 3,
      isImage: true,
      assetId: '79774745-730f-44e2-a520-a286ce49cc08',
      relativePath: 'Pictures/EasySave/',
      itemCount: 4,
      capturedBy: 'EasySave/1.10.0',
    ),
    HistoryFile(
      filename: '${_postId}_4.jpg',
      savedAt: _realWrite.millisecondsSinceEpoch,
      mediaId: '76512',
      itemIndex: 4,
      isImage: true,
      assetId: '7506498c-e300-4636-8d06-40ed15dae11b',
      relativePath: 'Pictures/EasySave/',
      itemCount: 4,
      capturedBy: 'EasySave/1.10.0',
    ),
  ];

  /// The stray row found on the device: same album file as item 1, 0-based
  /// index, no provenance, savedAt pinned to the record creation time.
  HistoryFile strayRow() => HistoryFile(
    filename: '${_postId}_1.jpg',
    savedAt: _createdAt.millisecondsSinceEpoch,
    mediaId: '76514',
    itemIndex: 0,
    isImage: true,
    relativePath: 'Pictures/EasySave/',
  );

  HistoryRecord recordWith(List<HistoryFile> files) => HistoryRecord(
    platform: 'instagram',
    postId: _postId,
    authorName: 'hannamimiimi',
    caption: 'A you here?)',
    postUrl: _postUrl,
    fileCount: files.length,
    createdAt: _createdAt,
    itemsJson: jsonEncode([
      for (var i = 0; i < 4; i++) {'type': 'image', 'url': 'https://cdn/$i.jpg'},
    ]),
    files: files,
  );

  /// Write the damaged `files_json` straight into the database (the way the
  /// old inference path left it), so the repair path is what gets exercised.
  Future<void> writeDamagedRow() async {
    await db.upsert(recordWith([savedRows().first]));
    final damaged = [
      {
        'filename': '${_postId}_1.jpg',
        'saved_at': _createdAt.millisecondsSinceEpoch,
        'media_id': '76514',
        'status': 'unknown',
        'item_index': 0,
        'is_image': 1,
        'asset_id': null,
        'relative_path': 'Pictures/EasySave/',
      },
      for (final f in savedRows()) f.toMap(),
    ];
    final raw = await databaseFactory.openDatabase(
      tempDbPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await raw.update(
        'history_records',
        {'files_json': jsonEncode(damaged)},
        where: 'post_id = ?',
        whereArgs: [_postId],
      );
    } finally {
      await raw.close();
    }
  }

  Future<List<dynamic>> storedFilesJson() async {
    final raw = await databaseFactory.openDatabase(
      tempDbPath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      final rows = await raw.query(
        'history_records',
        columns: ['files_json'],
        where: 'post_id = ?',
        whereArgs: [_postId],
      );
      return jsonDecode(rows.first['files_json'] as String) as List;
    } finally {
      await raw.close();
    }
  }

  group('itemIndex is always 1-based', () {
    test('inferred files from items_json start at 1', () {
      final inferred = inferHistoryFiles(
        postId: _postId,
        authorName: 'hannamimiimi',
        createdAt: _createdAt,
        itemsJson: jsonEncode([
          for (var i = 0; i < 4; i++)
            {'type': 'image', 'url': 'https://cdn/$i.jpg'},
        ]),
      );
      expect(inferred.map((f) => f.itemIndex), [1, 2, 3, 4]);
    });

    test('upsert refuses an index below 1 before touching the database',
        () async {
      await expectLater(
        db.upsert(recordWith([strayRow(), ...savedRows().skip(1)])),
        throwsArgumentError,
      );
      expect(await db.getByPostId(_postId), isNull);
    });

    test('updateFiles refuses an index below 1', () async {
      await db.upsert(recordWith([savedRows().first]));
      final stored = await db.getByPostId(_postId);
      await expectLater(
        db.updateFiles(stored!.id!, [strayRow()]),
        throwsArgumentError,
      );
    });
  });

  group('repairHistoryFiles', () {
    test('is a no-op for a healthy list', () {
      expect(repairHistoryFiles(savedRows()), isNull);
    });

    test('collapses a duplicated mediaId, keeping the 1-based assetId row', () {
      final repaired = repairHistoryFiles([strayRow(), ...savedRows()])!;
      expect(repaired, hasLength(4));
      expect(repaired.map((f) => f.itemIndex), [1, 2, 3, 4]);
      final first = repaired.first;
      expect(first.itemIndex, 1);
      expect(first.assetId, '7bd50820-6e68-4236-8d59-eb55dd16ec58');
      expect(first.savedAt, _realWrite.millisecondsSinceEpoch);
    });

    test('a fully 0-based legacy set is shifted to 1-based', () {
      final legacy = [
        HistoryFile(filename: 'a.jpg', savedAt: 1, mediaId: 'm1', itemIndex: 0),
        HistoryFile(filename: 'b.jpg', savedAt: 1, mediaId: 'm2', itemIndex: 1),
      ];
      final repaired = repairHistoryFiles(legacy)!;
      expect(repaired.map((f) => f.itemIndex), [1, 2]);
    });
  });

  group('a stored record is corrected on the next load', () {
    test('concurrent and repeated loads persist exactly one repair', () async {
      await writeDamagedRow();
      final lines = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      try {
        await Future.wait([db.recent(), db.recent(), db.recent()]);
        await db.recent();
        final repairs = lines.where((line) => line.contains('file rows repaired')).toList();
        expect(repairs, hasLength(1));
        expect(repairs.single, contains('deleted=1'));
        expect(repairs.single, contains('updated=1 committed=1 verified=1'));
        expect(await storedFilesJson(), hasLength(4));
      } finally {
        debugPrint = original;
      }
    });

    test('gallery scan cannot persist duplicate media IDs', () async {
      await db.upsert(recordWith(savedRows()));
      final stored = (await db.getByPostId(_postId))!;
      final duplicate = savedRows().first.copyWith(itemIndex: 5);
      await db.updateFiles(stored.id!, [...savedRows(), duplicate], source: 'gallery-scan');
      expect(await storedFilesJson(), hasLength(4));
      expect(historyFilesNeedRepair(jsonEncode(await storedFilesJson())), isFalse);
      await db.recent();
      expect(await storedFilesJson(), hasLength(4));
    });

    test('stale gallery scan preserves files saved after its snapshot', () async {
      await db.upsert(recordWith(savedRows().take(2).toList()));
      final stale = (await db.getByPostId(_postId))!;
      final more = [
        for (var i = 5; i <= 11; i++)
          savedRows().first.copyWith(
            filename: '${_postId}_$i.jpg',
            mediaId: '$i',
            itemIndex: i,
          ),
      ];
      await db.upsert(recordWith([...savedRows(), ...more]));
      final scanned = [
        for (final file in stale.files) file.copyWith(status: FileStatus.found),
      ];
      final merged = await db.syncScannedFiles(stale.id!, stale.files, scanned);
      expect(merged, hasLength(11));
      expect(merged.take(2).every((file) => file.status == FileStatus.found), isTrue);
      final persisted = await storedFilesJson();
      expect(persisted, hasLength(11));
      expect(historyFilesNeedRepair(jsonEncode(persisted)), isFalse);
    });

    test('stale scan cannot replace a newer media id for the same item', () async {
      await db.upsert(recordWith(savedRows().take(1).toList()));
      final stale = (await db.getByPostId(_postId))!;
      await db.upsert(recordWith([
        stale.files.single.copyWith(mediaId: 'new-id'),
      ]));
      final merged = await db.syncScannedFiles(stale.id!, stale.files, [
        stale.files.single.copyWith(mediaId: 'old-scan-id', status: FileStatus.found),
      ]);
      expect(merged.single.mediaId, 'new-id');
    });

    test('scan cannot assign an already claimed media id to another row', () async {
      await db.upsert(recordWith(savedRows().take(2).toList()));
      final record = (await db.getByPostId(_postId))!;
      final merged = await db.syncScannedFiles(record.id!, record.files, [
        record.files.first,
        record.files.last.copyWith(mediaId: record.files.first.mediaId, status: FileStatus.found),
      ]);
      expect(merged, hasLength(2));
      expect(merged.last.mediaId, record.files.last.mediaId);
      expect(historyFilesNeedRepair(jsonEncode([for (final f in merged) f.toMap()])), isFalse);
    });

    test('getByPostId repairs the row in the database', () async {
      await writeDamagedRow();
      expect((await storedFilesJson()), hasLength(5));

      final stored = await db.getByPostId(_postId);
      expect(stored!.files, hasLength(4));
      expect(stored.files.map((f) => f.itemIndex), [1, 2, 3, 4]);
      expect(stored.files.first.assetId, '7bd50820-6e68-4236-8d59-eb55dd16ec58');

      final persisted = await storedFilesJson();
      expect(persisted, hasLength(4));
      expect((persisted.first as Map)['item_index'], 1);
      expect(
        persisted.map((row) => (row as Map)['item_index']),
        [1, 2, 3, 4],
      );
    });

    test('recent() repairs the row in the database', () async {
      await writeDamagedRow();

      final records = await db.recent();
      final record = records.firstWhere((r) => r.postId == _postId);
      expect(record.files, hasLength(4));
      await db.settleRepairs();
      expect(await storedFilesJson(), hasLength(4));
    });
  });

  group('backup provenance reports stored values only', () {
    Future<Map<String, dynamic>> exportPost() async {
      final settings = await AppSettings.load();
      final json = await BackupService.exportBackup(db: db, settings: settings);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return (decoded['posts'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((p) => p['sourceId'] == _postId);
    }

    test('recorded itemCount and capturedBy are exported verbatim', () async {
      await db.upsert(recordWith(savedRows()));

      final post = await exportPost();
      final files = (post['files'] as List).cast<Map<String, dynamic>>();
      expect(files, hasLength(4));

      final provenance = files.first['provenance'] as Map<String, dynamic>?;
      expect(provenance, isNotNull);
      expect(provenance!['capturedBy'], 'EasySave/1.10.0');
      final source = provenance['source'] as Map<String, dynamic>;
      expect(source['itemIndex'], 1);
      expect(source['itemCount'], 4);
      expect(source['itemCount'], isNot(5));
    });

    test('the hard-coded 1.8.0 writer is gone from the export', () async {
      await db.upsert(recordWith(savedRows()));
      final settings = await AppSettings.load();
      final json = await BackupService.exportBackup(db: db, settings: settings);
      expect(json.contains('EasySave/1.8.0'), isFalse);
    });

    test('fields are omitted when the file carries no stored value', () async {
      await db.upsert(recordWith([
        HistoryFile(
          filename: '${_postId}_1.jpg',
          savedAt: _realWrite.millisecondsSinceEpoch,
          mediaId: '76514',
          itemIndex: 1,
          assetId: 'asset-1',
        ),
        HistoryFile(
          filename: '${_postId}_2.jpg',
          savedAt: _realWrite.millisecondsSinceEpoch,
          mediaId: '76511',
          itemIndex: 2,
          assetId: 'asset-2',
        ),
      ]));

      final post = await exportPost();
      final provenance =
          ((post['files'] as List).first as Map)['provenance'] as Map?;
      expect(provenance, isNotNull);
      expect(provenance!.containsKey('capturedBy'), isFalse);
      final source = provenance['source'] as Map;
      expect(source.containsKey('itemCount'), isFalse);
      expect(source['itemIndex'], 1);
    });

    test('the backup header reports the real app version', () {
      expect(BackupData.currentAppVersion, AppVersion.defaultVersion);
      expect(BackupData.currentAppVersion, isNot('1.8.0'));
    });
  });
}
