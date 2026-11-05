import 'package:easysave/services/ai_label_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('IgAiProbe console bridge accepts only safe field diagnostics', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    logUnknownAiLabel(
      'EasySaveIgAiProbe:{"path":"\u0024.ai_label","name":"ai_label","type":"string","value":"AI_CREATED"}',
    );
    logUnknownAiLabel(
      'EasySaveIgAiProbe:{"path":"\u0024.user.ai_label","name":"ai_label","type":"string","value":"PRIVATE"}',
    );
    logUnknownAiLabel(
      'EasySaveIgAiProbe:{"path":"\u0024.ai_label","name":"ai_label","type":"string","value":"https://private.example/?token=PRIVATE"}',
    );
    logUnknownAiLabel(
      'EasySaveIgAiProbe:{"path":"\u0024.caption","name":"caption","type":"string","value":"PRIVATE"}',
    );
    logUnknownAiLabel(
      'EasySaveIgAiProbe:{"path":"\u0024.ai_label","name":"ai_label","type":"string","value":"AI_CREATED","extra":"PRIVATE"}',
    );
    logUnknownAiLabel(
      'EasySaveIgAiProbe:{"path":"\u0024.c2pa_token","name":"c2pa_token","type":"string","value":"PRIVATE_TOKEN"}',
    );
    logUnknownAiLabel(
      'EasySaveIgAiProbe:{"path":"\u0024.label_cookie","name":"label_cookie","type":"string","value":"PRIVATE_COOKIE"}',
    );
    logUnknownAiLabel(
      'EasySaveIgAiProbe:{"path":"\u0024.ai_session","name":"ai_session","type":"string","value":"PRIVATE_SESSION"}',
    );
    expect(lines, hasLength(1));
    expect(lines.single, contains('[IgAiProbe]'));
    expect(lines.single, contains('AI_CREATED'));
    expect(lines.single, isNot(contains('PRIVATE')));
  });
}
