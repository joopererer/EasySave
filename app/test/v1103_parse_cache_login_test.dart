// v1.10.3: the parsed RAM cache must not outlive a site's login state, and it
// must never store an answer that is a failure or a placeholder. The device
// symptom was an Instagram link parsed before login (a cover from the login
// wall) being reused after login because `ParseCache event=hit` answered first.
import 'dart:async';

import 'package:easysave/core/models.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Harness {
  _Harness() : channel = MethodChannel('test/v1103-parse-cache') {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      switch (call.method) {
        case 'lookupParsed':
          final value = posts.values
              .where((value) => (value['keys'] as List).contains(args['key']))
              .firstOrNull;
          if (value == null) return {'status': 'miss'};
          return {'status': 'hit', 'value': value};
        case 'putParsed':
          posts[args['canonical'] as String] = args;
          return null;
        case 'clearParsed':
          cleared.add(args['site'] as String);
          posts.removeWhere((_, value) => value['site'] == args['site']);
          return null;
      }
      return null;
    });
  }

  final MethodChannel channel;
  final posts = <String, Map<String, dynamic>>{};
  final cleared = <String>[];
  var network = <String>[];
  var degraded = false;
  Future<void> Function(String url)? duringParse;
  Object? failure;

  static const xhsUrl = 'https://www.xiaohongshu.com/explore/abc123';
  static const instagramUrl = 'https://www.instagram.com/p/AbC123/';

  /// A media URL the site's own request policy accepts, so a cache hit is not
  /// discarded as expired while the test is about the cache itself.
  static String mediaUrl(String url) => url.contains('instagram')
      ? 'https://s1.cdninstagram.com/one.jpg'
      : 'https://sns-img.xhscdn.com/one.jpg';

  CachedPostParser engine() => CachedPostParser(
    channel: channel,
    parseNetwork: (url, entry) async {
      network.add(url);
      await duringParse?.call(url);
      if (failure != null) throw failure!;
      return ParseOutcome(
        data: ParsedPost(
          platform: url.contains('instagram') ? 'instagram' : 'xhs',
          id: url.contains('instagram') ? 'AbC123' : 'abc123',
          url: url,
          author: PostAuthor(),
          items: [MediaItem(type: 'image', url: mediaUrl(url))],
        ),
        rawImages: const [],
        degraded: degraded,
      );
    },
  );

  void close() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a login change drops only that site from the shared cache', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final engine = harness.engine();
    await engine.parse(_Harness.xhsUrl, entry: 'app_input');
    await engine.parse(_Harness.instagramUrl, entry: 'app_input');
    expect(harness.network, hasLength(2));

    await engine.invalidateSite('instagram');
    expect(harness.cleared, ['instagram']);
    expect(
      harness.posts.values.map((value) => value['site']).toSet(),
      {'xhs'},
    );

    // The untouched site still answers from the cache.
    await engine.parse(_Harness.xhsUrl, entry: 'app_input');
    expect(harness.network, hasLength(2));
    // The signed-in-or-out site has to parse again.
    await engine.parse(_Harness.instagramUrl, entry: 'app_input');
    expect(harness.network, hasLength(3));
  });

  test('a failure is not cached and the next attempt parses again', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    final engine = harness.engine();
    harness.failure = ParseFailure(ParseErrorCode.loginRequired, '需要登录');
    await expectLater(
      engine.parse(_Harness.instagramUrl, entry: 'app_input'),
      throwsA(isA<ParseFailure>()),
    );
    harness.failure = null;
    final outcome = await engine.parse(
      _Harness.instagramUrl,
      entry: 'app_input',
    );
    expect(outcome.data.id, 'AbC123');
    expect(harness.network, hasLength(2));
    expect(harness.posts, hasLength(1));
  });

  test('a placeholder answer is returned but never cached', () async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    final harness = _Harness();
    addTearDown(harness.close);
    harness.degraded = true;
    final engine = harness.engine();
    final first = await engine.parse(_Harness.instagramUrl, entry: 'app_input');
    expect(first.degraded, isTrue);
    expect(first.data.items, hasLength(1));
    expect(harness.posts, isEmpty);
    expect(lines.join('\n'), contains('event=degraded'));

    await engine.parse(_Harness.instagramUrl, entry: 'app_input');
    expect(harness.network, hasLength(2));
  });

  test(
    'a login change during a parse stops that answer from being published',
    () async {
      final harness = _Harness();
      addTearDown(harness.close);
      final engine = harness.engine();
      final started = Completer<void>();
      final release = Completer<void>();
      harness.duringParse = (_) async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final pending = engine.parse(_Harness.instagramUrl, entry: 'app_input');
      await started.future;
      await engine.invalidateSite('instagram');
      release.complete();
      final outcome = await pending;
      expect(outcome.data.id, 'AbC123');
      expect(harness.posts, isEmpty);

      harness.duringParse = null;
      await engine.parse(_Harness.instagramUrl, entry: 'app_input');
      expect(harness.network, hasLength(2));
    },
  );

  test('a forced refresh never answers from the cache', () async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    final harness = _Harness();
    addTearDown(harness.close);
    final engine = harness.engine();
    await engine.parse(_Harness.xhsUrl, entry: 'app_input');
    lines.clear();
    final refreshed = await engine.parse(
      _Harness.xhsUrl,
      entry: 'history_refresh',
      forceRefresh: true,
    );
    expect(refreshed.data.id, 'abc123');
    expect(harness.network, hasLength(2));
    expect(lines.join('\n'), isNot(contains('event=hit')));
    expect(lines.join('\n'), contains('event=miss'));
  });

  test('the local fallback cache is cleared with the shared one', () async {
    // No native handler at all: the engine keeps its own RAM store.
    final channel = MethodChannel('test/v1103-parse-cache/local-only');
    final engine = CachedPostParser(
      channel: channel,
      parseNetwork: (url, entry) async => ParseOutcome(
        data: ParsedPost(
          platform: 'instagram',
          id: 'AbC123',
          url: url,
          author: PostAuthor(),
          items: [
            MediaItem(
              type: 'image',
              url: 'https://s1.cdninstagram.com/one.jpg',
            ),
          ],
        ),
        rawImages: const [],
      ),
    );
    await engine.parse(_Harness.instagramUrl, entry: 'app_input');
    await engine.invalidateSite('instagram');
    final cached = await engine.lookup(engine.keyFor(_Harness.instagramUrl));
    expect(cached?['status'], 'miss');
    expect(sharedPreviewChannel, isNotNull);
  });
}
