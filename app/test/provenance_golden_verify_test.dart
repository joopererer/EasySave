import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/metadata/metadata_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('MetadataService reverse verification: reads back all golden samples successfully', () async {
    final candidates = [
      Directory('spec/fixtures/provenance_golden'),
      Directory('../spec/fixtures/provenance_golden'),
      Directory('../../spec/fixtures/provenance_golden'),
    ];
    final goldenDir = candidates.firstWhere(
      (d) => d.existsSync(),
      orElse: () => throw StateError('provenance_golden fixture directory not found'),
    );

    final subdirs = goldenDir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    expect(subdirs.length, equals(12));

    for (final dir in subdirs) {
      final goldenOutputFile = dir.listSync().whereType<File>().firstWhere(
        (f) => f.uri.pathSegments.last.startsWith('golden_output.'),
      );
      final jsonFile = File('${dir.path}/provenance.json');
      expect(jsonFile.existsSync(), isTrue);

      final expectedJson = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;

      // Read back with MetadataService
      final result = await MetadataService.readProvenance(goldenOutputFile.path);
      expect(result, isNotNull, reason: 'Failed to read provenance from ${dir.path}');

      // If the original input file had no provenance, capture fields match expectedJson.
      // If the original input had existing provenance, SPEC §4.6 capture fields (assetId, capturedAt,
      // platform, sourceId, etc.) are preserved untouched.
      expect(result!.assetId, isNotEmpty);
      expect(result.capturedBy, isNotEmpty);
      if (expectedJson.containsKey('title')) {
        expect(result.title, equals(expectedJson['title']));
      }
      if (expectedJson.containsKey('credit')) {
        expect(result.credit, equals(expectedJson['credit']));
      }
      if (expectedJson.containsKey('aiLabel')) {
        expect(result.aiLabel, equals(expectedJson['aiLabel']));
      }
    }
  });
}

