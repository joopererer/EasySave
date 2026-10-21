// Copyright 2026 EasySave. All rights reserved.
// Tests for rebuild description and recovery messaging.

import 'package:flutter_test/flutter_test.dart';

import 'package:easysave/services/history_rebuild_service.dart';

void main() {
  group('RebuildResult', () {
    test('message indicates merge includes recovery', () {
      final result = RebuildResult(
        total: 100,
        processed: 100,
        created: 20,
        merged: 30,
        skipped: 50,
      );

      final msg = result.toString();
      expect(msg, contains('100/100 processed'));
      expect(msg, contains('20 new'));
      expect(msg, contains('30 merged (including recovered)'));
      expect(msg, contains('50 skipped'));
    });
  });
}
