import 'dart:async';

import 'package:easysave/core/media_request.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'decoded-image cache cannot bypass an expired resource declaration',
    () async {
      const url = 'https://p16-common-sign.tiktokcdn-eu.com/photo.jpg';
      final item = MediaItem(
        type: 'image',
        url: url,
        requestResources: [
          MediaRequestResource(
            role: MediaResourceRole.image,
            url: url,
            request: MediaRequestRequirements(
              headers: const {},
              cookieDomains: const [],
              expiresAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
              transport: MediaTransport.background,
              resumable: true,
            ),
          ),
        ],
      );
      final provider = CdnImage(item, platform: 'tiktok');
      final pending = Completer<ImageInfo>();
      PaintingBinding.instance.imageCache.putIfAbsent(
        provider,
        () => OneFrameImageStreamCompleter(pending.future),
      );
      expect(PaintingBinding.instance.imageCache.containsKey(provider), isTrue);
      await expectLater(
        provider.obtainKey(ImageConfiguration.empty),
        throwsA(
          isA<MediaPolicyException>().having(
            (e) => e.code,
            'code',
            'REQUEST_EXPIRED',
          ),
        ),
      );
      PaintingBinding.instance.imageCache.evict(provider);
    },
  );
}
