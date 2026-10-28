import 'package:provenance_dart/provenance_dart.dart' as pkg;
import 'dart:io';
import '../metadata/metadata_service.dart';

/// Returns true when credentials must travel in a same-directory sidecar.
/// A successful save must never conceal a metadata write failure.
Future<bool> prepareDownloadProvenance(
  String path,
  XmpProvenance provenance,
) async {
  final result = await MetadataService.embedProvenance(
    filePath: path,
    provenance: provenance,
    checkC2pa: true,
    mp4WriteMode: Mp4WriteMode.rewrite,
  );
  final sidecar = result.errorCode == EmbedErrorCode.c2paDetected;
  if (sidecar) {
    // Download staging belongs to this task. Reusing another attempt's XMP
    // preserves immutable capture fields (including the old assetId).
    final stale = File('$path.xmp');
    if (await stale.exists()) await stale.delete();
    await pkg.MetadataService.writeSidecar(path, provenance);
  } else if (!result.success) {
    if (result.errorCode == EmbedErrorCode.formatUnsupported) {
      throw StateError('该格式无法写入来源信息');
    }
    throw StateError('来源信息写入失败，请重试');
  }
  final read = sidecar
      ? await pkg.MetadataService.readSidecar(path)
      : await pkg.MetadataService.readEmbedded(path);
  if (read == null ||
      read.platform != provenance.platform ||
      read.sourceId != provenance.sourceId ||
      read.assetId != provenance.assetId ||
      read.aiLabel != provenance.aiLabel ||
      read.aiLabelSource != provenance.aiLabelSource) {
    throw StateError(
      provenanceVerificationMessage(
        sidecar ? '$path.xmp' : path,
        provenance.assetId,
        read?.assetId,
      ),
    );
  }
  return sidecar;
}

String provenanceVerificationMessage(
  String path,
  String? expected,
  String? actual,
) =>
    '来源信息回读校验失败；文件=${File(path).uri.pathSegments.last}；'
    '期望assetId存在=${expected?.isNotEmpty == true}；'
    '实际assetId存在=${actual?.isNotEmpty == true}；assetId一致=${expected != null && expected == actual}';
