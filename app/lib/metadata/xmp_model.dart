// Copyright 2026 EasySave. All rights reserved.
// XMP provenance metadata model matching provenance-spec v0.1 §7.

/// XMP provenance metadata for a single image or video file.
/// Mirrors the JSON structure in provenance-spec v0.1 §7.
class XmpProvenance {
  final String schema;
  final String assetId;
  final DateTime capturedAt;
  final String capturedBy;
  final DateTime metadataDate;
  final String sourceUrl;
  final String platform;
  final String sourceId;
  final int? itemIndex;
  final int? itemCount;
  final String? authorId;
  final DateTime? publishedAt;
  final String? title;
  final List<String>? creators;
  final String? description;
  final String? credit;
  
  /// Arbitrary fields from other namespaces (e.g., photoshop:Headline, user-set dc:subject).
  /// Preserved when merging XMP.
  final Map<String, String> otherFields;

  XmpProvenance({
    required this.schema,
    required this.assetId,
    required this.capturedAt,
    required this.capturedBy,
    required this.metadataDate,
    required this.sourceUrl,
    required this.platform,
    required this.sourceId,
    this.itemIndex,
    this.itemCount,
    this.authorId,
    this.publishedAt,
    this.title,
    this.creators,
    this.description,
    this.credit,
    this.otherFields = const {},
  });

  Map<String, dynamic> toJson() => {
        'prov:schema': schema,
        'prov:assetId': assetId,
        'prov:capturedAt': capturedAt.toIso8601String(),
        'prov:capturedBy': capturedBy,
        'xmp:MetadataDate': metadataDate.toIso8601String(),
        'prov:sourceUrl': sourceUrl,
        'prov:platform': platform,
        'prov:sourceId': sourceId,
        if (itemIndex != null) 'prov:itemIndex': itemIndex,
        if (itemCount != null) 'prov:itemCount': itemCount,
        if (authorId != null) 'prov:authorId': authorId,
        if (publishedAt != null) 'prov:publishedAt': publishedAt!.toIso8601String(),
        if (title != null) 'dc:title': title,
        if (creators != null) 'dc:creator': creators,
        if (description != null) 'dc:description': description,
        if (credit != null) 'photoshop:Credit': credit,
        ...otherFields,
      };

  factory XmpProvenance.fromJson(Map<String, dynamic> json) {
    final otherFields = <String, String>{};
    json.forEach((key, value) {
      if (!_knownFields.contains(key)) {
        otherFields[key] = value.toString();
      }
    });

    return XmpProvenance(
      schema: json['prov:schema'] as String? ?? '0.1',
      assetId: json['prov:assetId'] as String,
      capturedAt: DateTime.parse(json['prov:capturedAt'] as String),
      capturedBy: json['prov:capturedBy'] as String,
      metadataDate: DateTime.parse(json['xmp:MetadataDate'] as String),
      sourceUrl: json['prov:sourceUrl'] as String,
      platform: json['prov:platform'] as String,
      sourceId: json['prov:sourceId'] as String,
      itemIndex: json['prov:itemIndex'] as int?,
      itemCount: json['prov:itemCount'] as int?,
      authorId: json['prov:authorId'] as String?,
      publishedAt:
          json['prov:publishedAt'] != null ? DateTime.parse(json['prov:publishedAt'] as String) : null,
      title: json['dc:title'] as String?,
      creators: json['dc:creator'] != null ? List<String>.from(json['dc:creator'] as List) : null,
      description: json['dc:description'] as String?,
      credit: json['photoshop:Credit'] as String?,
      otherFields: otherFields,
    );
  }

  static const _knownFields = {
    'prov:schema',
    'prov:assetId',
    'prov:capturedAt',
    'prov:capturedBy',
    'xmp:MetadataDate',
    'prov:sourceUrl',
    'prov:platform',
    'prov:sourceId',
    'prov:itemIndex',
    'prov:itemCount',
    'prov:authorId',
    'prov:publishedAt',
    'dc:title',
    'dc:creator',
    'dc:description',
    'dc:subject',
    'xmp:Rating',
    'dc:source',
    'photoshop:Credit',
  };
}
