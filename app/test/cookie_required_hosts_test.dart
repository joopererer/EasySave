import 'dart:convert';

import 'package:easysave/core/media_request.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SiteDefinition siteWithRequiredHost() {
    final data = jsonDecode(jsonEncode(SiteRegistry.current.byId('tiktok')!.data))
        as Map<String, dynamic>;
    (data['download'] as Map)['cookieRequiredHosts'] = [
      {'domain': 'v16-webapp-prime.tiktok.com', 'includeSubdomains': false},
    ];
    return SiteDefinition(data);
  }

  MediaRequestResource resource(String host, List<String> scope) =>
      MediaRequestResource(
        role: MediaResourceRole.video,
        url: 'https://$host/private.mp4?token=PRIVATE_QUERY',
        request: MediaRequestRequirements(
          headers: const {},
          cookieDomains: scope,
          transport: MediaTransport.session,
          resumable: false,
        ),
      );

  test('an explicitly required cookie host rejects an absent scope before reading cookies', () async {
    var reads = 0;
    final policy = MediaRequestPolicy(siteWithRequiredHost(), readCookie: (_) async {
      reads++;
      return 'synthetic=unused';
    }, logRejection: (_, _) {});
    await expectLater(policy.authorize(resource('v16-webapp-prime.tiktok.com', [])),
        throwsA(isA<MediaPolicyException>().having((error) => error.code,
            'code', 'REQUEST_COOKIE_DOMAIN_REJECTED')));
    expect(reads, 0);
  });

  test('a required host inside its allowed scope remains authorized', () async {
    var reads = 0;
    final policy = MediaRequestPolicy(siteWithRequiredHost(), readCookie: (_) async {
      reads++;
      return 'synthetic=fresh';
    });
    final authorized = await policy.authorize(
        resource('v16-webapp-prime.tiktok.com', ['tiktok.com']));
    expect(authorized.wireHeaders['Cookie'], 'synthetic=fresh');
    expect(reads, 1);
  });

  test('old XHS task cookie scopes outside the current allowlist are stripped', () async {
    var reads = 0;
    final policy = MediaRequestPolicy(SiteRegistry.current.byId('xhs')!,
        readCookie: (_) async { reads++; return 'PRIVATE_COOKIE'; },
        logRejection: (_, _) {});
    final authorized = await policy.authorize(resource('ci.xiaohongshu.com',
        ['xiaohongshu.com', 'rednote.com']));
    expect(authorized.wireHeaders.containsKey('Cookie'), isFalse);
    expect(reads, 0);
  });

  test('the explicit required-host rule does not reject a different allowed host', () async {
    var reads = 0;
    final policy = MediaRequestPolicy(siteWithRequiredHost(), readCookie: (_) async {
      reads++;
      throw StateError('must not consult a jar outside scope');
    });
    final authorized = await policy.authorize(
        resource('v19-webapp-prime.tiktok.com', []));
    expect(authorized.cookie, isNull);
    expect(authorized.wireHeaders.containsKey('Cookie'), isFalse);
    expect(reads, 0);
  });

  for (final entry in {
    'www.tiktok.com': 'site_media',
    'p16-common-sign.tiktokcdn-eu.com': 'cdn_media',
  }.entries) {
    test('outside-scope ${entry.value} strips cookies and logs only the host category', () async {
      var reads = 0;
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = previous);
      final policy = MediaRequestPolicy(siteWithRequiredHost(), readCookie: (_) async {
        reads++;
        return 'PRIVATE_COOKIE';
      });
      final request = resource(entry.key,
          entry.value == 'cdn_media' ? ['tiktok.com'] : []);
      final authorized = await policy.authorize(request);
      expect(authorized.cookie, isNull);
      expect(authorized.wireHeaders.containsKey('Cookie'), isFalse);
      expect(reads, 0);
      final stripped = logs.where((line) => line.contains('REQUEST_COOKIE_STRIPPED')).toList();
      expect(stripped, ['[INFO] [RequestPolicy] REQUEST_COOKIE_STRIPPED host=${entry.value}']);
      expect(logs.join('\n'), isNot(contains(entry.key)));
      expect(logs.join('\n'), isNot(contains('PRIVATE')));
      expect(logs.join('\n'), isNot(contains('private.mp4')));
    });
  }
}
