// Copyright 2026 EasySave. All rights reserved.
// v1.12, Task 2: Raw exception message sanitization and login action for unclassified errors.

import 'package:easysave/core/error_copy.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:easysave/widgets/shared.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SiteRegistry.useBuiltin();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(SiteRegistry.useBuiltin);

  group('Raw exception sanitization (displayErrorMessage)', () {
    final rawExceptions = [
      'FormatException: Invalid parser hook result',
      'FormatException: Unexpected character (at character 1)',
      'Bad state: No element',
      'Bad state: Stream has already been listened to.',
      'PlatformException(error, channel unavailable, null, null)',
      'StateError: Value is already disposed',
      'TypeError: type "Null" is not a subtype of type "String"',
      'RangeError (index): Index out of range: index should be less than 5: 10',
      'ArgumentError: Invalid argument: null',
      'NoSuchMethodError: The getter "foo" was called on null',
      'Null check operator used on a null value',
      'Exception: Network connection dropped',
      'Error: Assertion failed: foo != null\n#0 main (test.dart:10:5)',
    ];

    for (final raw in rawExceptions) {
      test('sanitizes "$raw" and hides exception name', () {
        expect(isRawExceptionMessage(raw), isTrue);
        final clean = displayErrorMessage(ParseErrorCode.invalidPage, raw);
        expect(clean, isNot(contains('Exception')));
        expect(clean, isNot(contains('Error')));
        expect(clean, isNot(contains('Bad state')));
        expect(clean, isNot(contains('#0')));
        expect(clean, isNot(contains('FormatException')));
        expect(clean, isNot(contains('PlatformException')));
        expect(clean, '页面内容无法识别，可能已改版');
      });
    }

    test('preserves legitimate user-facing error messages from the parser', () {
      const normalMsg = '需要先登录小红书才能解析该笔记';
      expect(isRawExceptionMessage(normalMsg), isFalse);
      expect(
        displayErrorMessage(ParseErrorCode.loginRequired, normalMsg),
        normalMsg,
      );
    });
  });

  group('Unclassified error on known sites needing login', () {
    testWidgets('shows both 重试 and 去登录 when user is not logged in', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ErrorCard(
              code: ParseErrorCode.invalidPage,
              message: 'FormatException: Invalid parser hook result',
              canLogin: true,
              showLoginAction: true, // App determined unclassified error & user not logged in
              onAction: (_) async {},
            ),
          ),
        ),
      );

      // Clean message displayed
      expect(find.text('页面内容无法识别，可能已改版'), findsOneWidget);
      expect(find.textContaining('FormatException'), findsNothing);

      // Both 重试 and 去登录 are provided
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('去登录'), findsOneWidget);
    });

    testWidgets('shows only 重试 when showLoginAction is false (e.g. already logged in)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ErrorCard(
              code: ParseErrorCode.invalidPage,
              canLogin: true,
              showLoginAction: false,
              onAction: (_) async {},
            ),
          ),
        ),
      );

      expect(find.text('重试'), findsOneWidget);
      expect(find.text('去登录'), findsNothing);
    });
  });
}
