import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../core/dev_log.dart';
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
  } catch (error) {
    if (await file.exists()) await file.delete();
    unawaited(DevLog.write(
      'PreviewPlayer',
      'event=failed source=network type=${playbackFailureType(error)}',
    ));
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

/// Log-safe type of a playback failure.
///
/// Never the source and never the native message: `video_player` puts the URL
/// into both `VideoPlayerValue.errorDescription` and the exception it throws, so
/// only a stable token leaves this function.
String playbackFailureType(Object? error) {
  if (error == null) return 'unknown';
  if (error is MediaPolicyException) return 'policy:${_tokenOf(error.code)}';
  if (error is PlatformException) return 'platform:${_tokenOf(error.code)}';
  if (error is FileSystemException) {
    final message = error.message.trim();
    final local = RegExp(r'^[A-Z][A-Z_]{2,40}$').hasMatch(message);
    return 'file:${local ? message : 'io'}';
  }
  if (error is TimeoutException) return 'timeout';
  if (error is MissingPluginException) return 'no_plugin';
  if (error is FormatException) return 'format';
  return _tokenOf(error.runtimeType.toString());
}

String _tokenOf(String value) =>
    RegExp(r'^[A-Za-z0-9_.-]{1,48}$').hasMatch(value) ? value : 'error';
