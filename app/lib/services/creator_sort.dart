// Ordering of the history "按作者" (creators) list.
//
// Kept free of widgets so the order is unit-testable: the page builds
// [CreatorSortRow]s from the records and passes the remembered key, direction
// and the locale collation keys from SystemCollation.

import 'settings.dart';

/// One creator row, detached from widgets.
class CreatorSortRow {
  const CreatorSortRow({
    required this.id,
    required this.name,
    required this.postCount,
    required this.lastSavedAt,
  });

  /// `platform:author`, the stable identity used as the last tie-break.
  final String id;
  final String name;
  final int postCount;

  /// The author's most recent save (the newest file of any of their posts).
  final DateTime lastSavedAt;
}

/// Sorts [rows] by [key], ascending or descending.
///
/// Ties keep a stable, explained order instead of an arbitrary one:
/// * sorting by name falls back to the post count, then the latest save
///   (as specified for the name key);
/// * sorting by count or time falls back to the name (locale order), then the
///   post count, then the latest save;
/// * the row identity is the final tie-break so equal data never reshuffles
///   between reloads.
List<CreatorSortRow> sortCreatorRows(
  List<CreatorSortRow> rows, {
  required CreatorSortKey key,
  required bool descending,
  Map<String, String> collationKeys = const {},
}) {
  int byCollatedName(CreatorSortRow a, CreatorSortRow b) {
    final ka = collationKeys[a.name] ?? a.name.toLowerCase();
    final kb = collationKeys[b.name] ?? b.name.toLowerCase();
    final cmp = ka.compareTo(kb);
    if (cmp != 0) return cmp;
    return a.name.compareTo(b.name);
  }

  int byName(CreatorSortRow a, CreatorSortRow b) {
    final cmp = byCollatedName(a, b);
    if (cmp != 0) return cmp;
    return a.id.compareTo(b.id);
  }

  int byCount(CreatorSortRow a, CreatorSortRow b) {
    final cmp = b.postCount.compareTo(a.postCount);
    if (cmp != 0) return cmp;
    final time = b.lastSavedAt.compareTo(a.lastSavedAt);
    if (time != 0) return time;
    return byName(a, b);
  }

  int primary(CreatorSortRow a, CreatorSortRow b) {
    switch (key) {
      case CreatorSortKey.postCount:
        return b.postCount.compareTo(a.postCount);
      case CreatorSortKey.recentSaved:
        return b.lastSavedAt.compareTo(a.lastSavedAt);
      case CreatorSortKey.name:
        // Descending-first, like the other keys, so [descending] is a single
        // sign flip for all three.
        return byCollatedName(b, a);
    }
  }

  int compare(CreatorSortRow a, CreatorSortRow b) {
    final cmp = primary(a, b) * (descending ? 1 : -1);
    if (cmp != 0) return cmp;
    switch (key) {
      case CreatorSortKey.name:
        // Same name: most posts first, then the most recent save.
        final count = b.postCount.compareTo(a.postCount);
        if (count != 0) return count;
        final time = b.lastSavedAt.compareTo(a.lastSavedAt);
        if (time != 0) return time;
        return a.id.compareTo(b.id);
      case CreatorSortKey.postCount:
      case CreatorSortKey.recentSaved:
        // Same count or same time: the other measured value, then the name.
        return byCount(a, b);
    }
  }

  return [...rows]..sort(compare);
}
