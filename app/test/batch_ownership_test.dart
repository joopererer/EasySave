import 'package:easysave/services/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadBatch _batch({
  String source = DownloadBatch.sourceMain,
  int updatedAt = 0,
}) {
  return DownloadBatch(
    batchId: '$source-1700000000000',
    album: 'EasySave',
    postUrl: 'https://www.xiaohongshu.com/explore/abc123',
    platform: 'xhs',
    postId: 'abc123',
    source: source,
    updatedAt: updatedAt,
    jobs: const [],
  );
}

void main() {
  group('batch source ownership', () {
    test('source survives the json round trip', () {
      final batch = _batch(
        source: DownloadBatch.sourceBackground,
        updatedAt: 42,
      );
      final restored = DownloadBatch.fromJson(batch.toJson());
      expect(restored.source, DownloadBatch.sourceBackground);
      expect(restored.updatedAt, 42);
    });

    test('legacy batches without a source belong to the main engine', () {
      final json = _batch().toJson()..remove('source');
      expect(DownloadBatch.fromJson(json).source, DownloadBatch.sourceMain);
    });

    test('an engine never adopts a batch of its own source', () {
      expect(
        canAdoptForeignBatch(
          owner: DownloadBatch.sourceMain,
          batchSource: DownloadBatch.sourceMain,
          updatedAt: 0,
          now: 10 * kStalledBatchAgeMs,
          allTasksTerminal: true,
        ),
        isFalse,
      );
    });

    test('a fresh foreign batch is left to its owner', () {
      final now = 1000000;
      expect(
        canAdoptForeignBatch(
          owner: DownloadBatch.sourceMain,
          batchSource: DownloadBatch.sourceBackground,
          updatedAt: now - 1000,
          now: now,
          allTasksTerminal: true,
        ),
        isFalse,
      );
    });

    test('a stale foreign batch with running tasks is not adopted', () {
      final now = 1000000;
      expect(
        canAdoptForeignBatch(
          owner: DownloadBatch.sourceMain,
          batchSource: DownloadBatch.sourceBackground,
          updatedAt: now - 10 * kStalledBatchAgeMs,
          now: now,
          allTasksTerminal: false,
        ),
        isFalse,
      );
    });

    test('a stale foreign batch whose tasks all finished is adopted', () {
      final now = 1000000;
      expect(
        canAdoptForeignBatch(
          owner: DownloadBatch.sourceMain,
          batchSource: DownloadBatch.sourceBackground,
          updatedAt: now - 10 * kStalledBatchAgeMs,
          now: now,
          allTasksTerminal: true,
        ),
        isTrue,
      );
    });
  });
}
