import 'dart:io';

import 'package:flutter/services.dart';

import '../core/dev_log.dart';
import '../metadata/metadata_service.dart';
import 'site_registry.dart';

typedef SavedMedia = ({String? mediaId, String? title, String? relativePath});
typedef SaveCollisionOutcome = ({SavedMedia saved, String? reusedAssetId});

bool sameSavedOrigin(XmpProvenance? found, XmpProvenance expected) =>
    found != null &&
    found.platform != null &&
    expected.platform != null &&
    SiteRegistry.current.sameSite(found.platform!, expected.platform!) &&
    found.sourceId == expected.sourceId &&
    found.itemIndex == expected.itemIndex;

String conflictFilename(String original, int number) {
  final dot = original.lastIndexOf('.');
  final indexSeparator = original.lastIndexOf('_', dot);
  if (dot < 0 || indexSeparator < 0 || number < 2) {
    throw ArgumentError.value(original, 'original', 'Invalid media filename');
  }
  return '${original.substring(0, indexSeparator)}-copy$number'
      '${original.substring(indexSeparator)}';
}

Future<Map<String, String>?> inspectSavedTarget(
  String filename, {
  required bool pair,
  required String album,
}) async {
  final result = await const MethodChannel('easysave/provenance_pair')
      .invokeMapMethod<String, String>('inspectTarget', {
        'filename': filename,
        'pair': pair,
        'album': album,
      });
  return result;
}

Future<XmpProvenance?> readInspectedOrigin(
  Map<String, String> row, {
  required bool pair,
}) async {
  if (pair) {
    final xml = row['sidecarXml'];
    if (xml == null) return null;
    try {
      return mergeProvenanceXml(null, xml);
    } catch (_) {
      return null;
    }
  }
  final path = row['probePath'];
  if (path == null) return null;
  try {
    return await MetadataService.readProvenance(path);
  } catch (_) {
    return null;
  } finally {
    final copy = File(path);
    if (await copy.exists()) await copy.delete();
  }
}

Future<SaveCollisionOutcome> saveWithConflictHandling({
  required String filename,
  required String tempPath,
  required String album,
  required bool pair,
  required XmpProvenance expected,
  required Future<SavedMedia> Function(String name) save,
  Future<Map<String, String>?> Function(String name)? inspect,
  Future<XmpProvenance?> Function(Map<String, String> row)? readOrigin,
}) async {
  final lookup =
      inspect ?? (name) => inspectSavedTarget(name, pair: pair, album: album);
  final read = readOrigin ?? (row) => readInspectedOrigin(row, pair: pair);
  for (var attempt = 1; attempt <= 20; attempt++) {
    final name = attempt == 1 ? filename : conflictFilename(filename, attempt);
    final row = await lookup(name);
    if (row != null) {
      final origin = await read(row);
      if (sameSavedOrigin(origin, expected)) {
        for (final path in [tempPath, '$tempPath.xmp']) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
        return (
          saved: (
            mediaId: row['mediaId'],
            title: row['title'],
            relativePath: row['relativePath'],
          ),
          reusedAssetId: origin!.assetId,
        );
      }
      await DevLog.write(
        'SaveCollision',
        'unrelated target; choosing another filename',
      );
      continue;
    }
    try {
      return (saved: await save(name), reusedAssetId: null);
    } on PlatformException catch (error) {
      final message = error.message ?? '';
      if (!message.contains('Target filename already exists') &&
          !message.contains('Provider changed final filename')) {
        rethrow;
      }
      // A concurrent save won between lookup and insert. Inspect it next.
      final raced = await lookup(name);
      final racedOrigin = raced == null ? null : await read(raced);
      if (raced != null && sameSavedOrigin(racedOrigin, expected)) {
        for (final path in [tempPath, '$tempPath.xmp']) {
          final file = File(path);
          if (await file.exists()) await file.delete();
        }
        return (
          saved: (
            mediaId: raced['mediaId'],
            title: raced['title'],
            relativePath: raced['relativePath'],
          ),
          reusedAssetId: racedOrigin!.assetId,
        );
      }
      await DevLog.write(
        'SaveCollision',
        'target occupied during save; retrying with another filename',
      );
    }
  }
  throw StateError('无法找到不冲突的保存文件名');
}
