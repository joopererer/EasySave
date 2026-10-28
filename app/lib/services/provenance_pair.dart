import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:photo_manager/photo_manager.dart';
import '../metadata/metadata_service.dart';
import 'download_provenance.dart';
import '../core/dev_log.dart';
import 'media_delete_service.dart';

const _channel = MethodChannel('easysave/provenance_pair');
const c2paRelativePath = 'Download/EasySave/';
const c2paSavedNotice = '该图片带有内容凭证，已保存到 Download/EasySave';

Future<({String? mediaId, String? title, String? relativePath})>
saveProvenancePair(String path, {String? expectedAssetId, String? finalName}) async {
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
    'filename': finalName ?? File(path).uri.pathSegments.last,
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

class LegacyRepairResult {
  const LegacyRepairResult({this.renamed = 0, this.skipped = 0, this.failures = 0, this.requiresAccess = false, this.changedIds = const []});
  final int renamed, skipped, failures;
  final bool requiresAccess;
  final List<String> changedIds;
}

Future<LegacyRepairResult> repairLegacyExportNames(Iterable<String> albums) async {
  try {
    Future<List<dynamic>> run() async => await _channel.invokeListMethod<dynamic>('repairLegacyNames', {'albums': albums.toList()}) ?? [];
    var rows = await run();
    final writable = <MediaRef>[];
    for (final row in rows.whereType<Map>()) {
      if (row['status'] == 'error' && '${row['path']}'.startsWith('Pictures/') && row['mediaId'] is String &&
          '${row['errorClass']}'.contains('SecurityException')) {
        writable.add(MediaRef(mediaId: row['mediaId'] as String, isImage: row['isImage'] == true));
      }
    }
    if (writable.isNotEmpty && await MediaDeleteService.instance.requestWriteAccess(writable)) {
      final priorSuccess = rows.whereType<Map>().where((r) => r['status'] == 'renamed').toList();
      rows = [...priorSuccess, ...await run()];
    }
    var renamed = 0, skipped = 0, failures = 0;
    var access = false;
    final changed = <String>[];
    for (final row in rows.whereType<Map>()) {
      final status = row['status'];
      DevLog.write('HistoryRebuild', 'file=${row['file']} path=${row['path']} stage=legacy-name-repair '
        'result=$status target=${row['target'] ?? "-"} exception=${row['errorClass'] ?? "-"} candidates=${row['candidates'] ?? "-"}');
      if (status == 'renamed') renamed++;
      if (status == 'target_exists' || status == 'missing_sidecar') skipped++;
      if (status == 'error' || status == 'rollback_failed') failures++;
      access |= row['requiresAccess'] == true;
      if (status == 'renamed' && row['mediaId'] is String) {
        changed.add(row['mediaId'] as String);
      }
    }
    return LegacyRepairResult(renamed: renamed, skipped: skipped, failures: failures, requiresAccess: access, changedIds: changed);
  } on MissingPluginException {
    if (!Platform.isAndroid) return const LegacyRepairResult();
    DevLog.write('HistoryRebuild', 'file=<directory> path=$c2paRelativePath stage=legacy-name-repair exception=MissingPluginException');
    return const LegacyRepairResult(failures: 1);
  } catch (e) {
    DevLog.write('HistoryRebuild', 'file=<directory> path=$c2paRelativePath stage=legacy-name-repair exception=${e.runtimeType}');
    return const LegacyRepairResult(failures: 1);
  }
}

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
