import 'dart:io';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import '../metadata/metadata_service.dart';

const _channel = MethodChannel('easysave/provenance_pair');

Future<({String? mediaId, String? title, String? relativePath})> saveProvenancePair(
  String path, String album,
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
    'path': path, 'album': album, 'mime': mime,
  });
  if (result?['mediaId'] == null) throw StateError('来源信息边车保存失败');
  for (final file in [File(path), File('$path.xmp')]) {
    try { await file.delete(); } catch (_) { /* Saved pair is already verified. */ }
  }
  return (mediaId: result!['mediaId'], title: result['title'], relativePath: result['relativePath']);
}

Future<XmpProvenance?> readProvenanceSidecar(String mediaId) async {
  try {
    final xml = await _channel.invokeMethod<String>('readSidecar', {'mediaId': mediaId});
    return xml == null ? null : parseXmpXml(xml);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  } on FormatException {
    return null;
  }
}
