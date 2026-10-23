// Copyright 2026 EasySave. All rights reserved.
// Tests for ProvenanceBuilder capturedAt parameter.

import 'package:flutter_test/flutter_test.dart';
import 'package:provenance_dart/provenance_dart.dart';

void main() {
  group('ProvenanceBuilder.capturedAt', () {
    test('uses capturedAt when provided', () {
      final captureTime = DateTime.utc(2025, 01, 15, 10, 30, 0);
      final builder = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.8.0',
        sourceId: 'test123',
        sourceUrl: 'https://example.com/test123',
        itemIndex: 1,
        itemCount: 2,
        capturedAt: captureTime,
      );

      final result = builder.build();
      expect(result.capturedAt, captureTime);
    });

    test('uses current time when capturedAt is null', () {
      final beforeBuild = DateTime.now();
      final builder = ProvenanceBuilder(
        platform: 'xiaohongshu',
        capturedBy: 'EasySave/1.8.0',
        sourceId: 'test123',
        sourceUrl: 'https://example.com/test123',
        itemIndex: 1,
        itemCount: 2,
      );

      final result = builder.build();
      final afterBuild = DateTime.now();

      expect(result.capturedAt.isAfter(beforeBuild.subtract(const Duration(seconds: 1))), isTrue);
      expect(result.capturedAt.isBefore(afterBuild.add(const Duration(seconds: 1))), isTrue);
    });
  });
}
