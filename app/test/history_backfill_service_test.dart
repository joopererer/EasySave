// Copyright 2026 EasySave. All rights reserved.
// Tests for backfill DevLog categorization by skip reason.

import 'package:flutter_test/flutter_test.dart';

import 'package:easysave/services/history_backfill_service.dart';

void main() {
  group('BackfillResult', () {
    test('breakdown message includes detailed skip reasons', () {
      final result = BackfillResult(
        totalFiles: 110,
        total: 100,
        success: 50,
        authRequired: 10,
        alreadyHasMetadata: 20,
        fileNotFound: 10,
        noWritePermission: 5,
        formatNotSupported: 3,
        skippedVideo: 8,
        skippedNotLocated: 2,
        otherError: 2,
      );

      final msg = result.toString();
      expect(msg, contains('50/100 written'));
      expect(msg, contains('10 required permission'));
      expect(msg, contains('20 already had metadata'));
      expect(msg, contains('10 file not found'));
      expect(msg, contains('5 no write permission'));
      expect(msg, contains('3 format not supported'));
      expect(msg, contains('8 video'));
      expect(msg, contains('2 not located'));
      expect(msg, contains('2 other errors'));
    });

    test('skipped getter sums all skip categories', () {
      final result = BackfillResult(
        totalFiles: 110,
        total: 100,
        success: 50,
        authRequired: 10,
        alreadyHasMetadata: 20,
        fileNotFound: 10,
        noWritePermission: 5,
        formatNotSupported: 3,
        skippedVideo: 8,
        skippedNotLocated: 2,
        otherError: 2,
      );

      // skipped = already + notFound + noWrite + formatNotSupported + video + notLocated + other
      expect(result.skipped, 50); // 20 + 10 + 5 + 3 + 8 + 2 + 2
      expect(result.success + result.authRequired + result.skipped, 110);
    });

    test('omits zero-count reasons from message', () {
      final result = BackfillResult(
        totalFiles: 50,
        total: 50,
        success: 50,
        authRequired: 0,
        alreadyHasMetadata: 0,
        fileNotFound: 0,
        noWritePermission: 0,
        formatNotSupported: 0,
        skippedVideo: 0,
        skippedNotLocated: 0,
        otherError: 0,
      );

      final msg = result.toString();
      expect(msg, '50/50 written');
      expect(msg.split(',').length, 1); // Only one part
    });
  });
}
