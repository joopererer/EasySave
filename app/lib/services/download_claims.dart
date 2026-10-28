import 'dart:io';
import 'package:flutter/services.dart';

class AlreadyDownloading implements Exception {
  @override
  String toString() => '已在下载中';
}

/// Android's registry is shared by both engines; desktop uses this isolate's
/// registry, allowing the same orchestration to run in JVM-free Flutter tests.
class DownloadClaims {
  static const _channel = MethodChannel('easysave/download_control');
  static final _owners = <String, String>{};
  static Future<List<String>> reserve(
    String batch,
    List<String> keys,
    Map<String, String> existing,
  ) async {
    if (Platform.isAndroid) {
      return (await _channel
          .invokeListMethod<String>('reserve', {
            'batch': batch,
            'keys': keys,
            'existing': existing,
          })
          .timeout(const Duration(seconds: 5)))!;
    }
    for (final entry in existing.entries) {
      _owners.putIfAbsent(entry.key, () => entry.value);
    }
    return keys.where((key) {
      if (_owners[key] != null && _owners[key] != batch) return false;
      _owners[key] = batch;
      return true;
    }).toList();
  }

  static Future<void> release(String batch) async {
    if (Platform.isAndroid) {
      await _channel
          .invokeMethod<void>('release', {'batch': batch})
          .timeout(const Duration(seconds: 5));
    } else {
      _owners.removeWhere((key, owner) => owner == batch);
    }
  }
}

String downloadIdentity(
  String platform,
  String postId,
  int itemIndex,
  bool isImage,
) => '$platform:$postId:$itemIndex:${isImage ? "image" : "video"}';

String downloadTempDirectory(String batchId, String jobKey) =>
    'easysave/${Uri.encodeComponent(batchId)}/${Uri.encodeComponent(jobKey)}';
