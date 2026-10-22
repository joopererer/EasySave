// Copyright 2026 EasySave. All rights reserved.
// Task 4 (v1.7): the album list used by the rebuild scan.
//
// The album names must never be derived from file names (file names carry no
// album). They come from MediaStore (BUCKET_DISPLAY_NAME / RELATIVE_PATH) for
// the files the history has located, and from the album the user picked in
// the settings.

import 'dart:io';

import 'package:easysave/services/album_name_registry.dart';
import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late String tempDbPath;
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('easysave_album');
    tempDbPath =
        '${tempDir.path}/album_${DateTime.now().microsecondsSinceEpoch}.db';
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: tempDbPath);
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

  Future<void> seedFile(String postId, String mediaId) async {
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: postId,
        postUrl: 'https://www.xiaohongshu.com/explore/$postId',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            filename: '${postId}_1.jpg',
            savedAt: 0,
            mediaId: mediaId,
            itemIndex: 1,
          ),
        ],
      ),
    );
  }

  group('AppSettings album list', () {
    test('renaming the album appends and keeps the old one', () {
      final settings = AppSettings()..albumName = 'EasySave';
      settings.rememberAlbum(settings.albumName);
      settings.albumName = 'EasySave5';
      settings.rememberAlbum(settings.albumName);

      expect(settings.effectiveAlbumNames, containsAll(['EasySave', 'EasySave5']));
    });

    test('the same album is remembered only once', () {
      final settings = AppSettings()..albumName = 'EasySave';
      settings.rememberAlbum('EasySave');
      settings.rememberAlbum('easysave');
      settings.rememberAlbum('  EasySave ');

      expect(settings.effectiveAlbumNames, ['EasySave']);
    });

    test('an empty name is ignored', () {
      final settings = AppSettings()..albumName = 'EasySave';
      settings.rememberAlbum('   ');
      expect(settings.effectiveAlbumNames, ['EasySave']);
    });
  });

  group('AlbumNameRegistry.completeFromHistory', () {
    test('adds the album MediaStore reports for the located files', () async {
      await seedFile('post1', 'media1');
      await seedFile('post2', 'media2');

      final settings = AppSettings()..albumName = 'EasySave';
      final added = await AlbumNameRegistry.completeFromHistory(
        settings,
        db: db,
        queryAlbum: (mediaId) async => (
          album: mediaId == 'media1' ? 'EasySave' : 'EasySave5',
          relativePath: null,
        ),
      );

      expect(added, containsAll(['EasySave', 'EasySave5']));
      expect(settings.effectiveAlbumNames, containsAll(['EasySave', 'EasySave5']));
    });

    test('falls back to the first RELATIVE_PATH segment', () async {
      await seedFile('post1', 'media1');

      final settings = AppSettings()..albumName = 'EasySave';
      await AlbumNameRegistry.completeFromHistory(
        settings,
        db: db,
        queryAlbum: (mediaId) async => (
          album: null,
          relativePath: 'EasySave5/sub/',
        ),
      );

      expect(settings.effectiveAlbumNames, contains('EasySave5'));
    });

    test('a file without media id is skipped', () async {
      await db.upsert(
        HistoryRecord(
          platform: 'xhs',
          postId: 'noMedia',
          postUrl: 'https://www.xiaohongshu.com/explore/noMedia',
          fileCount: 1,
          createdAt: DateTime.now(),
          files: [HistoryFile(filename: 'noMedia_1.jpg', savedAt: 0)],
        ),
      );

      var queried = 0;
      final settings = AppSettings()..albumName = 'EasySave';
      await AlbumNameRegistry.completeFromHistory(
        settings,
        db: db,
        queryAlbum: (mediaId) async {
          queried++;
          return (album: 'EasySave', relativePath: null);
        },
      );

      expect(queried, 0);
    });

    test('an unknown album does not add anything', () async {
      await seedFile('post1', 'media1');

      final settings = AppSettings()..albumName = 'EasySave';
      final added = await AlbumNameRegistry.completeFromHistory(
        settings,
        db: db,
        queryAlbum: (mediaId) async => (album: null, relativePath: null),
      );

      expect(added, isEmpty);
      expect(settings.effectiveAlbumNames, ['EasySave']);
    });
  });
}
