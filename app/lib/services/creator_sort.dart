// Creator-mode ordering for the history page (v1.11 batch 1).
//
// Pure Dart and in memory only. The history page already holds every record it
// read once from the DB, and grouping them by creator is a plain map walk, so
// ordering the resulting groups must not add a database query, a native call
// per row or a change to the shared reload path (the build 35 lesson: a native
// collation call per row turned a repaint into a stall).

/// Which value the 创作者 view is ordered by.
enum CreatorSort {
  /// Post count (帖子数).
  postCount,

  /// Most recent save time among the creator's posts (最近保存时间).
  latestSaved,

  /// Display name (名称).
  name,
}

/// Persisted choice: the sort key plus its direction.
class CreatorSortState {
  const CreatorSortState({required this.mode, required this.descending});

  /// 最近保存 descending (newest first) is the default for a fresh install.
  static const CreatorSortState defaults = CreatorSortState(
    mode: CreatorSort.latestSaved,
    descending: true,
  );

  final CreatorSort mode;
  final bool descending;

  CreatorSortState withMode(CreatorSort mode) =>
      CreatorSortState(mode: mode, descending: descending);

  CreatorSortState withDescending(bool descending) =>
      CreatorSortState(mode: mode, descending: descending);
}

/// The bits `sortCreators` needs from a creator group. The history page's
/// private group type implements this; tests can use their own.
abstract interface class CreatorSortable {
  /// The creator's name as stored (may be empty for an unknown author).
  String get sortName;

  /// Canonical platform id, the final tie-break so two creators that share a
  /// name can never swap places between two identical datasets.
  String get sortPlatform;

  int get sortPostCount;

  /// Latest save time of the group, in milliseconds since the epoch.
  int get sortLatestSavedMs;
}

/// Name ordering rule (documented so the UI behaviour is predictable).
///
/// 1. Names are trimmed and lower-cased first, so case never changes the
///    order of two otherwise identical names.
/// 2. An empty name (an unknown author) always sorts last, in both
///    directions only in the sense that the direction applies to the whole
///    list: the unknown bucket is the tail of the ascending order and the
///    head of the descending one.
/// 3. Names are bucketed by their first character:
///    digits (0-9) first, then Latin letters (a-z), then CJK ideographs,
///    then everything else (emoji, symbols, other scripts).
/// 4. Inside the digit bucket the leading run of digits is compared as a
///    number, so "2" sorts before "10" instead of after it.
/// 5. Inside every other bucket the comparison is by UTF-16 code unit, which
///    for CJK means Unicode block order (U+3400 ext-A, U+4E00 basic,
///    U+F900 compatibility) rather than pinyin. Pinyin would need either a
///    lookup table or a platform collator; the platform collator is a native
///    call and is deliberately not used here.
String nameSortKey(String name) => name.trim().toLowerCase();

int _nameRank(String key) {
  if (key.isEmpty) return 4;
  final first = key.codeUnitAt(0);
  if (first >= 0x30 && first <= 0x39) return 0;
  if ((first >= 0x61 && first <= 0x7a) || (first >= 0x41 && first <= 0x5a)) {
    return 1;
  }
  if (_isCjkCodeUnit(first)) return 2;
  return 3;
}

bool _isCjkCodeUnit(int code) =>
    (code >= 0x3400 && code <= 0x4dbf) ||
    (code >= 0x4e00 && code <= 0x9fff) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0x3040 && code <= 0x30ff); // kana, common in Japanese names

/// The leading digit run of [key] as a number (0 when there is none).
int _leadingNumber(String key) {
  var end = 0;
  while (end < key.length) {
    final code = key.codeUnitAt(end);
    if (code < 0x30 || code > 0x39) break;
    end++;
  }
  if (end == 0) return 0;
  // Absurdly long digit runs fall back to a saturating value instead of
  // overflowing.
  if (end > 15) return 1 << 52;
  return int.tryParse(key.substring(0, end)) ?? 0;
}

/// Ascending name comparison under the rule above.
int compareCreatorNames(String a, String b) {
  final ka = nameSortKey(a);
  final kb = nameSortKey(b);
  if (identical(ka, kb) || ka == kb) return 0;
  final rankA = _nameRank(ka);
  final rankB = _nameRank(kb);
  if (rankA != rankB) return rankA.compareTo(rankB);
  if (rankA == 0) {
    final na = _leadingNumber(ka);
    final nb = _leadingNumber(kb);
    if (na != nb) return na.compareTo(nb);
  }
  return ka.compareTo(kb);
}

/// Order [groups] in place: [mode] ascending, or descending when
/// [descending]. Returns the same list for convenient use in an expression.
///
/// Every mode falls back to the same chain of tie-breaks, so the result is a
/// total order: latest save descending, then name ascending, then platform
/// ascending. The same input therefore always produces the same layout.
List<T> sortCreators<T extends CreatorSortable>(
  List<T> groups, {
  required CreatorSort mode,
  required bool descending,
}) {
  groups.sort((a, b) {
    final primary = switch (mode) {
      CreatorSort.postCount => a.sortPostCount.compareTo(b.sortPostCount),
      CreatorSort.latestSaved => a.sortLatestSavedMs.compareTo(
        b.sortLatestSavedMs,
      ),
      CreatorSort.name => compareCreatorNames(a.sortName, b.sortName),
    };
    if (primary != 0) return descending ? -primary : primary;
    // Ties are always newest-first, independent of the chosen direction, as
    // specified for the 创作者 menu.
    final byTime = b.sortLatestSavedMs.compareTo(a.sortLatestSavedMs);
    if (byTime != 0) return byTime;
    final byName = compareCreatorNames(a.sortName, b.sortName);
    if (byName != 0) return byName;
    return a.sortPlatform.compareTo(b.sortPlatform);
  });
  return groups;
}
