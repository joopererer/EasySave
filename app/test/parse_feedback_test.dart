import 'package:easysave/core/error_copy.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/widgets/parse_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(void Function(BuildContext) onTap) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => onTap(context),
        child: const Text('go'),
      ),
    ),
  ),
);

void main() {
  group('displayErrorMessage', () {
    test('prefers the engine message when present', () {
      expect(
        displayErrorMessage(ParseErrorCode.timeout, 'custom text'),
        'custom text',
      );
    });

    test('falls back to the spec copy for null or empty messages', () {
      final spec = errorCopyFor(ParseErrorCode.timeout).message;
      expect(displayErrorMessage(ParseErrorCode.timeout, null), spec);
      expect(displayErrorMessage(ParseErrorCode.timeout, ''), spec);
    });
  });

  group('parse feedback snackbars', () {
    testWidgets('parsing snackbar shows progress and a cancel action', (
      tester,
    ) async {
      var cancelled = false;
      await tester.pumpWidget(
        _host(
          (c) => showParsingSnackBar(c, onCancel: () => cancelled = true),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('解析中…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.text('取消'));
      expect(cancelled, isTrue);
    });

    testWidgets('error snackbar shows the message and a view action', (
      tester,
    ) async {
      var viewed = false;
      await tester.pumpWidget(
        _host(
          (c) => showParseErrorSnackBar(
            c,
            code: ParseErrorCode.timeout,
            onView: () => viewed = true,
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text(errorCopyFor(ParseErrorCode.timeout).message),
        findsOneWidget,
      );
      await tester.tap(find.text('查看'));
      expect(viewed, isTrue);
    });

    testWidgets('error snackbar replaces the parsing snackbar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host((c) {
          showParsingSnackBar(c, onCancel: () {});
          showParseErrorSnackBar(
            c,
            code: ParseErrorCode.blocked,
            message: '被限制了',
            onView: () {},
          );
        }),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('被限制了'), findsOneWidget);
      expect(find.text('解析中…'), findsNothing);
    });
  });
}
