import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/services/ai_label_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('unknown label bridge logs only ID and original value', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) { if (message != null) lines.add(message); };
    addTearDown(() => debugPrint = previous);
    logUnknownAiLabel('EasySaveAiLabel:{"id":"123","value":"普通AI说明"}');
    logUnknownAiLabel('unrelated page output');
    logUnknownAiLabel('EasySaveAiLabel:{"id":"123","value":"x","extra":"secret"}');
    logUnknownAiLabel('EasySaveAiLabel:invalid');
    expect(lines, ['[INFO] [AI_LABEL] {"id":"123","value":"普通AI说明"}']);
  });
}
