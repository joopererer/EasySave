// Lazy (sliver) two-column waterfalls for the history page (v1.11 batch 2).
//
// Batch 1 placed the 帖子 waterfall's cards with a MultiChildRenderObjectWidget
// and kept the 全部 waterfall in a shrink-wrapped masonry inside a
// SliverToBoxAdapter. Both had to build *every* card of a date group to know
// the group's height, so a 200-post group mounted 200 HistoryThumb widgets —
// and every mounted thumb starts its own local thumbnail request — before the
// user saw a dozen of them. Build 49 measured the result: 625 timeout lines
// and an in-flight peak of 416 native thumbnail requests.
//
// The placement never needed the measured heights, only *heights*, and a
// card's height is a function of its cover's aspect ratio, which the record
// already carries. So the heights come from the data
// ([LazyMasonrySliver.estimatedHeightOf]) and the cards are rendered by two
// lazy [SliverList]s side by side inside a [SliverCrossAxisGroup]: only the
// cards near the viewport (plus the viewport's own cache extent) exist, and
// the geometry is identical to measuring, because each card really is that
// tall (both cards are a plain AspectRatio).
//
// The columns are pure stacks with a constant gap, so "two independent lists"
// reproduces both placement rules exactly:
//
//   * [layoutBalancedMasonry] for the 帖子 waterfall (left column never the
//     shorter one, ties to the left, deterministic);
//   * [layoutGreedyMasonry] for the 全部 waterfall (classic staggered order).

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'balanced_masonry.dart';

/// Lazy two-column masonry sliver.
///
/// [itemKeys] identify the items by content (not by position) so the lists can
/// keep an element when the order changes; [estimatedHeightOf] must return the
/// exact height the card will occupy at [columnWidth], derived from known data
/// only — nothing here may build a card to find out how tall it is.
class LazyMasonrySliver extends StatelessWidget {
  const LazyMasonrySliver({
    super.key,
    required this.itemKeys,
    required this.estimatedHeightOf,
    required this.itemBuilder,
    this.balanced = false,
    this.columnGap = kMasonryColumnGap,
    this.rowGap = kMasonryRowGap,
    this.tieThreshold = kMasonryTieThreshold,
  });

  /// One key per item, in display order.
  final List<String> itemKeys;

  /// Height of item [index] inside a column of [columnWidth] logical pixels.
  final double Function(int index, double columnWidth) estimatedHeightOf;

  /// Builds item [index] (the card itself, without padding).
  final Widget Function(BuildContext context, int index) itemBuilder;

  /// Balanced rule (帖子) instead of the staggered one (全部).
  final bool balanced;

  final double columnGap;
  final double rowGap;
  final double tieThreshold;

  static const String _keyPrefix = 'lazy-masonry:';

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (BuildContext context, SliverConstraints constraints) {
        final double width = constraints.crossAxisExtent;
        final double columnWidth = ((width - columnGap) / 2).clamp(0.0, width);
        final List<double> heights = <double>[
          for (var i = 0; i < itemKeys.length; i++)
            estimatedHeightOf(i, columnWidth),
        ];
        final MasonryLayout layout = balanced
            ? layoutBalancedMasonry(
                heights,
                tieThreshold: tieThreshold,
                rowGap: rowGap,
              )
            : layoutGreedyMasonry(heights, rowGap: rowGap);

        final List<int> left = <int>[];
        final List<int> right = <int>[];
        for (var i = 0; i < heights.length; i++) {
          (layout.slots[i].column == 0 ? left : right).add(i);
        }

        return SliverCrossAxisGroup(
          slivers: <Widget>[
            _column(context, left, leading: 0, trailing: columnGap / 2),
            _column(context, right, leading: columnGap / 2, trailing: 0),
          ],
        );
      },
    );
  }

  Widget _column(
    BuildContext context,
    List<int> indices, {
    required double leading,
    required double trailing,
  }) {
    final Map<String, int> positions = <String, int>{
      for (var position = 0; position < indices.length; position++)
        '$_keyPrefix${itemKeys[indices[position]]}': position,
    };
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (BuildContext context, int position) {
          final int index = indices[position];
          return Padding(
            key: ValueKey<String>('$_keyPrefix${itemKeys[index]}'),
            padding: EdgeInsets.only(
              left: leading,
              right: trailing,
              bottom: rowGap,
            ),
            child: itemBuilder(context, index),
          );
        },
        childCount: indices.length,
        findChildIndexCallback: (Key key) {
          if (key is! ValueKey<String>) return null;
          return positions[key.value];
        },
      ),
    );
  }
}
