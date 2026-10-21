// Copyright 2026 EasySave. All rights reserved.
// XMP read/write tests

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/metadata/xmp_model.dart';
import 'package:easysave/metadata/xmp_jpeg.dart';
import 'package:easysave/metadata/xmp_png.dart';
import 'package:easysave/metadata/xmp_core.dart';

void main() {
  group('XMP Model', () {
    test('toJson/fromJson roundtrip', () {
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'test-asset-id',
        capturedAt: DateTime.utc(2026, 10, 20, 10, 30),
        capturedBy: 'EasySave v1.7',
        metadataDate: DateTime.utc(2026, 10, 20, 10, 31),
        sourceUrl: 'https://www.xiaohongshu.com/explore/test123',
        platform: 'xiaohongshu',
        sourceId: 'test123',
        itemIndex: 0,
        itemCount: 3,
        title: 'Test Title',
        creators: ['Test Author'],
        description: 'Test Description',
        credit: 'Test Author',
      );

      final json = xmp.toJson();
      final restored = XmpProvenance.fromJson(json);

      expect(restored.assetId, xmp.assetId);
      expect(restored.platform, xmp.platform);
      expect(restored.title, xmp.title);
      expect(restored.capturedAt, xmp.capturedAt);
    });
  });

  group('XMP Namespace URI Parsing (SPEC §4.7)', () {
    test('reads prov namespace URI correctly', () {
      // XMP with canonical prov: prefix bound to correct URI
      const xmp = '''
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:prov="https://joopererer.github.io/provenance-spec/ns/">
    <rdf:Description rdf:about="">
      <prov:schema>0.1</prov:schema>
      <prov:assetId>test-asset-123</prov:assetId>
      <prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>
      <prov:capturedBy>EasySave Test</prov:capturedBy>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
''';
      final parsed = parseXmpXml(xmp);
      expect(parsed.schema, '0.1');
      expect(parsed.assetId, 'test-asset-123');
      expect(parsed.capturedBy, 'EasySave Test');
    });

    test('reads prov with zz: prefix bound to correct URI', () {
      // XMP with non-standard prefix 'zz' bound to prov namespace URI
      const xmp = '''
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:zz="https://joopererer.github.io/provenance-spec/ns/">
    <rdf:Description rdf:about="">
      <zz:schema>0.1</zz:schema>
      <zz:assetId>zz-prefix-test</zz:assetId>
      <zz:capturedAt>2026-10-20T10:00:00Z</zz:capturedAt>
      <zz:capturedBy>EasySave Test</zz:capturedBy>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
''';
      final parsed = parseXmpXml(xmp);
      expect(parsed.schema, '0.1');
      expect(parsed.assetId, 'zz-prefix-test');
    });

    test('reads prov with ns1: prefix bound to correct URI', () {
      // XMP with ns1: prefix (common in some tools) bound to prov URI
      const xmp = '''
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:ns1="https://joopererer.github.io/provenance-spec/ns/">
    <rdf:Description rdf:about="">
      <ns1:schema>0.1</ns1:schema>
      <ns1:assetId>ns1-prefix-test</ns1:assetId>
      <ns1:sourceUrl>https://example.com/post123</ns1:sourceUrl>
      <ns1:capturedAt>2026-10-20T10:00:00Z</ns1:capturedAt>
      <ns1:capturedBy>EasySave Test</ns1:capturedBy>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
''';
      final parsed = parseXmpXml(xmp);
      expect(parsed.schema, '0.1');
      expect(parsed.assetId, 'ns1-prefix-test');
      expect(parsed.sourceUrl, 'https://example.com/post123');
    });

    test('reads prov with pv: prefix (legacy alias) bound to correct URI', () {
      // XMP with pv: prefix bound to prov namespace URI
      const xmp = '''
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:pv="https://joopererer.github.io/provenance-spec/ns/">
    <rdf:Description rdf:about="">
      <pv:schema>0.1</pv:schema>
      <pv:assetId>pv-prefix-test</pv:assetId>
      <pv:capturedAt>2026-10-20T10:00:00Z</pv:capturedAt>
      <pv:capturedBy>EasySave Test</pv:capturedBy>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
''';
      final parsed = parseXmpXml(xmp);
      expect(parsed.schema, '0.1');
      expect(parsed.assetId, 'pv-prefix-test');
    });

    test('ignores prov fields with wrong namespace URI', () {
      // XMP with prov: prefix bound to WRONG URI (not the spec URI)
      // Fields should NOT be recognized as provenance fields by namespace URI
      // We test with schema field (NOT in local name fallback) to verify namespace check
      const xmp = '''
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:prov="http://wrong-namespace.example.com/">
    <rdf:Description rdf:about="">
      <prov:schema>0.1</prov:schema>
      <prov:assetId>wrong-ns-asset</prov:assetId>
      <prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>
      <prov:capturedBy>Test</prov:capturedBy>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
''';
      // Wrong namespace URI means prov: prefix is bound to wrong URI
      // - schema is NOT in local name fallback, so it won't be recognized
      // - capturedAt IS in local name fallback, so it WILL be recognized
      // The parsing should produce partial results, causing fromJson to fail
      try {
        parseXmpXml(xmp);
        fail('Expected parsing to fail with wrong namespace');
      } catch (e) {
        // Expected: fromJson fails because required fields aren't properly recognized
        expect(e.toString(), contains('type'));
      }
    });

    test('reads dc namespace fields correctly', () {
      const xmp = '''
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:prov="https://joopererer.github.io/provenance-spec/ns/">
    <rdf:Description rdf:about="">
      <prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>
      <prov:capturedBy>EasySave</prov:capturedBy>
      <dc:title>Test Title</dc:title>
      <dc:creator>
        <rdf:Seq>
          <rdf:li>Author One</rdf:li>
          <rdf:li>Author Two</rdf:li>
        </rdf:Seq>
      </dc:creator>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
''';
      final parsed = parseXmpXml(xmp);
      expect(parsed.title, 'Test Title');
      expect(parsed.creators, ['Author One', 'Author Two']);
    });

    test('reads xmp namespace fields correctly', () {
      const xmp = '''
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:xmp="http://ns.adobe.com/xap/1.0/"
           xmlns:prov="https://joopererer.github.io/provenance-spec/ns/">
    <rdf:Description rdf:about="">
      <prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>
      <prov:capturedBy>EasySave</prov:capturedBy>
      <xmp:MetadataDate>2026-10-20T12:00:00Z</xmp:MetadataDate>
      <xmp:Rating>5</xmp:Rating>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
''';
      final parsed = parseXmpXml(xmp);
      expect(parsed.metadataDate.year, 2026);
      expect(parsed.metadataDate.month, 10);
      expect(parsed.metadataDate.day, 20);
    });

    test('reads photoshop namespace fields correctly', () {
      const xmp = '''
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
           xmlns:prov="https://joopererer.github.io/provenance-spec/ns/">
    <rdf:Description rdf:about="">
      <prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>
      <prov:capturedBy>EasySave</prov:capturedBy>
      <photoshop:Credit>Photographer Name</photoshop:Credit>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
''';
      final parsed = parseXmpXml(xmp);
      expect(parsed.credit, 'Photographer Name');
    });

    test('handles multiple prefixes for same URI correctly', () {
      // XMP with both prov: and zz: both bound to prov URI
      const xmp = '''
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
           xmlns:prov="https://joopererer.github.io/provenance-spec/ns/"
           xmlns:zz="https://joopererer.github.io/provenance-spec/ns/">
    <rdf:Description rdf:about="">
      <prov:schema>0.1</prov:schema>
      <zz:assetId>shared-ns-test</zz:assetId>
      <prov:capturedAt>2026-10-20T10:00:00Z</prov:capturedAt>
      <prov:capturedBy>Test</prov:capturedBy>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
''';
      final parsed = parseXmpXml(xmp);
      expect(parsed.schema, '0.1');
      expect(parsed.assetId, 'shared-ns-test');
    });
  });

  group('JPEG XMP', () {
    test('write and read XMP', () {
      // Minimal valid JPEG: SOI + APP0 + SOF0 + SOS + EOI
      final minimalJpeg = Uint8List.fromList([
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x10, // APP0 length=16
        ...List.filled(14, 0), // APP0 data
        0xFF, 0xC0, 0x00, 0x0B, // SOF0 length=11
        ...List.filled(9, 0), // SOF0 data
        0xFF, 0xDA, 0x00, 0x08, // SOS length=8
        ...List.filled(6, 0), // SOS data
        0xFF, 0xD9, // EOI
      ]);

      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'jpeg-test',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );

      final withXmp = writeJpegXmp(minimalJpeg, xmp);
      final read = readJpegXmp(withXmp);

      expect(read, isNotNull);
      expect(read!.assetId, 'jpeg-test');
      expect(read.platform, 'web');
    });
  });

  group('PNG XMP', () {
    test('write and read XMP', () {
      // Minimal valid PNG
      final minimalPng = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, // IHDR length=13
        0x49, 0x48, 0x44, 0x52, // "IHDR"
        0x00, 0x00, 0x00, 0x01, // width=1
        0x00, 0x00, 0x00, 0x01, // height=1
        0x08, 0x02, 0x00, 0x00, 0x00, // bit depth=8, color=RGB, etc.
        0x90, 0x77, 0x53, 0xDE, // CRC
        0x00, 0x00, 0x00, 0x00, // IEND length=0
        0x49, 0x45, 0x4E, 0x44, // "IEND"
        0xAE, 0x42, 0x60, 0x82, // CRC
      ]);

      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'png-test',
        capturedAt: DateTime.utc(2026, 10, 20),
        capturedBy: 'EasySave',
        metadataDate: DateTime.utc(2026, 10, 20),
        sourceUrl: 'https://example.com/test',
        platform: 'web',
        sourceId: 'test',
      );

      final withXmp = writePngXmp(minimalPng, xmp);
      final read = readPngXmp(withXmp);

      expect(read, isNotNull);
      expect(read!.assetId, 'png-test');
      expect(read.platform, 'web');
    });
  });
}
