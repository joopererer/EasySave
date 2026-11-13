// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 1: the 帖子 waterfall's balanced two-column layout.
//
// The placement is a pure function of the card heights, so these tests drive
// it directly: equal heights, alternating heights, one card, an odd count, the
// tie threshold at its boundary and the group that has to be mirrored.

import 'package:easysave/widgets/balanced_masonry.dart';
import 'package:easysave/widgets/balanced_masonry_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> columns(MasonryLayout layout) =>
    [for (final slot in layout.slots) slot.column];

void main() {
  group('equal heights', () {
    test('alternates strictly left/right and never mirrors', () {
      final layout = layoutBalancedMasonry(List<double>.filled(6, 100));
      expect(columns(layout), [0, 1, 0, 1, 0, 1]);
      expect(layout.mirrored, isFalse);
      expect(layout.leftHeight, layout.rightHeight);
    });

    test('a group of equal cards is symmetric and repeatable', () {
      final first = layoutBalancedMasonry(List<double>.filled(4, 50));
      final second = layoutBalancedMasonry(List<double>.filled(4, 50));
      expect(columns(first), columns(second));
      expect(first.slots.map((s) => s.top).toList(),
          second.slots.map((s) => s.top).toList());
    });
  });

  group('alternating heights', () {
    test('tall/short pairs fill the shorter column', () {
      // 200 goes left, 100 goes right; the right is now 100 shorter than the
      // left, which is more than the 8dp tie threshold, so 200 goes right;
      // then 100 follows on the left.
      final layout = layoutBalancedMasonry([200, 100, 200, 100]);
      expect(columns(layout), [0, 1, 1, 0]);
      expect(layout.mirrored, isFalse);
      expect(layout.leftHeight, layout.rightHeight);
    });

    test('a taller right column mirrors the whole group', () {
      // 100 left, 300 right: the left stays shorter, so the group flips.
      final layout = layoutBalancedMasonry([100, 300]);
      expect(layout.mirrored, isTrue);
      // After mirroring the taller card is on the left.
      expect(layout.slots.first.column, 1);
      expect(layout.slots.last.column, 0);
      expect(layout.leftHeight, greaterThanOrEqualTo(layout.rightHeight));
    });
  });

  group('single card', () {
    test('goes to the left column and is never mirrored', () {
      final layout = layoutBalancedMasonry([180]);
      expect(columns(layout), [0]);
      expect(layout.slots.single.top, 0);
      expect(layout.height, 180);
      expect(layout.mirrored, isFalse);
      expect(layout.leftHeight, 180);
      expect(layout.rightHeight, 0);
    });

    test('an empty group has no slots and no height', () {
      final layout = layoutBalancedMasonry(const []);
      expect(layout.slots, isEmpty);
      expect(layout.height, 0);
      expect(layout.mirrored, isFalse);
    });
  });

  group('odd count', () {
    test('the last card goes to the shorter column and it is not mirrored',
        () {
      final layout = layoutBalancedMasonry([100, 100, 100]);
      expect(columns(layout), [0, 1, 0]);
      expect(layout.mirrored, isFalse);
      expect(layout.leftHeight, greaterThan(layout.rightHeight));
    });

    test('three tall cards keep the left column the taller one', () {
      final layout = layoutBalancedMasonry([300, 300, 300]);
      expect(columns(layout), [0, 1, 0]);
      expect(layout.leftHeight, greaterThan(layout.rightHeight));
      expect(layout.mirrored, isFalse);
    });
  });

  group('tie threshold', () {
    test('at exactly the threshold the card stays on the left', () {
      // Threshold 0 makes every difference a real one: after 100 left and
      // 100 right the columns are equal, so the third card is a tie again.
      // With the tie threshold at exactly the height difference the left
      // column must win.
      final withTie = layoutBalancedMasonry(
        [100, 100, 8],
        tieThreshold: 8,
        rowGap: 0,
      );
      expect(columns(withTie), [0, 1, 0]);
      // The left column was 100, the right 100: a difference of 0 is a tie.
      expect(withTie.mirrored, isFalse);
    });

    test('one point over the threshold sends the card to the right', () {
      // left = 108, right = 100: the difference is 8, a tie -> left.
      final tie = layoutBalancedMasonry([108, 100, 10],
          tieThreshold: 8, rowGap: 0);
      expect(tie.slots[2].column, 0);
      expect(tie.mirrored, isFalse);

      // left = 109, right = 100: the difference is 9 > 8 -> right. The third
      // card then makes the right column 1px taller, so the group is mirrored
      // and the card shows on the left; the placement before mirroring is
      // what the threshold decided.
      final dodge = layoutBalancedMasonry([109, 100, 10],
          tieThreshold: 8, rowGap: 0);
      expect(dodge.mirrored, isTrue);
      expect(dodge.slots[2].column, 0);
      expect(dodge.leftHeight, 110);
      expect(dodge.rightHeight, 109);
    });
  });

  group('mirroring', () {
    test('the mirrored group puts the taller column on the left', () {
      final layout = layoutBalancedMasonry([20, 200], rowGap: 0);
      expect(layout.mirrored, isTrue);
      expect(columns(layout), [1, 0]);
      expect(layout.leftHeight, 200);
      expect(layout.rightHeight, 20);
    });

    test('mirroring happens only when the right column is strictly taller',
        () {
      final equal = layoutBalancedMasonry([100, 100]);
      expect(equal.mirrored, isFalse);
      final rightTaller = layoutBalancedMasonry([100, 101]);
      expect(rightTaller.mirrored, isTrue);
    });

    test('card tops travel with their column when mirrored', () {
      final layout = layoutBalancedMasonry([50, 400, 60], rowGap: 0);
      // 50 -> left, 400 -> right, 60 -> left (left 50 < right 400).
      // The right column ends taller, so the group mirrors.
      expect(layout.mirrored, isTrue);
      expect(columns(layout), [1, 0, 1]);
      expect(layout.slots[0].top, 0); // the 50 was first in the right column
      expect(layout.slots[1].top, 0); // the 400 was first in the left column
      expect(layout.slots[2].top, 50); // the 60 followed the 50
      expect(layout.leftHeight, 400);
      expect(layout.rightHeight, 110);
    });
  });

  group('render object', () {
    Widget host(List<double> heights) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: BalancedMasonry(
                children: [
                  for (var i = 0; i < heights.length; i++)
                    SizedBox(
                      key: ValueKey('card-$i'),
                      height: heights[i],
                      child: const ColoredBox(color: Colors.grey),
                    ),
                ],
              ),
            ),
          ),
        );

    testWidgets('equal cards alternate between the two columns',
        (tester) async {
      await tester.pumpWidget(host([100, 100, 100, 100]));
      // 200 wide, 8 gap -> two 96 wide columns.
      expect(tester.getTopLeft(find.byKey(const ValueKey('card-0'))),
          const Offset(0, 0));
      expect(tester.getTopLeft(find.byKey(const ValueKey('card-1'))),
          const Offset(104, 0));
      expect(tester.getTopLeft(find.byKey(const ValueKey('card-2'))),
          const Offset(0, 112));
      expect(tester.getTopLeft(find.byKey(const ValueKey('card-3'))),
          const Offset(104, 112));
    });

    testWidgets('a taller card is placed in the shorter column',
        (tester) async {
      await tester.pumpWidget(host([300, 100]));
      expect(tester.getTopLeft(find.byKey(const ValueKey('card-0'))),
          const Offset(0, 0));
      expect(tester.getTopLeft(find.byKey(const ValueKey('card-1'))),
          const Offset(104, 0));
    });

    testWidgets('a group whose right column is taller is mirrored',
        (tester) async {
      await tester.pumpWidget(host([20, 200]));
      // Mirrored: the tall card sits on the left.
      expect(tester.getTopLeft(find.byKey(const ValueKey('card-1'))),
          const Offset(0, 0));
      expect(tester.getTopLeft(find.byKey(const ValueKey('card-0'))),
          const Offset(104, 0));
    });

    testWidgets('the same children always lay out the same way',
        (tester) async {
      await tester.pumpWidget(host([120, 240, 60, 60]));
      final first = [
        for (var i = 0; i < 4; i++)
          tester.getTopLeft(find.byKey(ValueKey('card-$i'))),
      ];
      // A rebuild with identical children (e.g. a progress tick) must not
      // reshuffle anything.
      await tester.pumpWidget(host([120, 240, 60, 60]));
      final second = [
        for (var i = 0; i < 4; i++)
          tester.getTopLeft(find.byKey(ValueKey('card-$i'))),
      ];
      expect(second, first);
    });
  });

  group('stability', () {
    test('the same height sequence always yields the same layout', () {
      const heights = [120.0, 240.0, 180.0, 90.0, 300.0, 60.0, 60.0];
      final a = layoutBalancedMasonry(heights);
      final b = layoutBalancedMasonry(heights);
      expect(columns(a), columns(b));
      expect([for (final s in a.slots) s.top], [for (final s in b.slots) s.top]);
      expect(a.height, b.height);
      expect(a.mirrored, b.mirrored);
    });

    test('the left column is never shorter than the right one', () {
      const sequences = [
        [100.0],
        [100.0, 200.0],
        [200.0, 100.0],
        [1.0, 2.0, 3.0, 4.0, 5.0],
        [500.0, 100.0, 100.0, 100.0, 100.0],
      ];
      for (final heights in sequences) {
        final layout = layoutBalancedMasonry(heights);
        expect(layout.leftHeight, greaterThanOrEqualTo(layout.rightHeight),
            reason: 'heights=$heights');
      }
    });
  });
}
