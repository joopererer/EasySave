import 'dart:async';

import 'package:easysave/core/media_request.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers only the poster *diagnosis*: every case below fails before any
/// socket is opened, so the checks run offline.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MediaRequestResource resource(MediaResourceRole role, String url) =>
      MediaRequestResource(
        role: role,
        url: url,
        request: MediaRequestRequirements(
          headers: const {'Referer': 'https://www.tiktok.com/'},
          cookieDomains: const [],
          transport: MediaTransport.background,
          resumable: true,
        ),
      );

  Future<List<String>> loadAndCollectLogs(MediaItem item) async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    final provider = CdnImage(item, platform: 'tiktok');
    final stream = provider.resolve(ImageConfiguration.empty);
    final settled = Completer<void>();
    stream.addListener(
      ImageStreamListener(
        (image, synchronousCall) {
          if (!settled.isCompleted) settled.complete();
        },
        onError: (error, stack) {
          if (!settled.isCompleted) settled.complete();
        },
      ),
    );
    await settled.future.timeout(const Duration(seconds: 10));
    return lines;
  }

  test('a video result without a cover logs NO_COVER_DECLARED with host only',
      () async {
    SiteRegistry.useBuiltin();
    const url = 'https://v16-webapp.tiktokcdn.com/video.mp4?expire=1&x=2';
    final lines = await loadAndCollectLogs(
      MediaItem(
        type: 'video',
        url: url,
        videoUrl: url,
        requestResources: [resource(MediaResourceRole.video, url)],
      ),
    );
    final poster = lines.where((line) => line.contains('[PreviewPoster]'));
    expect(
      poster.any(
        (line) =>
            line.contains('reason=NO_COVER_DECLARED') &&
            line.contains('host=v16-webapp.tiktokcdn.com'),
      ),
      isTrue,
      reason: lines.join('\n'),
    );
    // Only the hostname may leave the widget: no path, no query.
    expect(poster.every((line) => !line.contains('/video.mp4')), isTrue);
    expect(poster.every((line) => !line.contains('expire=')), isTrue);
  });

  test('a cover host outside mediaHosts logs the policy code and host', () async {
    SiteRegistry.useBuiltin();
    const video = 'https://v16-webapp.tiktokcdn.com/video.mp4';
    const cover = 'https://covers.evil.example/poster.jpg?token=secret';
    final lines = await loadAndCollectLogs(
      MediaItem(
        type: 'video',
        url: video,
        videoUrl: video,
        posterUrl: cover,
        requestResources: [
          resource(MediaResourceRole.video, video),
          resource(MediaResourceRole.poster, cover),
        ],
      ),
    );
    final poster = lines.where((line) => line.contains('[PreviewPoster]'));
    expect(
      poster.any(
        (line) =>
            line.contains('reason=POLICY') &&
            line.contains('code=REQUEST_HOST_REJECTED') &&
            line.contains('host=covers.evil.example'),
      ),
      isTrue,
      reason: poster.join('\n'),
    );
    expect(poster.every((line) => !line.contains('token=secret')), isTrue);
  });
}
