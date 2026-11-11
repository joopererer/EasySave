import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/media_request.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/services/signed_parser_manifest.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(SiteRegistry.useBuiltin);
  tearDown(SiteRegistry.useBuiltin);
  final clock = DateTime.utc(2026, 10, 29);
  SiteDefinition site([String id = 'tiktok']) => SiteRegistry.current.byId(id)!;
  MediaRequestResource resource(
    String url, {
    Map<String, String> headers = const {},
    List<String> cookies = const [],
    DateTime? expiresAt,
    MediaResourceRole role = MediaResourceRole.video,
  }) => MediaRequestResource(
    role: role,
    url: url,
    request: MediaRequestRequirements(
      headers: headers,
      cookieDomains: cookies,
      expiresAt: expiresAt,
      transport: MediaTransport.session,
      resumable: false,
    ),
  );
  Matcher rejected(String code) =>
      throwsA(isA<MediaPolicyException>().having((e) => e.code, 'code', code));
  MediaRequestPolicy policy({
    MediaCookieReader? reader,
    MediaPolicyRejectionLogger? log,
    String id = 'tiktok',
  }) => MediaRequestPolicy(
    site(id),
    now: () => clock,
    readCookie: reader,
    logRejection: log ?? (_, _) {},
  );

  test('X video fixture keeps its poster and sends the declared Referer', () async {
    final fixture = jsonDecode(
      File('../spec/fixtures/x/video.expected.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final item = MediaItem.fromJson(
      (fixture['items'] as List).single as Map<String, dynamic>,
    );
    expect(item.posterUrl, isNotNull);
    expect(urlsFor(item).first, item.posterUrl);
    final poster = policy(id: 'x').resourcesFor(item).singleWhere(
      (r) => r.role == MediaResourceRole.poster,
    );
    expect(poster.url, item.posterUrl);
    expect(poster.request.headers['Referer'], 'https://x.com/');
    final authorized = await policy(id: 'x').authorize(poster);
    expect(authorized.wireHeaders['Referer'], 'https://x.com/');
  });

  test('video poster candidates never include video URLs or video fallbacks', () {
    final item = MediaItem(
      type: 'video',
      url: 'https://sns-video-zl.xhscdn.com/a.mp4',
      fallbacks: ['https://sns-video-bd.xhscdn.com/a.mp4'],
      posterUrl: 'https://sns-webpic-qc.xhscdn.com/cover.jpg',
    );
    expect(urlsFor(item), [item.posterUrl]);
    expect(urlsFor(MediaItem(type: 'video', url: item.url, fallbacks: item.fallbacks)), isEmpty);
    expect(urlsFor(MediaItem(type: 'video', url: item.url, posterUrl: item.url)), isEmpty);
    expect(urlsFor(MediaItem(type: 'video', url: 'https://example.test/cover.jpg', videoUrl: item.url)), ['https://example.test/cover.jpg']);
  });

  test('URL rejection identifies field and shape without leaking values', () {
    final lines = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      for (final (url, shape) in [
        ('', 'empty'),
        ('relative/path?secret=hidden', 'relative'),
        ('//example.test/path?secret=hidden', 'protocol-relative'),
        ('file:///secret', 'scheme=file'),
      ]) {
        expect(
          () => MediaRequestPolicy(site()).resourcesFor(
            MediaItem(type: 'image', url: url),
          ),
          rejected('REQUEST_URL_REJECTED'),
        );
        expect(lines.last, contains('field=url shape=$shape'));
        expect(lines.last, contains('itemType=image'));
        expect(lines.last, isNot(contains('secret')));
      }
    } finally {
      debugPrint = original;
    }
  });

  test(
    'rejects non-HTTPS, userinfo, malformed URLs, spoofed domains and public suffix targets',
    () {
      final p = policy();
      for (final url in [
        'http://v16-webapp-prime.tiktok.com/a',
        'https://user:secret@www.tiktok.com/a',
        'https://@www.tiktok.com/a',
        'file:///a',
        'not a URL',
      ]) {
        expect(
          () => p.validate(resource(url)),
          rejected('REQUEST_URL_REJECTED'),
        );
      }
      for (final host in [
        'tiktok.com.evil.com',
        'eviltiktok.com',
        'com',
        'co.uk',
        'com.cn',
        'tiktok.com.co.uk',
        'instagram.com',
        '127.0.0.1',
      ]) {
        expect(
          () => p.validate(resource('https://$host/path?token=private')),
          rejected('REQUEST_HOST_REJECTED'),
        );
      }
      for (final host in [
        'tiktok.com',
        'www.tiktok.com',
        'v16-webapp-prime.tiktok.com',
        'v19-webapp-prime.tiktok.com',
        'p16-common-sign.tiktokcdn-eu.com',
        'p77-sg.tiktokcdn.com',
        'lf16-cdn-tos.tiktokcdn-us.com',
      ]) {
        expect(p.validate(resource('https://$host/a')).host, host);
      }
    },
  );

  test(
    'header whitelist is case-insensitive, canonicalizes names and rejects all control values',
    () {
      final p = policy();
      for (final key in [
        'Cookie',
        'Authorization',
        'Host',
        'Accept',
        'Content-Length',
        'Referer ',
        'Range\r\nCookie',
      ]) {
        expect(
          () => p.validate(
            resource('https://www.tiktok.com/a', headers: {key: 'secret'}),
          ),
          rejected('REQUEST_HEADER_REJECTED'),
        );
      }
      for (final key in ['Referer', 'Origin', 'User-Agent', 'Range']) {
        for (final value in ['good\rbad', 'good\nbad', 'good\u0000bad']) {
          expect(
            () => p.validate(
              resource('https://www.tiktok.com/a', headers: {key: value}),
            ),
            rejected('REQUEST_HEADER_REJECTED'),
          );
        }
      }
      expect(
        () => p.validate(
          resource(
            'https://www.tiktok.com/a',
            headers: {'Range': 'bytes=0-', 'range': 'bytes=1-'},
          ),
        ),
        rejected('REQUEST_HEADER_REJECTED'),
      );
    },
  );

  test(
    'uses only actual media URLs for cookies and refreshes or discards cookies on every redirect',
    () async {
      final lookups = <Uri>[];
      final p = policy(
        reader: (uri) async {
          lookups.add(uri);
          return 'sessionid=fresh${lookups.length}';
        },
      );
      final first = await p.authorize(
        resource(
          'https://v16-webapp-prime.tiktok.com/one?token=not-logged',
          cookies: ['tiktok.com'],
          headers: {'range': 'bytes=0-', 'uSeR-aGeNt': 'test-UA'},
        ),
      );
      expect(first.headers['Range'], 'bytes=0-');
      expect(first.headers['User-Agent'], 'test-UA');
      expect(first.headers.containsKey('Cookie'), isFalse);
      expect(first.cookie, 'sessionid=fresh1');
      expect(first.wireHeaders['Cookie'], 'sessionid=fresh1');
      final next = await p.redirect(
        first,
        'https://v19-webapp-prime.tiktok.com/two',
      );
      expect(next.cookie, 'sessionid=fresh2');
      final sameHost = await p.redirect(next, '/three');
      expect(sameHost.cookie, 'sessionid=fresh3');
      final cdn = await p.redirect(
        sameHost,
        'https://p16-common-sign.tiktokcdn-eu.com/photo',
      );
      expect(cdn.cookie, isNull);
      expect(cdn.wireHeaders.containsKey('Cookie'), isFalse);
      expect(lookups.map((u) => u.path), ['/one', '/two', '/three']);
      final calls = lookups.length;
      await expectLater(
        p.redirect(first, 'https://instagram.com/private'),
        rejected('REQUEST_HOST_REJECTED'),
      );
      await expectLater(
        p.redirect(first, 'http://www.tiktok.com/private'),
        rejected('REQUEST_URL_REJECTED'),
      );
      expect(lookups.length, calls);
      expect(
        first.toString(),
        'AuthorizedMediaRequest host=v16-webapp-prime.tiktok.com',
      );
      expect(first.toString(), isNot(contains('token')));
    },
  );

  test(
    'ignores unauthorized cookie scopes and rejects malformed scopes without reading cookies',
    () async {
      var calls = 0;
      final p = policy(
        reader: (_) async {
          calls++;
          return 'never';
        },
      );
      for (final domain in [
        'com',
        '.tiktok.com',
      ]) {
        await expectLater(
          p.authorize(resource('https://www.tiktok.com/a', cookies: [domain])),
          rejected('REQUEST_COOKIE_DOMAIN_REJECTED'),
        );
      }
      for (final domain in ['co.uk', 'tiktok.com.evil.com', 'instagram.com', 'tiktokcdn.com']) {
        final authorized = await p.authorize(
          resource('https://www.tiktok.com/a', cookies: [domain]));
        expect(authorized.wireHeaders.containsKey('Cookie'), isFalse);
      }
      expect(calls, 0);
      await p.authorize(
        resource(
          'https://p16-common-sign.tiktokcdn-eu.com/a',
          cookies: ['tiktok.com'],
        ),
      );
      expect(calls, 0);
    },
  );

  test(
    'rejections and exceptions expose only a fixed code and hostname, never secrets or paths',
    () async {
      final events = <String>[];
      final p = policy(
        log: (code, host) => events.add('$code $host'),
        reader: (_) async => throw StateError(
          'Cookie=private-secret path=/private?token=secret',
        ),
      );
      try {
        await p.authorize(
          resource(
            'https://www.tiktok.com/private?token=secret',
            cookies: ['tiktok.com'],
          ),
        );
        fail('expected rejection');
      } on MediaPolicyException catch (e) {
        expect(e.toString(), 'REQUEST_COOKIE_READ_FAILED host=www.tiktok.com');
      }
      expect(events, ['REQUEST_COOKIE_READ_FAILED www.tiktok.com']);
      for (final bad in ['a\rb', 'a\nb', 'a\u0000b']) {
        await expectLater(
          policy(reader: (_) async => bad).authorize(
            resource('https://www.tiktok.com/a', cookies: ['tiktok.com']),
          ),
          rejected('REQUEST_COOKIE_REJECTED'),
        );
      }
    },
  );

  test(
    'expiry comes from requirements; arbitrary URL queries are not interpreted by Dart',
    () async {
      final p = policy();
      p.validate(resource('https://www.tiktok.com/a?expire=1&x-expires=2'));
      for (final expiry in [
        clock,
        clock.subtract(const Duration(seconds: 1)),
      ]) {
        expect(
          () => p.validate(
            resource('https://www.tiktok.com/a', expiresAt: expiry),
          ),
          rejected('REQUEST_EXPIRED'),
        );
      }
      p.validate(
        resource(
          'https://www.tiktok.com/a',
          expiresAt: clock.add(const Duration(seconds: 1)),
        ),
      );
      var now = clock.subtract(const Duration(seconds: 1));
      final delayed = MediaRequestPolicy(
        site(),
        now: () => now,
        logRejection: (_, _) {},
        readCookie: (_) async {
          now = clock;
          return 'sessionid=safe';
        },
      );
      await expectLater(
        delayed.authorize(
          resource(
            'https://www.tiktok.com/a',
            cookies: ['tiktok.com'],
            expiresAt: clock,
          ),
        ),
        rejected('REQUEST_EXPIRED'),
      );
    },
  );

  test(
    'adapter maps every legacy role, and rejects unauthorized fallbacks or incomplete declarations',
    () {
      final p = policy();
      final item = MediaItem(
        type: 'image',
        url: 'https://p16-common-sign.tiktokcdn-eu.com/image',
        videoUrl: 'https://v16-webapp-prime.tiktok.com/motion',
        posterUrl: 'https://p77-sg.tiktokcdn.com/poster',
        fallbacks: ['https://p77-sg.tiktokcdn.com/backup'],
      );
      final resources = p.resourcesFor(item);
      expect(resources.map((r) => r.role), [
        MediaResourceRole.image,
        MediaResourceRole.motion,
        MediaResourceRole.poster,
        MediaResourceRole.fallback,
      ]);
      expect(resources[0].request.cookieDomains, isEmpty);
      expect(resources[0].request.transport, MediaTransport.background);
      expect(resources[0].request.resumable, isTrue);
      expect(resources[1].request.cookieDomains, ['tiktok.com']);
      expect(resources[1].request.transport, MediaTransport.session);
      expect(resources[3].fallbackFor, MediaResourceRole.image);
      expect(
        () => p.resourcesFor(
          MediaItem(
            type: 'image',
            url: item.url,
            fallbacks: ['https://tiktok.com.evil.com/backup'],
          ),
        ),
        rejected('REQUEST_HOST_REJECTED'),
      );
      expect(
        () => p.resourcesFor(
          MediaItem(type: 'image', url: item.url, requestResources: []),
        ),
        rejected('REQUEST_RESOURCE_MISMATCH'),
      );
      final explicit = MediaItem.fromJson({
        ...item.toJson(),
        'resources': resources.map((r) => r.toJson()).toList(),
      });
      expect(p.resourcesFor(explicit).length, 4);
      // Preserve legacy/history/backup JSON; requirements are separate from it.
      expect(explicit.toJson(), item.toJson());
      expect(explicit.toJson().containsKey('resources'), isFalse);
    },
  );

  test(
    'per-resource JSON rejects malformed roles/requirements with fixed errors',
    () {
      for (final value in [
        {'role': 'script', 'url': 'https://private/path?secret', 'request': {}},
        {'role': 'fallback', 'url': 'https://private/path', 'request': {}},
        {
          'role': 'image',
          'url': 'https://private/path',
          'request': {
            'headers': {},
            'cookieDomains': [],
            'resumable': true,
            'transport': 'background',
            'expiresAt': 'not a time',
          },
        },
      ]) {
        expect(
          () => MediaRequestResource.fromJson(value),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'Dart manifest validation rejects widened role cookies and malicious role headers',
    () {
      final parser = File('assets/parser/parser.js').readAsBytesSync();
      final schema =
          jsonDecode(
                File(
                  'assets/parser/sites-manifest.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final original = File(
        'assets/parser/builtin-manifest.json',
      ).readAsStringSync();
      for (final invalid in [
        {
          'cookieDomains': ['com'],
        },
        {
          'cookieDomains': ['instagram.com'],
        },
        {
          'headers': {'Cookie': 'private'},
        },
        {
          'headers': {'Referer': 'bad\r\nvalue'},
        },
      ]) {
        final value = jsonDecode(original) as Map<String, dynamic>;
        final tiktok = (value['sites'] as List).cast<Map>().firstWhere(
          (s) => s['id'] == 'tiktok',
        );
        tiktok['download']['resourceDefaults']['image'] = invalid;
        expect(
          () => SignedParserManifest.fromBuiltin(
            jsonEncode(value),
            parser,
            schema,
          ),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'ALL successful four-site fixture outputs from the current parser pass the Dart policy',
    () async {
      final output = await Process.run(
        Platform.isWindows ? 'node.exe' : 'node',
        ['../extension/scripts/export_request_policy_fixtures.js'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(output.exitCode, 0);
      final corpus = jsonDecode(output.stdout as String) as List;
      final counts = <String, int>{};
      var checked = 0;
      for (final raw in corpus.cast<Map>()) {
        final id = raw['id'] as String;
        final p = policy(id: id);
        counts[id] = (counts[id] ?? 0) + 1;
        for (final json in (raw['data']['items'] as List).cast<Map>()) {
          var item = MediaItem.fromJson(json.cast<String, dynamic>());
          if (id == 'tiktok') {
            // Original host was deliberately removed by existing sanitization.
            // First prove placeholders are NOT authorized in the production config.
            expect(
              () => p.resourcesFor(item),
              rejected('REQUEST_HOST_REJECTED'),
            );
            String actualHost(String url) {
              final uri = Uri.parse(url);
              expect(uri.host, 'media.example');
              return uri
                  .replace(
                    host: uri.path.endsWith('.jpg')
                        ? 'p16-common-sign.tiktokcdn-eu.com'
                        : 'v16-webapp-prime.tiktok.com',
                  )
                  .toString();
            }

            final adapted = item.toJson();
            for (final key in ['url', 'videoUrl', 'posterUrl']) {
              if (adapted[key] is String) {
                adapted[key] = actualHost(adapted[key] as String);
              }
            }
            if (adapted['fallbacks'] is List) {
              adapted['fallbacks'] = (adapted['fallbacks'] as List)
                  .cast<String>()
                  .map(actualHost)
                  .toList();
            }
            adapted['resources'] = [
              for (final r in item.requestResources!)
                r.atUrl(actualHost(r.url)).toJson(),
            ];
            item = MediaItem.fromJson(adapted);
          }
          checked += p.resourcesFor(item).length;
        }
      }
      expect(counts.keys, containsAll(['xhs', 'instagram', 'x', 'tiktok']));
      expect(checked, greaterThan(30));
    },
  );
}
