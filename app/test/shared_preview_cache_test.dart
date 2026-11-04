import 'package:easysave/services/shared_preview_cache.dart';
import 'package:easysave/services/auth.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Dart RAM cache uses canonical identity, aliases, short TTL and capacity',
    () {
      var now = DateTime(2026);
      final cache = SharedParseCache<String>(now: () => now, capacity: 2);
      cache.put('xhs:123', 'post', aliases: ['short']);
      expect(cache.get('short'), 'post');
      expect(cache.get('xhs:123'), 'post');
      cache.put('x:1', 'x');
      cache.put('instagram:1', 'ig');
      expect(cache.get('short'), isNull);
      now = now.add(const Duration(seconds: 46));
      expect(cache.get('x:1'), isNull);
    },
  );
  test(
    'foreground consumes an in-memory handoff without opening a parser WebView',
    () async {
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sharedPreviewChannel, (call) async {
            methods.add(call.method);
            return {
              'keys': ['xhs:abcdef'],
              'expires': DateTime.now()
                  .add(const Duration(seconds: 30))
                  .millisecondsSinceEpoch,
              'post': {
                'platform': 'xhs',
                'id': 'abcdef',
                'url': 'https://www.xiaohongshu.com/explore/abcdef',
                'author': {},
                'items': [],
              },
              'rawImages': [],
            };
          });
      final result = await parsePostOutcome(
        'https://www.xiaohongshu.com/explore/abcdef',
      );
      expect(result.data.id, 'abcdef');
      expect(methods, ['getParsed']);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sharedPreviewChannel, null);
    },
  );
  test('cookie presence logs only domain state transitions', () {
    expect(xhsCookiePresenceChanged('test.xhs', 'present'), isTrue);
    expect(xhsCookiePresenceChanged('test.xhs', 'present'), isFalse);
    expect(xhsCookiePresenceChanged('test.rednote', 'present'), isTrue);
    expect(xhsCookiePresenceChanged('test.xhs', 'absent'), isTrue);
  });
}
