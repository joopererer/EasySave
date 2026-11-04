import 'package:easysave/core/dev_log.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('easysave/dev_log');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'export' ? '/external/v16dl.log' : null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'foreground and background Dart diagnostics use the native writer channel',
    () async {
      await Future.wait([
        for (final source in ['Foreground', 'Background', 'Preview'])
          for (var i = 0; i < 40; i++)
            DevLog.write(source, 'record=$i\ncomplete'),
      ]);
      expect(calls, hasLength(120));
      for (final call in calls) {
        expect(call.method, 'append');
        expect(
          call.arguments,
          matches(
            r'^\[INFO\] \[(Foreground|Background|Preview)\] record=\d+\\ncomplete\n$',
          ),
        );
      }
    },
  );

  test(
    'channel payload is redacted and export and clear use the same writer',
    () async {
      await DevLog.write('Test', 'Cookie: web_session=SECRET; a1=OTHER');
      expect(calls.single.arguments, isNot(contains('SECRET')));
      expect(calls.single.arguments, isNot(contains('OTHER')));
      expect(await DevLog.exportToExternal(), '/external/v16dl.log');
      await DevLog.clear();
      expect(calls.map((call) => call.method), ['append', 'export', 'clear']);
    },
  );
}
