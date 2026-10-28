import 'dart:io';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:photo_manager/photo_manager.dart';
import '../metadata/metadata_service.dart';

const _channel = MethodChannel('easysave/provenance_pair');
const c2paRelativePath = 'Download/EasySave/';
const c2paSavedNotice = '该图片带有内容凭证，已保存到 Download/EasySave';

Future<({String? mediaId, String? title, String? relativePath})> saveProvenancePair(
  String path,
) async {
  // Gal requests legacy WRITE_EXTERNAL_STORAGE only where Android requires it.
  if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
  final format = await MetadataService.detectFormat(path);
  final mime = switch (format) {
    MediaFormat.jpeg => 'image/jpeg',
    MediaFormat.png => 'image/png',
    MediaFormat.webp => 'image/webp',
    MediaFormat.mp4 => 'video/mp4',
    _ => throw StateError('该格式无法写入来源信息'),
  };
  final result = await _channel.invokeMapMethod<String, String>('savePair', {
    'path': path, 'mime': mime,
  });
  if (result?['mediaId'] == null) throw StateError('来源信息边车保存失败');
  for (final file in [File(path), File('$path.xmp')]) {
    try { await file.delete(); } catch (_) { /* Saved pair is already verified. */ }
  }
  return (mediaId: result!['mediaId'], title: result['title'], relativePath: result['relativePath']);
}

Future<XmpProvenance?> readProvenanceSidecar(String mediaId) async {
  final xml = await readProvenanceSidecarXml(mediaId);
  return xml == null ? null : mergeProvenanceXml(null, xml);
}

Future<String?> readProvenanceSidecarXml(String mediaId) async {
  try {
    return await _channel.invokeMethod<String>('readSidecar', {'mediaId': mediaId});
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  } on FormatException {
    return null;
  }
}

Future<List<AssetEntity>> fixedC2paAssets() async {
  try {
    final rows = await _channel.invokeListMethod<dynamic>('queryFixedMedia') ?? [];
    return [for (final row in rows)
      if (row is Map && row['relativePath'] == c2paRelativePath &&
          (row['typeInt'] == 1 || row['typeInt'] == 2))
        AssetEntity(id: row['id'] as String, typeInt: row['typeInt'] as int,
          width: row['width'] as int? ?? 0, height: row['height'] as int? ?? 0,
          title: row['title'] as String?, mimeType: row['mimeType'] as String?, relativePath: c2paRelativePath),
    ];
  } on MissingPluginException {
    return [];
  }
}

List<AssetEntity> unionMedia(Iterable<AssetEntity> normal, Iterable<AssetEntity> fixed) =>
    {for (final asset in [...normal, ...fixed]) asset.id: asset}.values.toList();
