import 'package:easysave/core/media_request.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/preview_video.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'video preview authorizes the actual media URL and only declared cookies',
    () async {
      final calls = <Uri>[];
      final policy = MediaRequestPolicy(
        SiteRegistry.current.byId('tiktok')!,
        readCookie: (uri) async {
          calls.add(uri);
          return 'fixture=FAKE';
        },
        logRejection: (_, _) {},
      );
      final request = MediaRequestResource(
        role: MediaResourceRole.video,
        url: 'https://v16-webapp-prime.tiktok.com/video?token=fixture',
        request: MediaRequestRequirements(
          headers: const {},
          cookieDomains: const ['tiktok.com'],
          transport: MediaTransport.session,
          resumable: false,
        ),
      );
      final authorized = await policy.authorize(request);
      expect(calls.single.toString(), request.url);
      expect(authorized.wireHeaders['Cookie'], 'fixture=FAKE');
      expect(authorized.headers['Referer'], 'https://www.tiktok.com/');
    },
  );

  for (final platform in ['xhs', 'x', 'instagram']) {
    test('$platform preview declaration has no Cookie scope', () {
      final site = SiteRegistry.current.byId(platform)!;
      final policy = MediaRequestPolicy(site, logRejection: (_, _) {});
      final download = site.data['download'] as Map;
      final host =
          ((download['mediaHosts'] as List).first as Map)['domain'] as String;
      final item = policy.resourcesFor(
        MediaItem(type: 'video', url: 'https://media.$host/file.mp4'),
      );
      expect(item.single.request.cookieDomains, isEmpty);
    });
  }

  test('policy rejection has a fixed user-facing message', () {
    expect(
      previewFailureMessage(
        const MediaPolicyException('REQUEST_HOST_REJECTED', 'evil.com'),
        'tiktok',
      ),
      '该资源地址不在允许范围内',
    );
    expect(previewPlaybackError('tiktok'), contains('请下载后观看'));
  });
}
