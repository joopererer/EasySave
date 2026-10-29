import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../core/models.dart';
import 'authorized_media_http.dart';
import 'media_request_policy.dart';
import 'site_registry.dart';

/// A player cannot expose its redirect hops. Fetch through the policy first,
/// then play a local cache file so no player request can bypass authorization.
Future<VideoPlayerController> networkPreviewController(
  String url,
  String platform, {
  MediaItem? item,
}) async {
  final site = SiteRegistry.current.byId(platform);
  if (site == null) {
    throw const MediaPolicyException('REQUEST_SITE_REJECTED', '');
  }
  final policy = MediaRequestPolicy(site);
  final media = item ?? MediaItem(type: 'video', url: url);
  final resources = policy.resourcesFor(media);
  final resource = resources.where((r) => r.url == url).firstOrNull;
  if (resource == null) {
    policy.rejectResource(url);
  }
  final dir = await getTemporaryDirectory();
  final file = File(
    '${dir.path}/policy_preview_${DateTime.now().microsecondsSinceEpoch}.mp4',
  );
  final client = http.Client();
  try {
    final response = await sendAuthorizedMediaGet(client, policy, resource);
    if (response.statusCode != 200) {
      throw const FileSystemException('PREVIEW_HTTP_FAILED');
    }
    final sink = file.openWrite();
    var bytes = 0;
    try {
      await for (final chunk in response.stream) {
        bytes += chunk.length;
        if (bytes > 512 * 1024 * 1024) {
          throw const FileSystemException('PREVIEW_TOO_LARGE');
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    if (bytes == 0) throw const FileSystemException('PREVIEW_EMPTY');
    return VideoPlayerController.file(file);
  } catch (_) {
    if (await file.exists()) await file.delete();
    rethrow;
  } finally {
    client.close();
  }
}

String previewPlaybackError(String platform) =>
    SiteRegistry.current.byId(platform)?.data['previewErrorMessage']
        as String? ??
    '暂时无法播放，请重试或下载后观看';

String previewFailureMessage(Object error, String platform) =>
    error is MediaPolicyException
    ? '该资源地址不在允许范围内'
    : previewPlaybackError(platform);
