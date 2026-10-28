import 'package:easysave/core/models.dart';
import 'package:easysave/services/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TikTok preserves primary and all fallback URLs on initial and retry plans', () {
    final post = ParsedPost(
      platform: 'tiktok', id: '123', url: 'https://www.tiktok.com/@/video/123',
      author: PostAuthor(name: 'author'),
      items: [MediaItem(type: 'image', url: 'https://img/1',
        fallbacks: ['https://img/2', 'https://img/3', 'https://img/4'])],
    );
    final urls = ['https://img/1', 'https://img/2', 'https://img/3', 'https://img/4'];
    expect(planFiles(post, [0], (_, seq, ext) => 'file').single.urls, urls);
    expect(planFilesForItem(post, 0), urls);
    final job = DownloadJob(key: 'key', label: 'image', filename: 'image.jpg',
        urls: urls, isImage: true, itemIndex: 1);
    final batch = DownloadBatch(batchId: 'batch', album: 'album', postUrl: post.url,
        platform: post.platform, postId: post.id, jobs: [job]);
    expect(maxAttemptsFor(batch, job), 4);
    expect(decideStalledAction(nativeStatus: null, attempts: 3,
        maxAttempts: maxAttemptsFor(batch, job)), StalledAction.retry);
    expect(decideStalledAction(nativeStatus: null, attempts: 4,
        maxAttempts: maxAttemptsFor(batch, job)), StalledAction.fail);
  });
}
