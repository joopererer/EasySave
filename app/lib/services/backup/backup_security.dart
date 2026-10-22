// Copyright 2026 EasySave. All rights reserved.
// Sensitive data security audit for backup JSON.
//
// Strictly inspects JSON object keys recursively to verify that no credentials,
// session identifiers, or auth headers are exported. Values (such as captions
// or titles containing the word 'token') are deliberately not checked.
// This check runs during unit tests for privacy assertions.

class SensitiveDataLeakException implements Exception {
  final String key;
  SensitiveDataLeakException(this.key);

  @override
  String toString() => 'SensitiveDataLeakException: detected sensitive key "$key" in backup JSON';
}

final _sensitiveWords = {
  'cookie',
  'cookies',
  'token',
  'tokens',
  'session',
  'sessions',
  'authorization',
  'auth',
  'oauth',
  'password',
  'secret',
  'credential',
  'credentials',
};

/// Recursively scans all keys in [jsonMap] to assert that no sensitive keys exist.
/// Throws [SensitiveDataLeakException] if any sensitive key is found.
bool validateNoSensitiveKeys(Map<String, dynamic> jsonMap) {
  _scanMapKeys(jsonMap);
  return true;
}

List<String> _extractWords(String key) {
  return key
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((s) => s.isNotEmpty)
      .toList();
}

void _scanMapKeys(Map<String, dynamic> map) {
  for (final entry in map.entries) {
    final words = _extractWords(entry.key);
    for (final word in words) {
      if (_sensitiveWords.contains(word)) {
        throw SensitiveDataLeakException(entry.key);
      }
    }
    final value = entry.value;
    if (value is Map) {
      _scanMapKeys(value.cast<String, dynamic>());
    } else if (value is List) {
      for (final item in value) {
        if (item is Map) {
          _scanMapKeys(item.cast<String, dynamic>());
        }
      }
    }
  }
}
