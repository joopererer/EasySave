import 'dart:async';

import 'package:easysave/services/history_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('transient read failures retry with increasing delay', (
    tester,
  ) async {
    var reads = 0;
    final result = retryHistoryRead(() async {
      if (++reads < 3) throw StateError('database busy');
      return 'saved records';
    });
    await tester.pump();
    expect(reads, 1);
    await tester.pump(const Duration(milliseconds: 200));
    expect(reads, 2);
    await tester.pump(const Duration(milliseconds: 399));
    expect(reads, 2);
    await tester.pump(const Duration(milliseconds: 1));
    expect(await result, 'saved records');
    expect(reads, 3);
  });

  testWidgets(
    'deadline retries reuse pending read and accept its late result',
    (tester) async {
      var reads = 0;
      final pending = Completer<String>();
      final result = retryHistoryRead(() {
        reads++;
        return pending.future;
      });
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 200));
      expect(reads, 1);
      pending.complete('late records');
      await tester.pump();
      expect(await result, 'late records');
    },
  );

  testWidgets('completed source timeout starts another read', (tester) async {
    var reads = 0;
    final result = retryHistoryRead(() async {
      if (++reads == 1) throw TimeoutException('native database timeout');
      return 'recovered records';
    });
    final assertion = expectLater(result, completion('recovered records'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));
    await assertion;
    expect(reads, 2);
  });
}
