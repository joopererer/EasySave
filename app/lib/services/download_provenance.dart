import 'package:provenance_dart/provenance_dart.dart' as pkg;
import 'dart:io';
import '../metadata/metadata_service.dart';
import 'media_content_type.dart';

/// Returns true when credentials must travel in a same-directory sidecar.
/// A successful save must never conceal a metadata write failure.
Future<bool> prepareDownloadProvenance(
  String path,
  XmpProvenance provenance,
) async {
  // provenance_dart picks its writer from the container, and every ISO-BMFF
  // file (HEIC included) looks like MP4 to it — appending a video `uuid` box
  // to a still. Refuse a still it cannot embed into instead of corrupting it.
  final type = await sniffMediaFile(path);
  if (type != null && type.isImage && !_embeddableImage(type)) {
    throw StateError('该格式无法写入来源信息');
  }
  if (type != null && type.isVideo && type.playable == false) {
    throw StateError('该格式无法写入来源信息');
  }
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

/// Whether provenance_dart can embed into this still container. It has XMP
/// writers for JPEG, PNG and WebP only; a HEIC / AVIF / GIF still must not go
/// through the MP4 writer.
bool _embeddableImage(MediaContentType type) =>
    const {'jpg', 'jpeg', 'png', 'webp'}.contains(type.extension);

String provenanceVerificationMessage(
  String path,
  String? expected,
  String? actual,
) =>
    '来源信息回读校验失败；文件=${File(path).uri.pathSegments.last}；'
    '期望assetId存在=${expected?.isNotEmpty == true}；'
    '实际assetId存在=${actual?.isNotEmpty == true}；assetId一致=${expected != null && expected == actual}';
