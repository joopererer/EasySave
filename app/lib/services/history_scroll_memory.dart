// Where the history list should be, per mode + filter + sort (v1.11 batch 3).
//
// Build 55 device report:
//   * 创作者 lost its position after a few switches and came back to the top;
//   * picking an author there and switching to 帖子 / 全部 landed at the end of
//     the list.
// The page kept one offset per *mode* and let PageStorage restore it as soon as
// the list attached — which is before the content has a height, so the restore
// was clamped (to 0, or to whatever small extent existed) and the real offset
// was lost. Nothing distinguished "the same list, new data" from "another
// filter", so a filter change inherited the old offset.
//
// The rules this file implements, as pure functions so each one is testable:
//
//   * a position belongs to mode + filter (author, platform, search) + sort;
//   * adding or changing a filter, or changing the sort, starts at the top;
//   * going back to the *unfiltered* list returns to where it was left;
//   * a position outside the list becomes the top, never the end;
//   * a data update keeps the card the user was looking at where it was.

import 'package:flutter/foundation.dart';

/// What a remembered position belongs to.
@immutable
class HistoryScrollKey {
  const HistoryScrollKey({
    required this.view,
    required this.author,
    required this.platform,
    required this.query,
    required this.sort,
    required this.creatorSort,
    required this.creatorSortDescending,
  });

  /// `posts`, `all` or `creators`.
  final String view;
  final String? author;
  final String platform;
  final String query;
  final String sort;
  final String creatorSort;
  final bool creatorSortDescending;

  /// No author, no platform, no search: the list as it opened.
  bool get unfiltered =>
      author == null && platform == 'all' && query.trim().isEmpty;

  /// The map key. The search is trimmed and lower-cased, so "cat" and " Cat "
  /// are one position.
  String get id =>
      '$view\u0000${author ?? ''}\u0000$platform\u0000'
      '${query.trim().toLowerCase()}\u0000$sort\u0000'
      '$creatorSort\u0000${creatorSortDescending ? 1 : 0}';

  @override
  bool operator ==(Object other) => other is HistoryScrollKey && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'HistoryScrollKey(${id.replaceAll('\u0000', '|')})';
}

/// One offset per [HistoryScrollKey].
class HistoryScrollMemory {
  final Map<String, double> _offsets = <String, double>{};

  /// The offset remembered for [key], or null when it was never scrolled.
  double? offsetFor(HistoryScrollKey key) => _offsets[key.id];

  /// Remembers where [key] is now.
  ///
  /// Only a real position (a finite, non-negative pixel offset) is stored; a
  /// list that was never scrolled keeps "no position yet", which is different
  /// from "at the top" for the rules below.
  void remember(HistoryScrollKey key, double offset) {
    if (!offset.isFinite || offset < 0) return;
    _offsets[key.id] = offset;
  }

  /// Forgets everything (the page is going away / a test).
  void clear() => _offsets.clear();

  @visibleForTesting
  int get length => _offsets.length;
}

/// Where a change of filter or sort has to go.
enum ScrollDestination {
  /// The new list starts at the top.
  top,

  /// The new list returns to the position it was left at.
  remembered,
}

/// The rule for a filter or sort change.
///
/// A filter that is added or changed, or a new order, starts at the top. Going
/// back to the *unfiltered* list returns to where that list was left — that is
/// the "恢复筛选前的位置" the device report asked for. A remembered position that
/// the new list cannot hold is handled by [resolveOffset], which turns it into
/// the top.
ScrollDestination destinationForChange(
  HistoryScrollKey next, {
  double? remembered,
}) {
  if (next.unfiltered && remembered != null) {
    return ScrollDestination.remembered;
  }
  return ScrollDestination.top;
}

/// How far outside the list a position may be before it counts as gone.
const double kScrollRangeTolerance = 1.0;

/// A position inside `0 .. maxExtent`, or the top when [target] is outside it.
///
/// Being past the end never parks the list at the end: the record that was
/// there is gone, and the honest place to stand is the top.
double resolveOffset(double target, double maxExtent) {
  if (!target.isFinite || target <= 0) return 0;
  final max = maxExtent.isFinite && maxExtent > 0 ? maxExtent : 0.0;
  if (target <= max + kScrollRangeTolerance) {
    return target > max ? max : target;
  }
  return 0;
}

/// One card of a list, as the anchor rules see it.
@immutable
class ScrollAnchor {
  const ScrollAnchor({required this.key, required this.top, this.height = 0});

  /// Identity of the card (`p12`, `m12:0`, `c author`).
  final String key;

  /// Card top relative to the viewport top: negative when the card starts
  /// above the edge (the list is scrolled into it).
  final double top;

  /// Card height, so "is any of it on screen" can be answered. 0 when the
  /// caller does not know it.
  final double height;
}

/// Which card an anchor prefers.
enum AnchorPreference {
  /// The first card the user can actually see, including one that starts above
  /// the top edge. A data update must not move what is on screen at all, so
  /// this is the right one there.
  visible,

  /// The first card that starts at or below the top edge. A layout switch
  /// cannot keep a half-scrolled card on screen when the card's own height
  /// changes with the layout, so it holds on to the first fully visible one.
  aligned,
}

/// The card a change has to hold on to.
///
/// See [AnchorPreference]: a data update takes the first card the user can see
/// (including a partially scrolled one), a layout switch the first card that
/// starts below the top edge.
ScrollAnchor? pickAnchor(
  Iterable<ScrollAnchor> candidates, {
  AnchorPreference preference = AnchorPreference.visible,
}) {
  ScrollAnchor? below;
  ScrollAnchor? above;
  ScrollAnchor? straddling;
  for (final candidate in candidates) {
    if (candidate.top >= 0) {
      if (below == null || candidate.top < below.top) below = candidate;
      continue;
    }
    if (above == null || candidate.top > above.top) above = candidate;
    final bottom = candidate.top + candidate.height;
    if (candidate.height > 0 && bottom > 0) {
      if (straddling == null || candidate.top > straddling.top) {
        straddling = candidate;
      }
    }
  }
  if (preference == AnchorPreference.aligned) {
    return below ?? straddling ?? above;
  }
  return straddling ?? above ?? below;
}


/// The offset that puts [anchorKey] back where it was seen.
///
/// [delta] is the card's top relative to the viewport top when it was captured;
/// [reveal] is the offset at which the card's top sits exactly at the edge.
double anchorRestoreOffset({required double reveal, required double delta}) =>
    reveal - delta;
