import 'dart:convert';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/gallery_locator_service.dart';
import 'package:easysave/services/history_db.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final locator = GalleryLocatorService.instance;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const photos = MethodChannel('com.fluttercandies/photo_manager');
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() {
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
    messenger.setMockMethodCallHandler(
      photos,
      (call) async => call.method == 'getPermissionState'
          ? PermissionState.authorized.index
          : null,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(photos, null);
    locator.resetForTesting();
    HistoryDb.resetInstanceForTesting();
  });

  test(
    'unchanged permission emits no notification that can restart refresh',
    () async {
      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
      );
      var notifications = 0;
      void listener() => notifications++;
      locator.addListener(listener);
      try {
        for (var i = 0; i < 4; i++) {
          await locator.checkPermission();
        }
        expect(notifications, 0);
      } finally {
        locator.removeListener(listener);
      }
    },
  );

  test(
    'unresolved preload cannot recursively schedule another history read',
    () async {
      locator.setScannedForTesting(
        scanned: true,
        permission: PermissionState.authorized,
      );
      final records = [
        HistoryRecord(
          platform: 'xhs',
          postId: 'missing-post',
          postUrl: 'https://example.test/missing-post',
          fileCount: 1,
          createdAt: DateTime(2026),
          files: [
            HistoryFile(
              filename: 'missing.jpg',
              savedAt: 1,
              itemIndex: 1,
              mediaId: 'missing',
            ),
          ],
        ),
      ];
      var refreshes = 0;
      final triggered = <Future<void>>[];
      void listener() {
        refreshes++;
        if (refreshes < 5) triggered.add(locator.preloadMediaIds(records));
      }

      locator.addListener(listener);
      try {
        await locator.preloadMediaIds(records);
        while (triggered.isNotEmpty) {
          await Future.wait(triggered.toList());
          triggered.clear();
        }
        expect(refreshes, 0);
      } finally {
        locator.removeListener(listener);
      }
    },
  );

  test(
    'opening identical parsed metadata repeatedly does not notify history',
    () async {
      final db = await HistoryDb.instance(dbPath: ':memory:');
      await db.clear();
      final item = MediaItem(type: 'image', url: 'https://img.example/1.jpg');
      final post = ParsedPost(
        platform: 'xhs',
        id: 'same-post',
        url: 'https://example.test/same-post',
        author: PostAuthor(name: 'Author'),
        items: [item],
      );
      await db.upsert(
        HistoryRecord(
          platform: post.platform,
          postId: post.id,
          postUrl: post.url,
          authorName: post.author.name,
          fileCount: 0,
          createdAt: DateTime(2026),
          itemsJson: jsonEncode([item.toJson()]),
        ),
      );
      var notifications = 0;
      void listener() => notifications++;
      db.addListener(listener);
      try {
        for (var i = 0; i < 4; i++) {
          await db.mergeParsedPost(post);
        }
        expect(notifications, 0);
        expect((await db.getByPostId(post.id))!.createdAt, DateTime(2026));
      } finally {
        db.removeListener(listener);
      }
    },
  );
}
