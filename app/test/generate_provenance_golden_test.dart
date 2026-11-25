// Copyright 2026 EasySave. All rights reserved.
// Generator for spec/fixtures/provenance_golden/ using provenance_dart via MetadataService.

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/metadata/metadata_service.dart';

void main() {
  test('generate provenance golden outputs', () async {
    final rootDir = Directory('../spec/fixtures/provenance_golden');
    expect(rootDir.existsSync(), isTrue);

    final subdirs = rootDir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final dir in subdirs) {
      final jsonFile = File('${dir.path}/provenance.json');
      expect(jsonFile.existsSync(), isTrue, reason: 'Missing provenance.json in ${dir.path}');
      final jsonMap = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;

      final inputFile = dir.listSync().whereType<File>().firstWhere(
        (f) => f.path.contains('input.'),
      );
      final extension = inputFile.path.split('.').last;
      final outputFile = File('${dir.path}/golden_output.$extension');
      if (outputFile.existsSync()) {
        continue; // 只增不改：已有 golden_output 不覆盖
      }

      // Copy input to output, then embed in place
      inputFile.copySync(outputFile.path);

      final fixedCapturedAt = DateTime.parse(jsonMap['capturedAt'] as String);
      final fixedPublishedAt = DateTime.parse(jsonMap['publishedAt'] as String);
      final fixedMetadataDate = DateTime.parse(jsonMap['metadataDate'] as String);

      final provenance = XmpProvenance(
        schema: jsonMap['schema'] as String? ?? '0.1',
        assetId: jsonMap['assetId'] as String,
        capturedAt: fixedCapturedAt,
        capturedBy: jsonMap['capturedBy'] as String,
        metadataDate: fixedMetadataDate,
        sourceUrl: jsonMap['sourceUrl'] as String?,
        platform: jsonMap['platform'] as String?,
        sourceId: jsonMap['sourceId'] as String?,
        itemIndex: jsonMap['itemIndex'] as int?,
        itemCount: jsonMap['itemCount'] as int?,
        authorId: jsonMap['authorId'] as String?,
        publishedAt: fixedPublishedAt,
        pairId: jsonMap['pairId'] as String?,
        title: jsonMap['title'] as String?,
        creators: (jsonMap['creator'] as List?)?.cast<String>(),
        description: jsonMap['description'] as String?,
        subject: (jsonMap['subject'] as List?)?.cast<String>(),
        credit: jsonMap['credit'] as String?,
        aiLabel: jsonMap['aiLabel'] as String?,
        aiLabelSource: jsonMap['aiLabelSource'] as String?,
        digitalSourceType: jsonMap['digitalSourceType'] as String?,
      );

      final result = await MetadataService.embedProvenance(
        filePath: outputFile.path,
        provenance: provenance,
      );

      expect(result.success, isTrue, reason: 'Failed embedding ${outputFile.path}: ${result.errorCode} ${result.errorMessage}');
      print('Generated: ${outputFile.path} (${outputFile.lengthSync()} bytes)');
    }
  });
}
