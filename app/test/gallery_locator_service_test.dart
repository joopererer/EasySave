import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';

void main() {
  late String dbPath;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('easysave_locator');
    dbPath = p.join(directory.path, 'history.db');
    HistoryDb.resetInstanceForTesting();
    final db = await HistoryDb.instance(dbPath: dbPath);
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: 'deleted-post',
        postUrl: 'https://example.test/deleted-post',
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [
          HistoryFile(
            itemIndex: 1,
            filename: 'deleted-post_1.jpg',
            savedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      ),
    );
    final record = await db.getByPostId('deleted-post');
    await db.delete(record!.id!);
  });

  tearDown(() {
    HistoryDb.resetInstanceForTesting();
  });

  test('deleted history records are not reported as downloaded', () async {
    final post = ParsedPost(
      platform: 'xhs',
      id: 'deleted-post',
      url: 'https://example.test/deleted-post',
      author: PostAuthor(),
      items: [MediaItem(type: 'image', url: 'https://img.example/1.jpg')],
    );

    expect(
      await GalleryLocatorService.instance.findDownloadedIndices(post),
      isEmpty,
    );
  });

  test('a missing MediaStore asset is not reported as present', () async {
    expect(
      await GalleryLocatorService.instance.isPresent('missing-media-id'),
      isFalse,
    );
  });
}
