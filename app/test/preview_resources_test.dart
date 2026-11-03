import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/core/media_request.dart';
import 'package:easysave/services/preview_resources.dart';

void main() {
  final request = MediaRequestRequirements(
    transport: MediaTransport.background,
    resumable: false,
  );
  MediaRequestResource resource(
    MediaResourceRole role,
    String url, {
    MediaResourceRole? fallbackFor,
  }) => MediaRequestResource(
    role: role,
    url: url,
    request: request,
    fallbackFor: fallbackFor,
  );

  test('live still candidates never include motion or motion fallbacks', () {
    final resources = [
      resource(MediaResourceRole.image, 'https://image.test/still'),
      resource(MediaResourceRole.motion, 'https://video.test/motion'),
      resource(
        MediaResourceRole.fallback,
        'https://image.test/alternate',
        fallbackFor: MediaResourceRole.image,
      ),
      resource(
        MediaResourceRole.fallback,
        'https://video.test/alternate',
        fallbackFor: MediaResourceRole.motion,
      ),
    ];
    expect(
      previewImageCandidates(
        resources,
        'https://image.test/still',
      ).map((r) => r.url),
      ['https://image.test/still', 'https://image.test/alternate'],
    );
    expect(
      previewImageCandidates(resources, 'https://video.test/motion'),
      isEmpty,
    );
  });

  test('video poster candidates use only poster fallbacks', () {
    final resources = [
      resource(MediaResourceRole.poster, 'https://image.test/poster'),
      resource(
        MediaResourceRole.fallback,
        'https://image.test/alternate',
        fallbackFor: MediaResourceRole.poster,
      ),
      resource(
        MediaResourceRole.fallback,
        'https://image.test/still',
        fallbackFor: MediaResourceRole.image,
      ),
    ];
    expect(
      previewImageCandidates(resources, 'https://image.test/poster').length,
      2,
    );
    expect(previewImageCandidates(resources, null), isEmpty);
  });
}
