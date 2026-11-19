import 'package:easysave/services/history_db.dart';
import 'package:easysave/services/media_delete_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('build 69: DeletionCounts formatting', () {
    test('live only formats correctly', () {
      final counts3 = DeletionCounts(images: 0, videos: 0, livePhotos: 3);
      expect(counts3.format(), '3 个实况（共 6 个文件）');
      expect(counts3.totalItems, 3);
      expect(counts3.totalFiles, 6);

      final counts1 = DeletionCounts(images: 0, videos: 0, livePhotos: 1);
      expect(counts1.format(), '1 个实况（共 2 个文件）');
      expect(counts1.totalItems, 1);
      expect(counts1.totalFiles, 2);
    });

    test('mixed live + images / videos formats correctly', () {
      final mixed1 = DeletionCounts(images: 2, videos: 0, livePhotos: 3);
      expect(mixed1.format(), '2 张图片、3 个实况（共 8 个文件）');
      expect(mixed1.totalItems, 5);
      expect(mixed1.totalFiles, 8);

      final mixed2 = DeletionCounts(images: 0, videos: 1, livePhotos: 3);
      expect(mixed2.format(), '1 个视频、3 个实况（共 7 个文件）');
      expect(mixed2.totalItems, 4);
      expect(mixed2.totalFiles, 7);

      final mixed3 = DeletionCounts(images: 2, videos: 1, livePhotos: 3);
      expect(mixed3.format(), '2 张图片、1 个视频、3 个实况（共 9 个文件）');
      expect(mixed3.totalItems, 6);
      expect(mixed3.totalFiles, 9);
    });

    test('non-live keeps fallback format', () {
      final nonLiveImages = DeletionCounts(images: 2, videos: 0, livePhotos: 0);
      expect(nonLiveImages.format(), '2 张图片');
      expect(nonLiveImages.format(nonLiveFallback: '2 项'), '2 项');

      final nonLiveEmpty = DeletionCounts(images: 0, videos: 0, livePhotos: 0);
      expect(nonLiveEmpty.format(), '0 项');
      expect(nonLiveEmpty.format(nonLiveFallback: '0 项'), '0 项');
    });
  });

  group('build 69: records deletion counts & MediaStore file match', () {
    HistoryRecord createLivePost(String postId, int liveCount, {int imageCount = 0}) {
      final files = <HistoryFile>[];
      var idx = 1;
      for (var i = 0; i < imageCount; i++) {
        files.add(
          HistoryFile(
            filename: 'post_${idx}.jpg',
            savedAt: 100000,
            mediaId: 'media_img_$idx',
            itemIndex: idx,
            isImage: true,
            status: FileStatus.found,
          ),
        );
        idx++;
      }
      for (var i = 0; i < liveCount; i++) {
        final pairId = '$postId#$idx';
        files.add(
          HistoryFile(
            filename: 'post_${idx}.jpg',
            savedAt: 100000,
            mediaId: 'media_still_$idx',
            itemIndex: idx,
            isImage: true,
            pairId: pairId,
            status: FileStatus.found,
          ),
        );
        files.add(
          HistoryFile(
            filename: 'post_${idx}.mp4',
            savedAt: 100000,
            mediaId: 'media_clip_$idx',
            itemIndex: idx,
            isImage: false,
            pairId: pairId,
            status: FileStatus.found,
          ),
        );
        idx++;
      }

      return HistoryRecord(
        platform: 'xhs',
        postId: postId,
        postUrl: 'https://xhs.com/$postId',
        fileCount: files.length,
        createdAt: DateTime.now(),
        files: files,
      );
    }

    test('3 live photos counts 3 items, 6 files matching deletableMediaFor', () {
      final post = createLivePost('p1', 3);
      final counts = deletionCountsForRecords([post]);

      expect(counts.livePhotos, 3);
      expect(counts.images, 0);
      expect(counts.totalItems, 3);
      expect(counts.totalFiles, 6);
      expect(counts.format(), '3 个实况（共 6 个文件）');

      // Crucial invariant: totalFiles must match MediaStore media list length!
      final mediaRefs = deletableMediaFor([post]);
      expect(mediaRefs.length, counts.totalFiles);
      expect(mediaRefs.length, 6);
    });

    test('mixed 2 images + 3 live photos counts 5 items, 8 files matching deletableMediaFor', () {
      final post = createLivePost('p2', 3, imageCount: 2);
      final counts = deletionCountsForRecords([post]);

      expect(counts.livePhotos, 3);
      expect(counts.images, 2);
      expect(counts.totalItems, 5);
      expect(counts.totalFiles, 8);
      expect(counts.format(), '2 张图片、3 个实况（共 8 个文件）');

      final mediaRefs = deletableMediaFor([post]);
      expect(mediaRefs.length, counts.totalFiles);
      expect(mediaRefs.length, 8);
    });
  });
}

