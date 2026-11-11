import 'package:easysave/core/media_request.dart';
import 'package:easysave/services/authorized_media_http.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  MediaRequestResource request(String url) => MediaRequestResource(
    role: MediaResourceRole.video,
    url: url,
    request: MediaRequestRequirements(
      headers: const {},
      cookieDomains: const ['tiktok.com'],
      transport: MediaTransport.session,
      resumable: false,
    ),
  );

  test('each redirected request is authorized and Cookie is re-read', () async {
    final lookups = <Uri>[];
    final policy = MediaRequestPolicy(
      SiteRegistry.current.byId('tiktok')!,
      readCookie: (uri) async {
        lookups.add(uri);
        return 'session=hop${lookups.length}';
      },
      logRejection: (_, _) {},
    );
    final requests = <http.Request>[];
    final client = MockClient((r) async {
      requests.add(r);
      expect(r.followRedirects, false);
      if (requests.length == 1) {
        return http.Response('', 302, headers: {'location': '/two'});
      }
      return http.Response('ok', 200);
    });
    final response = await sendAuthorizedMediaGet(
      client,
      policy,
      request('https://www.tiktok.com/one'),
    );
    expect(await response.stream.bytesToString(), 'ok');
    expect(requests.map((r) => r.headers['Cookie']), [
      'session=hop1',
      'session=hop2',
    ]);
    expect(lookups.map((u) => u.path), ['/one', '/two']);
  });

  test('cross-domain redirect is rejected before any second request', () async {
    final events = <String>[];
    var requests = 0;
    final policy = MediaRequestPolicy(
      SiteRegistry.current.byId('tiktok')!,
      readCookie: (_) async => 'secret=never-forward',
      logRejection: (code, host) => events.add('$code host=$host'),
    );
    final client = MockClient((_) async {
      requests++;
      return http.Response(
        '',
        302,
        headers: {
          'location': 'https://tiktok.com.evil.com/private?token=secret',
        },
      );
    });
    await expectLater(
      sendAuthorizedMediaGet(
        client,
        policy,
        request('https://www.tiktok.com/start'),
      ),
      throwsA(
        isA<MediaPolicyException>().having(
          (e) => e.code,
          'code',
          'REQUEST_HOST_REJECTED',
        ),
      ),
    );
    expect(requests, 1);
    expect(events, ['REQUEST_HOST_REJECTED host=tiktok.com.evil.com']);
  });
}
