// Copyright 2026 EasySave. All rights reserved.
// Tests for EasySave Provenance construction and business rules.

import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/services/download_manager.dart';
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

  group('EasySave provenanceForBatchItem rules', () {
    DownloadBatch createBatch({
      required String platform,
      String? authorName,
      String? authorId,
    }) {
      return DownloadBatch(
        batchId: 'batch1',
        album: 'EasySave',
        postUrl: 'https://example.com/post',
        platform: platform,
        postId: 'post123',
        authorName: authorName,
        authorId: authorId,
        jobs: [],
      );
    }

    test('maps platform xhs to spec platform xiaohongshu', () {
      final batch = createBatch(platform: 'xhs');
      final prov = provenanceForBatchItem(batch, itemIndex: 1);
      expect(prov.platform, 'xiaohongshu');
    });

    test('sets credit using localized display name for xhs, instagram, and x', () {
      final xhsBatch = createBatch(platform: 'xhs', authorName: '测试用户');
      expect(provenanceForBatchItem(xhsBatch, itemIndex: 1).credit, '测试用户 / 小红书');

      final igBatch = createBatch(platform: 'instagram', authorName: 'TestUser');
      expect(provenanceForBatchItem(igBatch, itemIndex: 1).credit, 'TestUser / Instagram');

      final xBatch = createBatch(platform: 'x', authorName: 'XUser');
      expect(provenanceForBatchItem(xBatch, itemIndex: 1).credit, 'XUser / X');
    });

    test('skips non-numeric authorId on X platform (username)', () {
      final batch = createBatch(platform: 'x', authorId: 'n8_AIart');
      final prov = provenanceForBatchItem(batch, itemIndex: 1);
      expect(prov.authorId, isNull);
    });

    test('preserves numeric authorId on X platform', () {
      final batch = createBatch(platform: 'x', authorId: '1234567890');
      final prov = provenanceForBatchItem(batch, itemIndex: 1);
      expect(prov.authorId, '1234567890');
    });

    test('preserves authorId for non-X platforms', () {
      final xhsBatch = createBatch(platform: 'xhs', authorId: 'user_str_id');
      expect(provenanceForBatchItem(xhsBatch, itemIndex: 1).authorId, 'user_str_id');

      final igBatch = createBatch(platform: 'instagram', authorId: 'ig_user_123');
      expect(provenanceForBatchItem(igBatch, itemIndex: 1).authorId, 'ig_user_123');
    });
  });
}
