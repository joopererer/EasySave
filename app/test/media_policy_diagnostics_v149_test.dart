import 'package:easysave/core/models.dart';
import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('resource mismatch identifies declaration field and safe URL category', () {
    final lines = <String>[];
    final originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      final policy = MediaRequestPolicy(SiteRegistry.current.byId('instagram')!);
      const url = 'https://scontent.cdninstagram.com/media?private=NO_LOG';
      final source = MediaItem(type: 'image', url: url,
          thumbnailUrl: 'https://scontent.cdninstagram.com/small?private=NO_LOG');
      final resources = policy.resourcesFor(source);
      expect(() => policy.resourcesFor(MediaItem(type: 'image', url: url,
          requestResources: resources)), throwsA(isA<MediaPolicyException>()
          .having((e) => e.code, 'code', 'REQUEST_RESOURCE_MISMATCH')));
      expect(lines.last, contains('field=resources.count shape=scheme=https'));
      expect(lines.last, contains('hostClass=media'));
      expect(lines.last, isNot(contains('NO_LOG')));
      expect(lines.last, isNot(contains('?private')));
    } finally {
      debugPrint = originalPrint;
    }
  });
}
