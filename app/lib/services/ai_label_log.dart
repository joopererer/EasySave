import 'dart:convert';

import '../core/dev_log.dart';

/// Accept only the parser's narrow diagnostic, never a general console dump.
void logUnknownAiLabel(String message) {
  if (message.startsWith('EasySaveIgAiProbe:')) {
    logIgAiProbe(message.substring('EasySaveIgAiProbe:'.length));
    return;
  }
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

void logIgAiProbe(String text) {
  try {
    final data = jsonDecode(text);
    if (data is! Map ||
        data.keys.any((k) => !{'path', 'name', 'type', 'value'}.contains(k))) {
      return;
    }
    final path = data['path'], name = data['name'], type = data['type'];
    if (path is! String ||
        name is! String ||
        type is! String ||
        path.length > 2200 ||
        !RegExp(
          r'^\$(?:\.[A-Za-z_][A-Za-z0-9_]{0,79}|\[[0-9]+\])+$',
        ).hasMatch(path) ||
        !RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,79}$').hasMatch(name) ||
        !RegExp(
          r'ai|gen_ai|genai|label|disclosure|c2pa',
          caseSensitive: false,
        ).hasMatch(name) ||
        !{
          'null',
          'array',
          'object',
          'boolean',
          'number',
          'string',
          'undefined',
        }.contains(type)) {
      return;
    }
    final value = data['value'];
    if (data.containsKey('value') &&
        (RegExp(
              r'user|owner|author|caption|text|url|email|phone|account|cookie|token|session|password|secret|authorization',
              caseSensitive: false,
            ).hasMatch(path) ||
            !(value is bool ||
                value is num && value.isFinite ||
                value is String &&
                    RegExp(r'^[A-Za-z0-9_]{1,40}$').hasMatch(value)))) {
      return;
    }
    DevLog.write('IgAiProbe', jsonEncode(data));
  } catch (_) {}
}
