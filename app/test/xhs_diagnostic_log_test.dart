import 'dart:convert';
import 'package:easysave/services/ai_label_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('narrow diagnostic bridge accepts fields but rejects sensitive paths and extra data', () {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) { if (message != null) lines.add(message); };
    addTearDown(() => debugPrint = previous);
    String message(Map<String, dynamic> field) => 'EasySaveXhsDiagnostic:${jsonEncode({
      'dataPath': 'note.noteDetailMap[id].note', 'fields': [field],
    })}';
    logUnknownAiLabel(message({'path': 'note.illegalInfo', 'type': 'null'}));
    logUnknownAiLabel(message({'path': 'note.author.aiLabel', 'type': 'string', 'text': 'AI SECRET'}));
    logUnknownAiLabel(message({'path': 'note.aiLabel', 'type': 'string', 'text': 'ordinary SECRET'}));
    logUnknownAiLabel(message({'path': 'note.aiLabel', 'type': 'string', 'text': 'AI SECRET', 'cookie': 'SECRET'}));
    // The existing log export is the observable privacy boundary.
    expect(lines.join(), contains('note.illegalInfo'));
    expect(lines.join(), isNot(contains('SECRET')));
  });
}
