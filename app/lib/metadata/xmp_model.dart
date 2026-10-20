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

    // Handle both SPEC format (flat keys) and XMP format (namespace-prefixed keys)
    String schema;
    if (json.containsKey('prov:schema')) {
      schema = json['prov:schema'] as String? ?? '0.1';
    } else {
      schema = json['schema'] as String? ?? '0.1';
    }

    String? assetId;
    DateTime capturedAt;
    String capturedBy;
    DateTime metadataDate;
    String? sourceUrl;
    String? platform;
    String? sourceId;
    int? itemIndex;
    int? itemCount;
    String? authorId;
    DateTime? publishedAt;
    String? title;
    List<String>? creators;
    String? description;
    List<String>? subject;
    int? rating;
    String? credit;

    // Try XMP format first, fall back to SPEC format
    if (json.containsKey('prov:assetId')) {
      assetId = json['prov:assetId'] as String?;
    } else {
      assetId = json['assetId'] as String?;
    }

    if (json.containsKey('prov:capturedAt')) {
      capturedAt = DateTime.parse(json['prov:capturedAt'] as String);
    } else {
      capturedAt = DateTime.parse(json['capturedAt'] as String);
    }

    if (json.containsKey('prov:capturedBy')) {
      capturedBy = json['prov:capturedBy'] as String;
    } else {
      capturedBy = json['capturedBy'] as String;
    }

    if (json.containsKey('xmp:MetadataDate')) {
      metadataDate = DateTime.parse(json['xmp:MetadataDate'] as String);
    } else if (json.containsKey('metadataDate')) {
      metadataDate = DateTime.parse(json['metadataDate'] as String);
    } else {
      // Use capturedAt as fallback
      metadataDate = capturedAt;
    }

    // Source fields
    if (json.containsKey('prov:sourceUrl')) {
      sourceUrl = json['prov:sourceUrl'] as String?;
    } else if (json.containsKey('source')) {
      final source = json['source'] as Map<String, dynamic>?;
      sourceUrl = source?['url'] as String?;
      platform = source?['platform'] as String?;
      sourceId = source?['id'] as String?;
      itemIndex = source?['itemIndex'] as int?;
      itemCount = source?['itemCount'] as int?;
      authorId = source?['authorId'] as String?;
      if (source?['publishedAt'] != null) {
        publishedAt = DateTime.parse(source!['publishedAt'] as String);
      }
    } else {
      sourceUrl = json['sourceUrl'] as String?;
    }

    if (json.containsKey('prov:platform') && platform == null) {
      platform = json['prov:platform'] as String?;
    }
    if (json.containsKey('prov:sourceId') && sourceId == null) {
      sourceId = json['prov:sourceId'] as String?;
    }
    if (json.containsKey('prov:itemIndex') && itemIndex == null) {
      itemIndex = _parseInt(json['prov:itemIndex']);
    }
    if (json.containsKey('prov:itemCount') && itemCount == null) {
      itemCount = _parseInt(json['prov:itemCount']);
    }
    if (json.containsKey('prov:authorId') && authorId == null) {
      authorId = json['prov:authorId'] as String?;
    }
    if (json.containsKey('prov:publishedAt') && publishedAt == null) {
      publishedAt = DateTime.parse(json['prov:publishedAt'] as String);
    }

    // Dublin Core fields
    if (json.containsKey('dc:title')) {
      title = json['dc:title'] as String?;
    } else {
      title = json['title'] as String?;
    }

    if (json.containsKey('dc:creator')) {
      creators = json['dc:creator'] != null ? List<String>.from(json['dc:creator'] as List) : null;
    } else if (json.containsKey('creator')) {
      creators = json['creator'] != null ? List<String>.from(json['creator'] as List) : null;
    }

    if (json.containsKey('dc:description')) {
      description = json['dc:description'] as String?;
    } else {
      description = json['description'] as String?;
    }

    if (json.containsKey('dc:subject')) {
      subject = json['dc:subject'] != null ? List<String>.from(json['dc:subject'] as List) : null;
    } else if (json.containsKey('subject')) {
      subject = json['subject'] != null ? List<String>.from(json['subject'] as List) : null;
    }

    if (json.containsKey('xmp:Rating')) {
      rating = _parseInt(json['xmp:Rating']);
    } else if (json.containsKey('rating')) {
      rating = _parseInt(json['rating']);
    }

    if (json.containsKey('photoshop:Credit')) {
      credit = json['photoshop:Credit'] as String?;
    } else {
      credit = json['credit'] as String?;
    }

    return XmpProvenance(
      schema: schema,
      assetId: assetId ?? 'unknown',
      capturedAt: capturedAt,
      capturedBy: capturedBy,
      metadataDate: metadataDate,
      sourceUrl: sourceUrl,
      platform: platform,
      sourceId: sourceId,
      itemIndex: itemIndex,
      itemCount: itemCount,
      authorId: authorId,
      publishedAt: publishedAt,
      title: title,
      creators: creators,
      description: description,
      subject: subject,
      rating: rating,
      credit: credit,
      otherFields: otherFields,
    );
  }

  static int? _parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
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
    // Flat SPEC format keys
    'schema',
    'assetId',
    'capturedAt',
    'capturedBy',
    'metadataDate',
    'sourceUrl',
    'platform',
    'sourceId',
    'itemIndex',
    'itemCount',
    'authorId',
    'publishedAt',
    'title',
    'creator',
    'description',
    'subject',
    'rating',
    'credit',
    'source',
  };
}
