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
  final String? sourceUrl;
  final String? platform;
  final String? sourceId;
  final int? itemIndex;
  final int? itemCount;
  final String? authorId;
  final DateTime? publishedAt;
  final String? title;
  final List<String>? creators;
  final String? description;
  final List<String>? subject;
  final int? rating;
  final String? credit;
  
  /// Arbitrary fields from other namespaces (e.g., photoshop:Headline).
  /// Preserved when merging XMP.
  final Map<String, String> otherFields;

  XmpProvenance({
    required this.schema,
    required this.assetId,
    required this.capturedAt,
    required this.capturedBy,
    required this.metadataDate,
    this.sourceUrl,
    this.platform,
    this.sourceId,
    this.itemIndex,
    this.itemCount,
    this.authorId,
    this.publishedAt,
    this.title,
    this.creators,
    this.description,
    this.subject,
    this.rating,
    this.credit,
    this.otherFields = const {},
  });

  /// Converts to SPEC §7 JSON format (flattened keys, source nested).
  Map<String, dynamic> toJson() => {
        'schema': schema,
        'assetId': assetId,
        'capturedAt': capturedAt.toIso8601String(),
        'capturedBy': capturedBy,
        'metadataDate': metadataDate.toIso8601String(),
        'source': {
          'url': sourceUrl,
          'platform': platform,
          'id': sourceId,
          if (itemIndex != null) 'itemIndex': itemIndex,
          if (itemCount != null) 'itemCount': itemCount,
          if (authorId != null) 'authorId': authorId,
          if (publishedAt != null) 'publishedAt': publishedAt!.toIso8601String(),
        },
        if (title != null) 'title': title,
        if (creators != null) 'creator': creators,
        if (description != null) 'description': description,
        if (subject != null) 'subject': subject,
        if (rating != null) 'rating': rating,
        if (credit != null) 'credit': credit,
        // Keep other fields with original qualified names for preservation
        ...otherFields,
      };
  
  /// Converts to XMP namespace-qualified format for XML building.
  Map<String, dynamic> toXmpJson() => {
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
        if (subject != null) 'dc:subject': subject,
        if (rating != null) 'xmp:Rating': rating,
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
      sourceUrl: json['prov:sourceUrl'] as String?,
      platform: json['prov:platform'] as String?,
      sourceId: json['prov:sourceId'] as String?,
      itemIndex: json['prov:itemIndex'] != null
          ? (json['prov:itemIndex'] is int ? json['prov:itemIndex'] as int : int.tryParse(json['prov:itemIndex'].toString()))
          : null,
      itemCount: json['prov:itemCount'] != null
          ? (json['prov:itemCount'] is int ? json['prov:itemCount'] as int : int.tryParse(json['prov:itemCount'].toString()))
          : null,
      authorId: json['prov:authorId'] as String?,
      publishedAt:
          json['prov:publishedAt'] != null ? DateTime.parse(json['prov:publishedAt'] as String) : null,
      title: json['dc:title'] as String?,
      creators: json['dc:creator'] != null ? List<String>.from(json['dc:creator'] as List) : null,
      description: json['dc:description'] as String?,
      subject: json['dc:subject'] != null ? List<String>.from(json['dc:subject'] as List) : null,
      rating: json['xmp:Rating'] != null 
          ? (json['xmp:Rating'] is int ? json['xmp:Rating'] as int : int.tryParse(json['xmp:Rating'].toString()))
          : null,
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
