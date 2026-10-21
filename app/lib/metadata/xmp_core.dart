// Copyright 2026 EasySave. All rights reserved.
// Shared XMP parsing and building logic for JPEG, PNG, WebP, and sidecar files.

import 'package:xml/xml.dart';
import 'xmp_model.dart';

/// Canonical namespace URIs for provenance-spec fields.
const _provNs = 'https://joopererer.github.io/provenance-spec/ns/';
const _dcNs = 'http://purl.org/dc/elements/1.1/';
const _xmpNs = 'http://ns.adobe.com/xap/1.0/';
const _photoshopNs = 'http://ns.adobe.com/photoshop/1.0/';

/// Build a qualified name from namespace URI and local name.
String _qname(String uri, String local) {
  // Derive prefix from URI for canonical output
  if (uri == _provNs) return 'prov:$local';
  if (uri == _dcNs) return 'dc:$local';
  if (uri == _xmpNs) return 'xmp:$local';
  if (uri == _photoshopNs) return 'photoshop:$local';
  return local;
}

/// Get canonical qualified name from an XML element's name.
String _canonicalKey(XmlElement elem) {
  final ns = elem.name.prefix;
  final local = elem.name.local;
  if (ns == 'prov' || ns == 'pv') return 'prov:$local';
  if (ns == 'dc') return 'dc:$local';
  if (ns == 'xmp') return 'xmp:$local';
  if (ns == 'photoshop') return 'photoshop:$local';
  return elem.name.qualified;
}

/// Parse XMP XML string into XmpProvenance model.
XmpProvenance parseXmpXml(String xml) {
  final document = XmlDocument.parse(xml);

  final json = <String, dynamic>{};

  // Build namespace prefix map from root element
  final nsMap = <String, String>{};
  for (final rdf in document.findAllElements('rdf:RDF')) {
    final desc = rdf.findElements('rdf:Description').firstOrNull;
    if (desc != null) {
      for (final attr in desc.attributes) {
        if (attr.name.local.startsWith('xmlns')) {
          nsMap[attr.value] = attr.name.local.replaceFirst('xmlns:', '');
        }
      }
    }
  }

  // Parse ALL rdf:Description elements in the document (handle multiple blocks)
  for (final rdf in document.findAllElements('rdf:RDF')) {
    for (final desc in rdf.findAllElements('rdf:Description')) {
      _parseDescriptionElement(desc, json, nsMap);
    }
  }

  return XmpProvenance.fromJson(json);
}

/// Parse a single rdf:Description element, extracting fields from attributes or child elements.
void _parseDescriptionElement(XmlElement desc, Map<String, dynamic> json, Map<String, String> nsMap) {
  // Build URI -> prefix map from attributes
  final uriToPrefix = <String, String>{};
  for (final attr in desc.attributes) {
    if (attr.name.local.startsWith('xmlns') && attr.name.local.contains(':')) {
      final prefix = attr.name.local.replaceFirst('xmlns:', '');
      uriToPrefix[attr.value] = prefix;
    }
  }

  // Parse attributes - skip xmlns:* and rdf:about
  for (final attr in desc.attributes) {
    final key = attr.name.qualified;
    if (key.startsWith('xmlns:') || key == 'rdf:about') {
      continue;
    }

    // Resolve canonical name from namespace
    final attrUri = attr.name.prefix;
    String canonicalKey;
    if (attrUri != null && attrUri.isNotEmpty) {
      canonicalKey = _canonicalKeyFromPrefix(attrUri, attr.name.local, uriToPrefix);
    } else {
      // No prefix: check if this looks like a known field by local name
      canonicalKey = _canonicalKeyFromPrefix('prov', attr.name.local, uriToPrefix);
    }

    // Only set if not already present (attributes take precedence in same block)
    if (!json.containsKey(canonicalKey)) {
      json[canonicalKey] = attr.value;
    }
  }

  // Parse child elements
  for (final child in desc.children.whereType<XmlElement>()) {
    final tagName = child.name.qualified;

    // Resolve canonical name from namespace
    final childNs = child.name.prefix ?? '';
    String canonicalTagName;
    if (childNs.isNotEmpty) {
      canonicalTagName = _canonicalKeyFromPrefix(childNs, child.name.local, uriToPrefix);
    } else {
      canonicalTagName = _canonicalKeyFromPrefix('prov', child.name.local, uriToPrefix);
    }

    if (json.containsKey(canonicalTagName)) continue; // Already have this field

    // Check for rdf:Alt (single localized text)
    if (child.findElements('rdf:Alt').isNotEmpty) {
      final alt = child.findElements('rdf:Alt').first;
      final li = alt.findElements('rdf:li').firstOrNull;
      if (li != null) {
        json[canonicalTagName] = li.innerText;
      }
    }
    // Check for rdf:Seq (ordered array)
    else if (child.findElements('rdf:Seq').isNotEmpty) {
      final seq = child.findElements('rdf:Seq').first;
      json[canonicalTagName] = seq.findElements('rdf:li').map((e) => e.innerText).toList();
    }
    // Check for rdf:Bag (unordered set, treat as array)
    else if (child.findElements('rdf:Bag').isNotEmpty) {
      final bag = child.findElements('rdf:Bag').first;
      json[canonicalTagName] = bag.findElements('rdf:li').map((e) => e.innerText).toList();
    }
    // Simple text node
    else if (child.children.length == 1 && child.children.first is XmlText) {
      json[canonicalTagName] = (child.children.first as XmlText).value;
    }
  }
}

/// Resolve a canonical qualified name from prefix and local name.
String _canonicalKeyFromPrefix(String prefix, String local, Map<String, String> uriToPrefix) {
  // Check if prefix maps to a known namespace URI
  final uri = uriToPrefix.entries
      .where((e) => e.value == prefix)
      .map((e) => e.key)
      .firstOrNull;

  if (uri == _provNs || prefix == 'prov' || prefix == 'pv') {
    return 'prov:$local';
  }
  if (uri == _dcNs || prefix == 'dc') {
    return 'dc:$local';
  }
  if (uri == _xmpNs || prefix == 'xmp') {
    return 'xmp:$local';
  }
  if (uri == _photoshopNs || prefix == 'photoshop') {
    return 'photoshop:$local';
  }

  // Unknown prefix: return as-is
  return '$prefix:$local';
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
