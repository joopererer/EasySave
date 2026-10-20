// Copyright 2026 EasySave. All rights reserved.
// Shared XMP parsing and building logic for JPEG, PNG, WebP, and sidecar files.

import 'package:xml/xml.dart';
import 'xmp_model.dart';

/// Normalize a qualified name to canonical prefix:namespace format.
/// e.g., 'pv:schema' or 'prov_NS:schema' → 'prov:schema'
/// According to SPEC §4.7, fields must be identified by namespace URI, not prefix.
String _normalizeKey(String qualified) {
  if (qualified.contains(':')) {
    final parts = qualified.split(':');
    if (parts.length == 2) {
      final prefix = parts[0];
      final local = parts[1];
      
      // Map known prefixes to canonical form
      if (prefix == 'pv' || prefix == 'prov_NS') {
        return 'prov:$local';
      }
      // Already canonical
      if (prefix == 'prov' || prefix == 'dc' || prefix == 'xmp' || prefix == 'photoshop') {
        return qualified;
      }
    }
  }
  return qualified;
}

/// Parse XMP XML string into XmpProvenance model.
XmpProvenance parseXmpXml(String xml) {
  final document = XmlDocument.parse(xml);
  
  final json = <String, dynamic>{};

  // Parse ALL rdf:Description elements in the document (handle multiple blocks)
  for (final rdf in document.findAllElements('rdf:RDF')) {
    for (final desc in rdf.findAllElements('rdf:Description')) {
      _parseDescriptionElement(desc, json);
    }
  }

  return XmpProvenance.fromJson(json);
}

/// Parse a single rdf:Description element, extracting fields from attributes or child elements.
void _parseDescriptionElement(XmlElement desc, Map<String, dynamic> json) {
  // Parse attributes - skip xmlns:* and rdf:about
  for (final attr in desc.attributes) {
    final key = attr.name.qualified;
    if (key.startsWith('xmlns:') || key == 'rdf:about') {
      continue;
    }
    // Normalize prefix to canonical form (e.g., pv: → prov:)
    final normalizedKey = _normalizeKey(key);
    // Only set if not already present (attributes take precedence in same block)
    if (!json.containsKey(normalizedKey)) {
      json[normalizedKey] = attr.value;
    }
  }

  // Parse child elements
  for (final child in desc.children.whereType<XmlElement>()) {
    final tagName = child.name.qualified;
    // Normalize prefix to canonical form
    final normalizedTagName = _normalizeKey(tagName);
    if (json.containsKey(normalizedTagName)) continue; // Already have this field

    // Check for rdf:Alt (single localized text)
    if (child.findElements('rdf:Alt').isNotEmpty) {
      final alt = child.findElements('rdf:Alt').first;
      final li = alt.findElements('rdf:li').firstOrNull;
      if (li != null) {
        json[normalizedTagName] = li.innerText;
      }
    }
    // Check for rdf:Seq (ordered array)
    else if (child.findElements('rdf:Seq').isNotEmpty) {
      final seq = child.findElements('rdf:Seq').first;
      json[normalizedTagName] = seq.findElements('rdf:li').map((e) => e.innerText).toList();
    }
    // Check for rdf:Bag (unordered set, treat as array)
    else if (child.findElements('rdf:Bag').isNotEmpty) {
      final bag = child.findElements('rdf:Bag').first;
      json[normalizedTagName] = bag.findElements('rdf:li').map((e) => e.innerText).toList();
    }
    // Simple text node
    else if (child.children.length == 1 && child.children.first is XmlText) {
      json[normalizedTagName] = (child.children.first as XmlText).value;
    }
  }
}

/// Build XMP XML string from XmpProvenance model.
String buildXmpXml(XmpProvenance xmp) {
  final builder = XmlBuilder();
  builder.processing('xpacket', 'begin="" id="W5M0MpCehiHzreSzNTczkc9d"');
  builder.element('x:xmpmeta', nest: () {
    builder.attribute('xmlns:x', 'adobe:ns:meta/');
    builder.element('rdf:RDF', nest: () {
      builder.attribute('xmlns:rdf', 'http://www.w3.org/1999/02/22-rdf-syntax-ns#');
      builder.attribute('xmlns:prov', 'https://joopererer.github.io/provenance-spec/ns/');
      builder.attribute('xmlns:dc', 'http://purl.org/dc/elements/1.1/');
      builder.attribute('xmlns:xmp', 'http://ns.adobe.com/xap/1.0/');
      builder.attribute('xmlns:photoshop', 'http://ns.adobe.com/photoshop/1.0/');

      builder.element('rdf:Description', nest: () {
        builder.attribute('rdf:about', '');

        final json = xmp.toXmpJson();
        json.forEach((key, value) {
          if (value is List) {
            builder.element(key, nest: () {
              // Use rdf:Seq for dc:creator (ordered), rdf:Bag for dc:subject (unordered set)
              final containerType = key == 'dc:subject' ? 'rdf:Bag' : 'rdf:Seq';
              builder.element(containerType, nest: () {
                for (final item in value) {
                  builder.element('rdf:li', nest: item);
                }
              });
            });
          } else if (key == 'dc:title' || key == 'dc:description') {
            // Use rdf:Alt for localized text fields
            builder.element(key, nest: () {
              builder.element('rdf:Alt', nest: () {
                builder.element('rdf:li', nest: () {
                  builder.attribute('xml:lang', 'x-default');
                  builder.text(value.toString());
                });
              });
            });
          } else {
            builder.attribute(key, value.toString());
          }
        });
      });
    });
  });
  builder.processing('xpacket', 'end="w"');

  return builder.buildDocument().toXmlString(pretty: false);
}

/// Merge new XMP with existing, preserving assetId and foreign fields.
XmpProvenance mergeXmp(XmpProvenance? existing, XmpProvenance newXmp) {
  if (existing == null) return newXmp;
  
  // Preserve existing assetId
  final assetId = existing.assetId;
  
  // Merge otherFields: keep existing foreign fields, don't overwrite
  final mergedOtherFields = Map<String, String>.from(existing.otherFields);
  newXmp.otherFields.forEach((key, value) {
    if (!mergedOtherFields.containsKey(key)) {
      mergedOtherFields[key] = value;
    }
  });
  
  return XmpProvenance(
    schema: newXmp.schema,
    assetId: assetId, // Always use existing
    capturedAt: newXmp.capturedAt,
    capturedBy: newXmp.capturedBy,
    metadataDate: newXmp.metadataDate,
    sourceUrl: newXmp.sourceUrl,
    platform: newXmp.platform,
    sourceId: newXmp.sourceId,
    itemIndex: newXmp.itemIndex,
    itemCount: newXmp.itemCount,
    authorId: newXmp.authorId,
    publishedAt: newXmp.publishedAt,
    title: newXmp.title,
    creators: newXmp.creators,
    description: newXmp.description,
    subject: newXmp.subject,
    rating: newXmp.rating,
    credit: newXmp.credit,
    otherFields: mergedOtherFields,
  );
}
