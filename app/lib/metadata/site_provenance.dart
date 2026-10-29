import 'package:provenance_dart/provenance_dart.dart';

import '../services/site_registry.dart';

/// Shared manifest rules for downloads and old-file backfill. Callers retain
/// their existing indexing, pair IDs and evidence about missing history fields.
XmpProvenance buildSiteProvenance({
  required String platform,
  required String capturedBy,
  required String sourceId,
  required String sourceUrl,
  String? authorName,
  String? title,
  String? caption,
  String? aiLabel,
  String? aiLabelSource,
  String? authorId,
  DateTime? publishedAt,
  required int itemIndex,
  required int itemCount,
  String? existingAssetId,
  DateTime? capturedAt,
}) {
  final site = SiteRegistry.current.byId(platform);
  return ProvenanceBuilder(
    platform: site?.platform ?? platform,
    capturedBy: capturedBy,
    sourceId: sourceId,
    sourceUrl: sourceUrl,
    authorName: authorName,
    title: title,
    caption: caption,
    aiLabel: aiLabel,
    aiLabelSource: aiLabelSource,
    authorId: site?.allowsAuthorId(authorId) == true ? authorId : null,
    creditPlatformName: site?.creditName ?? platform,
    publishedAt: publishedAt,
    itemIndex: itemIndex,
    itemCount: itemCount,
    existingAssetId: existingAssetId,
    capturedAt: capturedAt,
  ).build();
}
