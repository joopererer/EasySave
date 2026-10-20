// Copyright 2026 EasySave. All rights reserved.
// JPEG XMP reader/writer - pure Dart byte manipulation.
// APP1 segment format: 0xFFE1 [length:2] "http://ns.adobe.com/xap/1.0/\0" [XMP]

import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';
import 'xmp_model.dart';

const _xmpHeader = 'http://ns.adobe.com/xap/1.0/\x00';
const _xmpHeaderBytes = _xmpHeader.length; // 29

/// Reads XMP from JPEG APP1 segment.
/// Returns null if no XMP found.
XmpProvenance? readJpegXmp(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw FormatException('Not a JPEG file');
  }

  int offset = 2;
  while (offset < bytes.length - 1) {
    if (bytes[offset] != 0xFF) break;

    final marker = bytes[offset + 1];
    if (marker == 0xD9) break; // EOI

    offset += 2;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      // Standalone markers without length
      continue;
    }

    if (offset + 2 > bytes.length) break;

    final segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
    if (segmentLength < 2) break;

    if (marker == 0xE1 && offset + 2 + _xmpHeaderBytes <= bytes.length) {
      // APP1 segment
      final headerStart = offset + 2;
      final headerEnd = headerStart + _xmpHeaderBytes;
      
      // Check if we have enough space for header
      if (headerEnd <= offset + segmentLength) {
        final header = utf8.decode(bytes.sublist(headerStart, headerEnd));

        if (header == _xmpHeader) {
          // Found XMP segment
          final xmpStart = headerEnd;
          final xmpEnd = offset + segmentLength;
          final xmpPayload = utf8.decode(bytes.sublist(xmpStart, xmpEnd));
          return parseXmpXml(xmpPayload);
        }
      }
    }

    offset += segmentLength;
  }

  return null;
}

/// Writes XMP into JPEG APP1 segment.
/// Returns new JPEG bytes with XMP written.
/// Replaces existing XMP APP1 if present, otherwise inserts after SOI.
/// Preserves existing assetId and foreign fields when replacing.
Uint8List writeJpegXmp(Uint8List bytes, XmpProvenance xmp) {
  if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw FormatException('Not a JPEG file');
  }

  // Check if existing XMP exists and merge with it
  final existing = readJpegXmp(bytes);
  final merged = _mergeXmp(existing, xmp);

  final xmpPayload = buildXmpXml(merged);
  final xmpBytes = utf8.encode(_xmpHeader + xmpPayload);
  final newSegmentLength = 2 + xmpBytes.length;

  if (newSegmentLength > 65535) {
    throw ArgumentError('XMP payload too large for single APP1 segment');
  }

  final builder = BytesBuilder();
  int offset = 2;
  bool xmpWritten = false;

  // SOI
  builder.add([0xFF, 0xD8]);

  while (offset < bytes.length - 1) {
    if (bytes[offset] != 0xFF) break;

    final marker = bytes[offset + 1];
    if (marker == 0xD9) break; // EOI

    offset += 2;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      // Standalone markers - copy as-is
      builder.add([0xFF, marker]);
      continue;
    }

    if (offset + 2 > bytes.length) break;

    final segmentLength = (bytes[offset] << 8) | bytes[offset + 1];
    if (segmentLength < 2) break;

    if (marker == 0xE1 && offset + 2 + _xmpHeaderBytes <= bytes.length) {
      // Check if this is XMP APP1
      final headerStart = offset + 2;
      final headerEnd = headerStart + _xmpHeaderBytes;
      
      if (headerEnd <= offset + segmentLength) {
        final header = utf8.decode(bytes.sublist(headerStart, headerEnd));

        if (header == _xmpHeader) {
          // Replace existing XMP
          builder.add([0xFF, 0xE1]);
          builder.add([newSegmentLength >> 8, newSegmentLength & 0xFF]);
          builder.add(xmpBytes);
          xmpWritten = true;
          offset += segmentLength;
          continue;
        }
      }
    }

    // Copy segment as-is
    builder.add([0xFF, marker]);
    builder.add(bytes.sublist(offset, offset + segmentLength));
    offset += segmentLength;

    // Insert XMP after first non-XMP APP segment if not yet written
    if (!xmpWritten && (marker >= 0xE0 && marker <= 0xEF)) {
      builder.add([0xFF, 0xE1]);
      builder.add([newSegmentLength >> 8, newSegmentLength & 0xFF]);
      builder.add(xmpBytes);
      xmpWritten = true;
    }
  }

  // If no XMP written yet, insert after SOI (offset should be at first scan or EOI)
  if (!xmpWritten) {
    final temp = builder.toBytes();
    builder.clear();
    builder.add([0xFF, 0xD8]); // SOI
    builder.add([0xFF, 0xE1]); // APP1
    builder.add([newSegmentLength >> 8, newSegmentLength & 0xFF]);
    builder.add(xmpBytes);
    builder.add(temp.sublist(2)); // Rest after SOI
  }

  // Copy remaining bytes (scan data + EOI)
  if (offset < bytes.length) {
    builder.add(bytes.sublist(offset));
  }

  return builder.toBytes();
}

XmpProvenance _parseXmpXml(String xml) {
  final document = XmlDocument.parse(xml);
  final rdf = document.findAllElements('rdf:Description').first;

  final json = <String, dynamic>{};

  for (final attr in rdf.attributes) {
    json[attr.name.qualified] = attr.value;
  }

  for (final child in rdf.children.whereType<XmlElement>()) {
    final tagName = child.name.qualified;
    if (child.children.length == 1 && child.children.first is XmlText) {
      json[tagName] = (child.children.first as XmlText).value;
    } else if (child.findElements('rdf:Seq').isNotEmpty) {
      // Array
      final seq = child.findElements('rdf:Seq').first;
      json[tagName] = seq.findElements('rdf:li').map((e) => e.innerText).toList();
    }
  }

  return XmpProvenance.fromJson(json);
}

String _buildXmpXml(XmpProvenance xmp) {
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

        final json = xmp.toJson();
        json.forEach((key, value) {
          if (value is List) {
            builder.element(key, nest: () {
              builder.element('rdf:Seq', nest: () {
                for (final item in value) {
                  builder.element('rdf:li', nest: item);
                }
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

/// Exported for PNG/WebP readers
XmpProvenance parseXmpXml(String xml) => _parseXmpXml(xml);

/// Exported for PNG/WebP writers
String buildXmpXml(XmpProvenance xmp) => _buildXmpXml(xmp);

/// Merge new XMP with existing, preserving assetId and foreign fields.
XmpProvenance _mergeXmp(XmpProvenance? existing, XmpProvenance newXmp) {
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
    credit: newXmp.credit,
    otherFields: mergedOtherFields,
  );
}
