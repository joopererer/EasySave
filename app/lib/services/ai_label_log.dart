import 'dart:convert';

import '../core/dev_log.dart';

/// Accept only the parser's narrow diagnostic, never a general console dump.
void logUnknownAiLabel(String message) {
  const prefix = 'EasySaveAiLabel:';
  if (!message.startsWith(prefix)) return;
  try {
    final data = jsonDecode(message.substring(prefix.length));
    if (data is! Map || data.length != 2) return;
    final id = data['id'];
    final value = data['value'];
    if (id is! String || !RegExp(r'^[a-zA-Z0-9]+$').hasMatch(id)) return;
    if (value is! String && value is! num && value is! bool) return;
    DevLog.write('AI_LABEL', jsonEncode({'id': id, 'value': value}));
  } catch (_) {
    // A malformed page console message cannot interrupt parsing.
  }
}
