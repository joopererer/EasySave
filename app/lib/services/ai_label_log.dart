import 'dart:convert';

import '../core/dev_log.dart';

/// Accept only the parser's narrow diagnostic, never a general console dump.
void logUnknownAiLabel(String message) {
  if (message.startsWith('EasySaveXhsDiagnostic:')) {
    logXhsDiagnostic(message);
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

// TEMPORARY: narrow allowlist for the XHS diagnostic, never forward raw console.
void logXhsDiagnostic(String message) {
  const prefix = 'EasySaveXhsDiagnostic:';
  try {
    final data = jsonDecode(message.substring(prefix.length));
    if (data is! Map || data.length != 2) return;
    final path = data['dataPath'];
    const allowed = {'note.noteDetailMap[id].note', 'note.noteDetailMap[id]',
      'noteData.data.noteData.note', 'noteData.data.noteData',
      'state.deepFindNote', 'HTML.noteDetailMap[id]'};
    if (!allowed.contains(path) || data['fields'] is! List) return;
    final fields = <Map<String, String>>[];
    for (final field in data['fields'] as List) {
      if (field is! Map || field.keys.any((k) => !{'path', 'type', 'text'}.contains(k))) return;
      final name = field['path'];
      final type = field['type'];
      if (name is! String || !RegExp(r'^note(?:\.[a-zA-Z_$][a-zA-Z0-9_$]*|\[index\])+$').hasMatch(name)) return;
      if (name.split('.').skip(1).any((part) => RegExp(
        r'cookie|token|session|account|password|email|phone|^(?:author|user|profile|nickname)(?:$|[_-]?(?:id|name|info|avatar|detail|data)$)',
        caseSensitive: false).hasMatch(part))) return;
      if (!RegExp(r'illegal|ai|aigc|declare|statement|label|tag|notice|tip', caseSensitive: false).hasMatch(name.split('.').last)) return;
      if (!{'null', 'array', 'object', 'string', 'number', 'boolean', 'undefined'}.contains(type)) return;
      final clean = <String, String>{'path': name, 'type': type as String};
      if (field.containsKey('text')) {
        final value = field['text'];
        if (type != 'string' || value is! String || value.runes.length > 50 ||
            !RegExp(r'AI|声明', caseSensitive: false).hasMatch(value)) return;
        clean['text'] = value;
      }
      fields.add(clean);
    }
    DevLog.write('XHS_DIAG', jsonEncode({'dataPath': path, 'fields': fields}));
  } catch (_) { /* Malformed page messages are ignored. */ }
}
