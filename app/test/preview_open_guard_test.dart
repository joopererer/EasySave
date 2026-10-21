// Copyright 2026 EasySave. All rights reserved.
// Task 2 (v1.7): the shared "open this link" dedup decision.
//
// Every entry (bubble, share, clipboard, input box, batch) asks
// PreviewOpenGuard.decide(); these tests pin down the three outcomes and the
// inputs the decision is based on (real page stack + history records).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/preview_open_guard.dart';
import 'package:easysave/services/preview_route_observer.dart';

const _xhsUrl = 'https://www.xiaohongshu.com/explore/6612ab34cd56ef7890123456';
const _xhsId = '6612ab34cd56ef7890123456';
const _otherUrl = 'https://www.instagram.com/p/CxYzAbCdEfG/';

Route<void> _previewRoute(String postId) => MaterialPageRoute<void>(
      settings: RouteSettings(name: kPreviewRouteName, arguments: postId),
      builder: (_) => const SizedBox.shrink(),
    );

Route<void> _homeRoute() => MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/'),
      builder: (_) => const SizedBox.shrink(),
    );

void main() {
  late String tempDbPath;
  late HistoryDb db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final tempDir = await Directory.systemTemp.createTemp('easysave_guard');
    tempDbPath =
        '${tempDir.path}/guard_${DateTime.now().microsecondsSinceEpoch}.db';
    HistoryDb.resetInstanceForTesting();
    db = await HistoryDb.instance(dbPath: tempDbPath);
    PreviewRouteObserver.instance.reset();
    PreviewRouteObserver.instance.didPush(_homeRoute(), null);
  });

  tearDown(() async {
    PreviewRouteObserver.instance.reset();
    HistoryDb.resetInstanceForTesting();
    try {
      final file = File(tempDbPath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Ignore cleanup errors
    }
  });

  Future<HistoryRecord> seedRecord({
    String postId = _xhsId,
    String postUrl = _xhsUrl,
  }) async {
    await db.upsert(
      HistoryRecord(
        platform: 'xhs',
        postId: postId,
        postUrl: postUrl,
        fileCount: 1,
        createdAt: DateTime.now(),
        files: [HistoryFile(filename: '___.jpg', savedAt: 0)],
      ),
    );
    return (await db.getByPostId(postId))!;
  }

  group('PreviewOpenGuard.decide', () {
    test('skips when the top page is already this post preview', () async {
      PreviewRouteObserver.instance.didPush(_previewRoute(_xhsId), null);

      final decision =
          await PreviewOpenGuard.decide(entry: 'bubble', link: _xhsUrl, db: db);

      expect(decision.action, PreviewOpenAction.skipAlreadyOnPreview);
      expect(decision.postId, _xhsId);
      expect(decision.currentPreviewPostId, _xhsId);
      expect(decision.entry, 'bubble');
    });

    test('parses fresh once the preview page has been left', () async {
      final route = _previewRoute(_xhsId);
      PreviewRouteObserver.instance.didPush(route, null);
      PreviewRouteObserver.instance.didPop(route, null);

      final decision =
          await PreviewOpenGuard.decide(entry: 'bubble', link: _xhsUrl, db: db);

      expect(decision.action, PreviewOpenAction.parseFresh);
      expect(decision.currentPreviewPostId, isNull);
    });

    test('parses fresh when another post preview is on top', () async {
      PreviewRouteObserver.instance.didPush(_previewRoute('someotherpost'), null);

      final decision =
          await PreviewOpenGuard.decide(entry: 'bubble', link: _xhsUrl, db: db);

      expect(decision.action, PreviewOpenAction.parseFresh);
      expect(decision.currentPreviewPostId, 'someotherpost');
    });

    test('opens the cached preview when the post is in history', () async {
      final record = await seedRecord();

      final decision =
          await PreviewOpenGuard.decide(entry: 'bubble', link: _xhsUrl, db: db);

      expect(decision.action, PreviewOpenAction.openCached);
      expect(decision.cachedRecord?.id, record.id);
    });

    test('ignores soft-deleted records', () async {
      final record = await seedRecord();
      await db.delete(record.id!);

      final decision =
          await PreviewOpenGuard.decide(entry: 'bubble', link: _xhsUrl, db: db);

      expect(decision.action, PreviewOpenAction.parseFresh);
    });

    test('matches a record stored under the same canonical link', () async {
      // Short links keep no post id, so the fallback compares canonical links.
      await seedRecord(
        postId: 'shortlinkpost',
        postUrl: 'https://xhslink.com/a/AbCdEf',
      );

      final decision = await PreviewOpenGuard.decide(
        entry: 'share',
        link: 'https://xhslink.com/a/AbCdEf?share_from=user',
        db: db,
        resolveShortLinks: false,
      );

      expect(decision.action, PreviewOpenAction.openCached);
      expect(decision.entry, 'share');
    });

    test('a popup over the preview keeps the skip decision', () async {
      PreviewRouteObserver.instance.didPush(_previewRoute(_xhsId), null);
      // A dialog / bottom sheet on top of the preview does not mean the user
      // left the preview.
      PreviewRouteObserver.instance.didPush(_FakePopupRoute(), null);

      final decision =
          await PreviewOpenGuard.decide(entry: 'bubble', link: _xhsUrl, db: db);

      expect(decision.action, PreviewOpenAction.skipAlreadyOnPreview);
    });
  });

  group('PreviewOpenGuard.isTopPreview', () {
    test('true only for the post shown by the top preview page', () {
      PreviewRouteObserver.instance.didPush(_previewRoute(_xhsId), null);

      expect(PreviewOpenGuard.isTopPreview(_xhsId), isTrue);
      expect(PreviewOpenGuard.isTopPreview(_otherUrl), isFalse);
      expect(PreviewOpenGuard.isTopPreview(null), isFalse);
    });

    test('false when no preview page is open', () {
      expect(PreviewOpenGuard.isTopPreview(_xhsId), isFalse);
    });
  });
}

/// Popup route (dialog / sheet) placeholder: no barrier, no animation.
class _FakePopupRoute extends PopupRoute<void> {
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      const SizedBox.shrink();
}
