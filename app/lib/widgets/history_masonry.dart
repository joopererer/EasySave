import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

/// Shrink-wrapped two-column masonry used by the history waterfalls.
///
/// The masonry render object caches each child's column and offset in its
/// parent data. When the list order changes (a re-saved post moves to the
/// top, a deletion, an insertion) those stale positions are reused, leaving a
/// moved card alone in its row. Keying the grid by the ordered item keys
/// rebuilds the layout whenever order or membership changes, while
/// progress-only rebuilds keep the same render object.
class HistoryMasonryGrid extends StatelessWidget {
  const HistoryMasonryGrid({
    super.key,
    required this.itemKeys,
    required this.itemBuilder,
  });

  final List<String> itemKeys;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return MasonryGridView.count(
      key: ValueKey(itemKeys.join('\u0000')),
      crossAxisCount: 2,
      mainAxisSpacing: 12,
      crossAxisSpacing: 8,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: itemKeys.length,
      itemBuilder: itemBuilder,
    );
  }
}
