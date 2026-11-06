import 'dart:async';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/shared_preview_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('five canonical variants share one network parse and release failed flights', () async {
    var calls = 0;
    final network = Completer<ParseOutcome>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sharedPreviewChannel, (call) async =>
            call.method == 'lookupParsed' ? {'status': 'miss'} : null);
    final parser = CachedPostParser(parseNetwork: (_, _) {
      calls++;
      return network.future;
    });
    final tasks = [for (var i = 0; i < 5; i++)
      parser.parse('https://www.instagram.com/p/SingleFlight/?dlrf=$i')];
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    for (final task in tasks) { expect(identical(task, tasks.first), isTrue); }
    network.complete(ParseOutcome(data: ParsedPost(platform: 'instagram', id: 'SingleFlight',
        url: 'https://www.instagram.com/p/SingleFlight/', author: PostAuthor(),
        items: [MediaItem(type: 'image', url: 'https://scontent.cdninstagram.com/still.jpg')]), rawImages: []));
    await Future.wait(tasks);
    var failures = 0;
    final failing = CachedPostParser(parseNetwork: (_, _) async {
      failures++;
      throw StateError('synthetic');
    });
    for (var i = 0; i < 2; i++) {
      await expectLater(failing.parse('https://www.instagram.com/p/SingleFlight/'), throwsStateError);
    }
    expect(failures, 2);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sharedPreviewChannel, null);
  });
}
