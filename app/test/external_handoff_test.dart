import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/services/links.dart';
import 'package:easysave/services/seal.dart';
import 'package:easysave/services/site_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('easysave/seal');
  final calls = <MethodCall>[];
  var installed = true;
  setUp(() {
    calls.clear();
    installed = true;
    // External routes must continue working even when the site list is empty.
    SiteRegistry.activate([]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'isInstalled' ? installed : true;
        });
  });
  tearDown(() {
    SiteRegistry.useBuiltin();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  for (final entry in ['share', 'clipboard', 'bubble', 'input']) {
    test(
      '$entry sends external URL through installed local Seal handler without site parsing',
      () async {
        const text = '分享 https://youtu.be/abc123。';
        expect(extractLinks(text), isEmpty);
        expect(
          await routeExternalText(
            text,
            present: (url) async {
              expect(await isSealInstalled(), isTrue);
              await sendToSeal(url);
            },
          ),
          isTrue,
        );
        expect(calls.map((c) => c.method), ['isInstalled', 'send']);
        expect(calls.last.arguments, {'url': 'https://youtu.be/abc123'});
      },
    );
    test(
      '$entry offers guidance when local handler is absent, never starts the parser',
      () async {
        installed = false;
        var guidance = false;
        await routeExternalText(
          'youtube.com/watch?v=abc',
          present: (url) async {
            if (await isSealInstalled()) {
              await sendToSeal(url);
            } else {
              guidance = true;
            }
          },
        );
        expect(guidance, isTrue);
        expect(calls.map((c) => c.method), ['isInstalled']);
      },
    );
  }
  test(
    'unregistered Bilibili and spoofed or non-web URLs are not authorized for external handoff',
    () async {
      for (final text in [
        'https://www.bilibili.com/video/BV1xx411c7mD',
        'https://youtube.com.evil.test/watch?v=123',
        'https://user@youtube.com/watch?v=123',
        'ftp://youtube.com/watch?v=123',
      ]) {
        expect(
          await routeExternalText(
            text,
            present: (_) async => fail('No handler allowed'),
          ),
          isFalse,
        );
      }
      expect(
        () => sendToSeal('https://www.bilibili.com/video/BV1xx411c7mD'),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    },
  );
}
