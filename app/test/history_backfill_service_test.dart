// Copyright 2026 EasySave. All rights reserved.
// Tests for backfill DevLog categorization by skip reason.

import 'package:flutter_test/flutter_test.dart';

import 'package:easysave/services/history_backfill_service.dart';

void main() {
  group('BackfillResult', () {
    test('breakdown message includes detailed skip reasons', () {
      final result = BackfillResult(
        total: 100,
        success: 50,
        authRequired: 10,
        alreadyHasMetadata: 20,
        fileNotFound: 10,
        noWritePermission: 5,
        formatNotSupported: 3,
        otherError: 2,
      );

      final msg = result.toString();
      expect(msg, contains('50/100 written'));
      expect(msg, contains('10 required permission'));
      expect(msg, contains('20 already had metadata'));
      expect(msg, contains('10 file not found'));
      expect(msg, contains('5 no write permission'));
      expect(msg, contains('3 format not supported'));
      expect(msg, contains('2 other errors'));
    });

    test('skipped getter sums all skip categories', () {
      final result = BackfillResult(
        total: 100,
        success: 50,
        authRequired: 10,
        alreadyHasMetadata: 20,
        fileNotFound: 10,
        noWritePermission: 5,
        formatNotSupported: 3,
        otherError: 2,
      );

      expect(result.skipped, 40); // 20 + 10 + 5 + 3 + 2 (authRequired is not part of skipped)
      expect(result.success + result.authRequired + result.skipped, 100);
    });

    test('omits zero-count reasons from message', () {
      final result = BackfillResult(
        total: 50,
        success: 50,
        authRequired: 0,
        alreadyHasMetadata: 0,
        fileNotFound: 0,
        noWritePermission: 0,
        formatNotSupported: 0,
        otherError: 0,
      );

      final msg = result.toString();
      expect(msg, '50/50 written');
      expect(msg.split(',').length, 1); // Only one part
    });
  });
}
