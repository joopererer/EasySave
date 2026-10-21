// Copyright 2026 EasySave. All rights reserved.
// Shared XMP parsing and building logic for JPEG, PNG, WebP, and sidecar files.

import 'package:xml/xml.dart';
import 'xmp_model.dart';

/// Canonical namespace URIs for provenance-spec fields.
const provNsUri = 'https://joopererer.github.io/provenance-spec/ns/';
const dcNsUri = 'http://purl.org/dc/elements/1.1/';
const xmpNsUri = 'http://ns.adobe.com/xap/1.0/';
const photoshopNsUri = 'http://ns.adobe.com/photoshop/1.0/';

/// Parse XMP XML string into XmpProvenance model.
XmpProvenance parseXmpXml(String xml) {
  final document = XmlDocument.parse(xml);
  final json = <String, dynamic>{};

  // Build namespace map from rdf:RDF element (xmlns:* are typically there)
  final prefixToUri = <String, String>{};
  for (final rdf in document.findAllElements('rdf:RDF')) {
    for (final attr in rdf.attributes) {
      if (attr.name.prefix == 'xmlns') {
        prefixToUri[attr.name.local] = attr.value;
      }
    }
  }

  // Parse ALL rdf:Description elements in the document
  for (final rdf in document.findAllElements('rdf:RDF')) {
    for (final desc in rdf.findAllElements('rdf:Description')) {
      _parseDescriptionElement(desc, json, prefixToUri);
    }
  }

  return XmpProvenance.fromJson(json);
}

/// Parse a single rdf:Description element.
void _parseDescriptionElement(
  XmlElement desc,
  Map<String, dynamic> json,
  Map<String, String> prefixToUri,
) {
  // Parse attributes - skip xmlns:* and rdf:about
  for (final attr in desc.attributes) {
    // Skip xmlns declarations and rdf:about
    if (attr.name.prefix == 'xmlns' || attr.name.local == 'about') continue;

    final canonicalKey = _canonicalKeyFromAttr(attr, prefixToUri);
    if (canonicalKey != null && !json.containsKey(canonicalKey)) {
      json[canonicalKey] = attr.value;
    }
  }

  // Parse child elements
  for (final child in desc.children.whereType<XmlElement>()) {
    final canonicalKey = _canonicalKeyFromElement(child, prefixToUri);
    if (canonicalKey == null || json.containsKey(canonicalKey)) continue;

    // Check for rdf:Alt (localized text)
    final alt = child.findElements('rdf:Alt').firstOrNull;
    if (alt != null) {
      final li = alt.findElements('rdf:li').firstOrNull;
      if (li != null) json[canonicalKey] = li.innerText;
      continue;
    }

    // Check for rdf:Seq (ordered array)
    final seq = child.findElements('rdf:Seq').firstOrNull;
    if (seq != null) {
      json[canonicalKey] = seq.findElements('rdf:li').map((e) => e.innerText).toList();
      continue;
    }

    // Check for rdf:Bag (unordered set)
    final bag = child.findElements('rdf:Bag').firstOrNull;
    if (bag != null) {
      json[canonicalKey] = bag.findElements('rdf:li').map((e) => e.innerText).toList();
      continue;
    }

    // Simple text node
    if (child.children.length == 1 && child.children.first is XmlText) {
      json[canonicalKey] = (child.children.first as XmlText).value;
    }
  }
}

/// Get canonical key for an attribute, returns null if unrecognized.
String? _canonicalKeyFromAttr(XmlAttribute attr, Map<String, String> prefixToUri) {
  final prefix = attr.name.prefix ?? '';
  final local = attr.name.local;
  return _canonicalKeyFromPrefixAndLocal(prefix, local, prefixToUri);
}

/// Get canonical key for an element, returns null if unrecognized.
String? _canonicalKeyFromElement(XmlElement elem, Map<String, String> prefixToUri) {
  final prefix = elem.name.prefix ?? '';
  final local = elem.name.local;
  return _canonicalKeyFromPrefixAndLocal(prefix, local, prefixToUri);
}

/// Resolve canonical key from prefix and local name.
/// Returns null if the namespace URI doesn't match a known provenance namespace.
String? _canonicalKeyFromPrefixAndLocal(
  String prefix,
  String local,
  Map<String, String> prefixToUri,
) {
  // No prefix: try to match by local name to known fields (fallback)
  if (prefix.isEmpty) {
    return _canonicalKeyFromLocalName(local);
  }

  // Get the namespace URI for this prefix
  final uri = prefixToUri[prefix];

  // If xmlns wasn't parsed (uri is null), fall back to known prefix names only
  if (uri == null) {
    if (prefix == 'prov' || prefix == 'pv') return 'prov:$local';
    if (prefix == 'dc') return 'dc:$local';
    if (prefix == 'xmp') return 'xmp:$local';
    if (prefix == 'photoshop') return 'photoshop:$local';
    return null;
  }

  // Map namespace URI to canonical prefix - URI MUST match
  if (uri == provNsUri) return 'prov:$local';
  if (uri == dcNsUri) return 'dc:$local';
  if (uri == xmpNsUri) return 'xmp:$local';
  if (uri == photoshopNsUri) return 'photoshop:$local';

  // Unknown namespace: ignore (not a provenance field)
  return null;
}

/// Fallback: match by local name for known provenance fields.
String? _canonicalKeyFromLocalName(String local) {
  switch (local) {
    case 'schema':
    case 'assetId':
    case 'capturedAt':
    case 'capturedBy':
    case 'sourceUrl':
    case 'platform':
    case 'sourceId':
    case 'itemIndex':
    case 'itemCount':
    case 'authorId':
    case 'publishedAt':
    case 'metadataDate':
      return 'prov:$local';
    case 'MetadataDate':
      return 'xmp:$local';
    case 'title':
    case 'creator':
    case 'description':
    case 'subject':
      return 'dc:$local';
    case 'Rating':
      return 'xmp:$local';
    case 'Credit':
      return 'photoshop:$local';
    default:
      return null;
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
