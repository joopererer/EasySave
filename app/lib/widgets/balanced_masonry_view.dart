// The render object behind the 帖子 waterfall's balanced two columns.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'balanced_masonry.dart';

/// Two-column masonry whose cards are placed by [layoutBalancedMasonry].
///
/// Children are measured once per layout pass with a fixed column width, so
/// their height comes from the cover's aspect ratio exactly like the staggered
/// grid did. The placement is re-derived from those heights every pass, which
/// makes it stable: the same children always produce the same layout.
class BalancedMasonry extends MultiChildRenderObjectWidget {
  const BalancedMasonry({
    super.key,
    required super.children,
    this.columnGap = kMasonryColumnGap,
    this.rowGap = kMasonryRowGap,
    this.tieThreshold = kMasonryTieThreshold,
  });

  final double columnGap;
  final double rowGap;
  final double tieThreshold;

  @override
  RenderBalancedMasonry createRenderObject(BuildContext context) =>
      RenderBalancedMasonry(
        columnGap: columnGap,
        rowGap: rowGap,
        tieThreshold: tieThreshold,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderBalancedMasonry renderObject,
  ) {
    renderObject
      ..columnGap = columnGap
      ..rowGap = rowGap
      ..tieThreshold = tieThreshold;
  }
}

/// Shrink-wrapped balanced two-column grid with the same API as
/// [HistoryMasonryGrid], so a group can switch its placement rule in one line.
class BalancedMasonryGrid extends StatelessWidget {
  const BalancedMasonryGrid({
    super.key,
    required this.itemKeys,
    required this.itemBuilder,
  });

  final List<String> itemKeys;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    return BalancedMasonry(
      // The key keeps the render object stable while only progress changes.
      key: ValueKey(itemKeys.join('\u0000')),
      children: [
        for (var i = 0; i < itemKeys.length; i++)
          KeyedSubtree(
            key: ValueKey(itemKeys[i]),
            child: itemBuilder(context, i),
          ),
      ],
    );
  }
}

class MasonryParentData extends ContainerBoxParentData<RenderBox> {}

class RenderBalancedMasonry extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, MasonryParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, MasonryParentData> {
  RenderBalancedMasonry({
    required double columnGap,
    required double rowGap,
    required double tieThreshold,
  }) : _columnGap = columnGap,
       _rowGap = rowGap,
       _tieThreshold = tieThreshold;

  double get columnGap => _columnGap;
  double _columnGap;
  set columnGap(double value) {
    if (_columnGap == value) return;
    _columnGap = value;
    markNeedsLayout();
  }

  double get rowGap => _rowGap;
  double _rowGap;
  set rowGap(double value) {
    if (_rowGap == value) return;
    _rowGap = value;
    markNeedsLayout();
  }

  double get tieThreshold => _tieThreshold;
  double _tieThreshold;
  set tieThreshold(double value) {
    if (_tieThreshold == value) return;
    _tieThreshold = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MasonryParentData) {
      child.parentData = MasonryParentData();
    }
  }

  @override
  void performLayout() {
    final children = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      children.add(child);
      child = childAfter(child);
    }
    if (children.isEmpty) {
      size = constraints.constrain(Size.zero);
      return;
    }

    final width = constraints.maxWidth;
    final columnWidth = ((width - columnGap) / 2).clamp(0.0, width);
    for (final box in children) {
      box.layout(
        BoxConstraints.tightFor(width: columnWidth),
        parentUsesSize: true,
      );
    }

    final layout = layoutBalancedMasonry(
      [for (final box in children) box.size.height],
      tieThreshold: tieThreshold,
      rowGap: rowGap,
    );

    for (var i = 0; i < children.length; i++) {
      final slot = layout.slots[i];
      final parentData = children[i].parentData as MasonryParentData;
      parentData.offset = Offset(
        slot.column == 0 ? 0 : columnWidth + columnGap,
        slot.top,
      );
    }

    size = constraints.constrain(Size(width, layout.height));
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    var widest = 0.0;
    var child = firstChild;
    while (child != null) {
      final width = child.getMinIntrinsicWidth(height);
      if (width > widest) widest = width;
      child = childAfter(child);
    }
    return widest * 2 + columnGap;
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    var widest = 0.0;
    var child = firstChild;
    while (child != null) {
      final width = child.getMaxIntrinsicWidth(height);
      if (width > widest) widest = width;
      child = childAfter(child);
    }
    return widest * 2 + columnGap;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
