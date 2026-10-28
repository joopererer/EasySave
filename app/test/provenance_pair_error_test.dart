import 'dart:io';
import 'package:easysave/services/provenance_pair.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native step details reach Dart and failed saves retain private retry files', () async {
    final dir = await Directory.systemTemp.createTemp('pair_error_');
    addTearDown(() => dir.delete(recursive: true));
    final image = await File('../docs/provenance-spec/test-vectors/no-metadata.jpg').copy('${dir.path}/photo.jpg');
    await File('${image.path}.xmp').writeAsString('<xmp/>');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const pair = MethodChannel('easysave/provenance_pair');
    const gal = MethodChannel('gal');
    messenger.setMockMethodCallHandler(gal, (_) async => true);
    messenger.setMockMethodCallHandler(pair, (_) async => throw PlatformException(
      code: 'provenance_pair', message: '创建边车: IllegalArgumentException: invalid MIME'));
    addTearDown(() {
      messenger.setMockMethodCallHandler(gal, null);
      messenger.setMockMethodCallHandler(pair, null);
    });
    await expectLater(saveProvenancePair(image.path), throwsA(isA<PlatformException>()
      .having((e) => e.message, 'detailed task error', '创建边车: IllegalArgumentException: invalid MIME')));
    expect(await image.exists(), isTrue);
    expect(await File('${image.path}.xmp').exists(), isTrue);
  });
}
