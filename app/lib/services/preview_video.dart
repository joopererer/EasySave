import 'package:video_player/video_player.dart';
import 'auth.dart';
import 'saver.dart';

/// These headers belong only to the current player, never to post/job JSON.
Future<Map<String, String>> previewVideoHeaders(String platform, {
  Future<String> Function(List<String>)? readCookie,
}) async {
  final headers = <String, String>{'Referer': refererFor(platform)};
  if (platform == 'tiktok') {
    final cookie = await (readCookie ?? cookieHeaderFor)(['https://www.tiktok.com/']);
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
  }
  return headers;
}

Future<VideoPlayerController> networkPreviewController(String url, String platform) async =>
    VideoPlayerController.networkUrl(Uri.parse(url), httpHeaders: await previewVideoHeaders(platform));

String previewPlaybackError(String platform) => platform == 'tiktok'
    ? 'TikTok 在线预览可能受平台限制，请下载后观看'
    : '暂时无法播放，请重试或下载后观看';
