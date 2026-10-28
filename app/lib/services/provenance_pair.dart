import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:photo_manager/photo_manager.dart';
import '../metadata/metadata_service.dart';
import 'download_provenance.dart';
import '../core/dev_log.dart';

const _channel = MethodChannel('easysave/provenance_pair');
const c2paRelativePath = 'Download/EasySave/';
const c2paSavedNotice = '该图片带有内容凭证，已保存到 Download/EasySave';

Future<({String? mediaId, String? title, String? relativePath})>
saveProvenancePair(String path, {String? expectedAssetId}) async {
  // Gal requests legacy WRITE_EXTERNAL_STORAGE only where Android requires it.
  if (!await Gal.hasAccess(toAlbum: true))
    await Gal.requestAccess(toAlbum: true);
  final format = await MetadataService.detectFormat(path);
  final mime = switch (format) {
    MediaFormat.jpeg => 'image/jpeg',
    MediaFormat.png => 'image/png',
    MediaFormat.webp => 'image/webp',
    MediaFormat.mp4 => 'video/mp4',
    _ => throw StateError('该格式无法写入来源信息'),
  };
  final result = await _channel.invokeMapMethod<String, String>('savePair', {
    'path': path,
    'mime': mime,
  });
  if (result?['mediaId'] == null) throw StateError('来源信息边车保存失败');
  if (expectedAssetId != null) {
    try {
      // Signed image bytes intentionally have no newly embedded provenance.
      final read = await readProvenanceSidecar(result!['mediaId']!);
      if (read?.assetId != expectedAssetId) {
        throw StateError(
          provenanceVerificationMessage(
            '${result['title'] ?? File(path).uri.pathSegments.last}.xmp',
            expectedAssetId,
            read?.assetId,
          ),
        );
      }
    } catch (e) {
      // System-saved media and sidecar form one unit, including Dart failures.
      try {
        await _channel.invokeMethod<void>('deletePair', {
          'mediaId': result!['mediaId'],
        });
      } catch (_) {
        throw StateError('$e；图片与边车成组清理失败');
      }
      rethrow;
    }
  }
  for (final file in [File(path), File('$path.xmp')]) {
    try {
      await file.delete();
    } catch (_) {
      /* Saved pair is already verified. */
    }
  }
  return (
    mediaId: result!['mediaId'],
    title: result['title'],
    relativePath: result['relativePath'],
  );
}

Future<XmpProvenance?> readProvenanceSidecar(String mediaId) async {
  final xml = await readProvenanceSidecarXml(mediaId);
  return xml == null ? null : mergeProvenanceXml(null, xml);
}

Future<String?> readProvenanceSidecarXml(String mediaId) async {
  try {
    return await _channel.invokeMethod<String>('readSidecar', {
      'mediaId': mediaId,
    });
  } on MissingPluginException {
    return null;
  } on PlatformException {
    rethrow;
  } on FormatException {
    rethrow;
  }
}

class SidecarReadResult {
  const SidecarReadResult({this.xml, required this.status, required this.found,
    required this.stage, this.errorClass, this.requiresAccess = false});
  final String? xml, errorClass;
  final String status, stage;
  final bool found, requiresAccess;
}

Future<SidecarReadResult> readRebuildSidecar(AssetEntity asset, String? relativePath) async {
  try {
    Map<String, dynamic>? raw;
    try {
      raw = await _channel.invokeMapMethod<String, dynamic>('readSidecarDetailed', {
        'mediaId': asset.id, 'filename': asset.title, 'relativePath': relativePath,
      });
    } on MissingPluginException {
      if (Platform.isAndroid) rethrow;
    }
    if (raw != null) return SidecarReadResult(xml: raw['xml'] as String?, status: raw['status'] as String,
      found: raw['found'] == true, stage: raw['stage'] as String, errorClass: raw['errorClass'] as String?, requiresAccess: raw['requiresAccess'] == true);
    final xml = await readProvenanceSidecarXml(asset.id);
    return SidecarReadResult(xml: xml, status: xml == null ? 'not_found' : 'success', found: xml != null, stage: 'legacy-sidecar-read');
  } catch (e) {
    return SidecarReadResult(status: 'error', found: false, stage: 'sidecar-channel', errorClass: e.runtimeType.toString(), requiresAccess: e is PlatformException);
  }
}

Future<bool> authorizeFixedRebuildDirectory(String treeUri) async =>
    await _channel.invokeMethod<bool>('setFixedTree', {'treeUri': treeUri}) ?? false;

bool isFixedFileReference(String id) => id.startsWith('fixed:');
Future<Uint8List> readFixedRebuildHeader(String mediaId, String? mimeType) async =>
    await _channel.invokeMethod<Uint8List>('readFixedHeader', {'mediaId': mediaId, 'mimeType': mimeType}) ?? Uint8List(0);

Future<List<AssetEntity>> fixedC2paAssets() async {
  try {
    final rows =
        await _channel.invokeListMethod<dynamic>('queryFixedMedia') ?? [];
    for (final row in rows) {
      if (row is Map && row['diagnostic'] == true) {
        DevLog.write('HistoryRebuild', 'queryFixedMedia path=$c2paRelativePath file=${row['file'] ?? "-"} '
          'stage=${row['stage']} visible=${row['visible']} owned=${row['owned'] ?? "unknown"} '
          'count=${row['count'] ?? "-"} exception=${row['errorClass'] ?? "-"}');
      }
    }
    DevLog.write('HistoryRebuild', 'queryFixedMedia path=$c2paRelativePath returned=${rows.where((r) => r is Map && r["diagnostic"] != true).length}');
    return [
      for (final row in rows)
        if (row is Map &&
            row['relativePath'] == c2paRelativePath &&
            (row['typeInt'] == 1 || row['typeInt'] == 2))
          AssetEntity(
            id: row['id'] as String,
            typeInt: row['typeInt'] as int,
            width: row['width'] as int? ?? 0,
            height: row['height'] as int? ?? 0,
            title: row['title'] as String?,
            mimeType: row['mimeType'] as String?,
            relativePath: c2paRelativePath,
          ),
    ];
  } on MissingPluginException {
    if (Platform.isAndroid) rethrow;
    return [];
  }
}

List<AssetEntity> unionMedia(
  Iterable<AssetEntity> normal,
  Iterable<AssetEntity> fixed,
) => {
  for (final asset in [...normal, ...fixed]) asset.id: asset,
}.values.toList();
