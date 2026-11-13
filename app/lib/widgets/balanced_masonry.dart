// Placement rule for the 帖子 waterfall's two balanced columns (v1.11).
//
// Pure Dart: the placement is a function of the card heights alone, so the
// same data always lays out the same way and a refresh cannot reshuffle cards
// that are already on screen.
//
//   * every card goes into the column that is shorter at that moment;
//   * a difference of at most [kMasonryTieThreshold] counts as a tie and a tie
//     puts the card in the left column, so the choice never flaps;
//   * if the group would end with the right column taller, the whole group is
//     mirrored, so the left column is never the shorter one.

/// Height difference treated as a tie between the two columns.
const double kMasonryTieThreshold = 8;

/// Gap between the two columns.
const double kMasonryColumnGap = 8;

/// Vertical gap between two cards of the same column.
const double kMasonryRowGap = 12;

/// Where one card ended up.
class MasonrySlot {
  const MasonrySlot({
    required this.column,
    required this.top,
    required this.height,
  });

  /// 0 = left, 1 = right, in displayed (already mirrored) order.
  final int column;

  /// Top offset inside the group.
  final double top;
  final double height;
}

/// Result of laying out one date group.
class MasonryLayout {
  const MasonryLayout({
    required this.slots,
    required this.height,
    required this.mirrored,
    required this.leftHeight,
    required this.rightHeight,
  });

  final List<MasonrySlot> slots;

  /// Height the group occupies.
  final double height;

  /// True when the group was mirrored to keep the left column the taller one.
  final bool mirrored;

  /// Column heights after mirroring, with [leftHeight] >= [rightHeight].
  final double leftHeight;
  final double rightHeight;
}

/// Places the cards of one group into two columns.
///
/// [tieThreshold] and [rowGap] are parameters so the rule can be tested at its
/// boundaries; production uses the constants above.
MasonryLayout layoutBalancedMasonry(
  List<double> heights, {
  double tieThreshold = kMasonryTieThreshold,
  double rowGap = kMasonryRowGap,
}) {
  var left = 0.0;
  var right = 0.0;
  final columnOf = List<int>.filled(heights.length, 0);
  final topOf = List<double>.filled(heights.length, 0);

  for (var i = 0; i < heights.length; i++) {
    final height = heights[i];
    // The right column only wins when it is shorter by more than the
    // threshold; a tie keeps the card on the left.
    if ((left - right) > tieThreshold) {
      columnOf[i] = 1;
      topOf[i] = right;
      right += height + rowGap;
    } else {
      columnOf[i] = 0;
      topOf[i] = left;
      left += height + rowGap;
    }
  }

  // The trailing row gap is not part of the group's height.
  final leftContent = left > 0 ? left - rowGap : 0.0;
  final rightContent = right > 0 ? right - rowGap : 0.0;
  final mirrored = rightContent > leftContent;

  return MasonryLayout(
    slots: [
      for (var i = 0; i < heights.length; i++)
        MasonrySlot(
          column: mirrored ? 1 - columnOf[i] : columnOf[i],
          top: topOf[i],
          height: heights[i],
        ),
    ],
    height: leftContent > rightContent ? leftContent : rightContent,
    mirrored: mirrored,
    leftHeight: mirrored ? rightContent : leftContent,
    rightHeight: mirrored ? leftContent : rightContent,
  );
}
