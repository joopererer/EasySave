// Locale-aware text ordering for the creators list.
//
// Dart has no collation, so Chinese names would otherwise sort by code point.
// Android's java.text.Collator (ICU) gives the system locale's order — pinyin
// for a Chinese locale — through the `easysave/text` channel. When the channel
// is unavailable (tests, other platforms, an older build) the lower-cased name
// is used as the key, which keeps the order deterministic.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SystemCollation {
  static const MethodChannel _channel = MethodChannel('easysave/text');

  /// Test seam: returns the sort keys for [names] in the same order.
  @visibleForTesting
  static Future<List<String>> Function(List<String> names)? readerForTesting;

  /// Sort keys for [names], keyed by name. Names are de-duplicated; missing
  /// names simply fall back to their lower-cased form in the comparator.
  static Future<Map<String, String>> keysFor(Iterable<String> names) async {
    final unique = <String>{...names.where((n) => n.trim().isNotEmpty)};
    if (unique.isEmpty) return const {};
    final list = unique.toList();
    List<String>? keys;
    try {
      keys = await (readerForTesting?.call(list) ??
          _channel
              .invokeMethod<List<Object?>>('collationKeys', {'names': list})
              .then((raw) => raw?.map((e) => '$e').toList()));
    } catch (_) {
      keys = null;
    }
    if (keys == null || keys.length != list.length) {
      return {for (final name in list) name: name.toLowerCase()};
    }
    return {for (var i = 0; i < list.length; i++) list[i]: keys[i]};
  }
}
