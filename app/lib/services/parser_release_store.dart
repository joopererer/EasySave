import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'signed_parser_manifest.dart';

class ParserRelease {
  ParserRelease(this.reference, this.manifest, this.script);
  final String reference;
  final SignedParserManifest manifest;
  final String script;
}

/// Only the foreground updater calls activate. Readers never mutate state or caches.
/// One atomically replaced state file commits the selection and anti-rollback watermark.
class ParserReleaseStore {
  ParserReleaseStore(
    this.directory,
    this.publicKeyHex,
    this.appVersion,
    this.schema,
  );
  final Directory directory;
  final String publicKeyHex;
  final String appVersion;
  final Map<String, dynamic> schema;
  File get _stateFile => File('${directory.path}/state.json');

  Map<String, dynamic>? readState() {
    if (!_stateFile.existsSync()) return null;
    final state =
        jsonDecode(_stateFile.readAsStringSync()) as Map<String, dynamic>;
    if (state['highestAcceptedManifestVersion'] is! int ||
        (state['highestAcceptedManifestVersion'] as int) < 1 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(state['contentHash'] as String) ||
        !_validReference(state['current']) ||
        (state['previous'] != null && !_validReference(state['previous']))) {
      throw const FormatException('parser_state');
    }
    return state;
  }

  bool _validReference(Object? value) =>
      value is String &&
      RegExp(r'^[0-9]+-[a-f0-9]{64}-[0-9]+$').hasMatch(value);

  void checkWatermark(
    SignedParserManifest manifest,
    Map<String, dynamic>? state,
  ) {
    if (state == null) return;
    final highest = state['highestAcceptedManifestVersion'] as int;
    if (manifest.version < highest ||
        (manifest.version == highest &&
            manifest.payloadHash != state['contentHash'])) {
      throw const FormatException('parser_rollback');
    }
  }

  Future<ParserRelease?> load() async {
    final state = readState();
    if (state == null) return null;
    for (final reference in [state['current'], state['previous']]) {
      if (reference is! String) continue;
      try {
        final release = await _read(reference);
        final manifest = release.manifest;
        final highest = state['highestAcceptedManifestVersion'] as int;
        if (reference == state['current']) {
          if (manifest.version != highest ||
              manifest.payloadHash != state['contentHash']) {
            continue;
          }
        } else if (manifest.version > highest ||
            (manifest.version == highest &&
                manifest.payloadHash != state['contentHash'])) {
          continue;
        }
        return release;
      } catch (_) {
        // A corrupt current version must not erase the previous usable version.
      }
    }
    return null;
  }

  Future<ParserRelease> _read(String reference) async {
    if (!_validReference(reference)) {
      throw const FormatException('parser_reference');
    }
    final base = '${directory.path}/releases/$reference';
    final manifest = await SignedParserManifest.verify(
      File('$base/manifest.json').readAsBytesSync(),
      publicKeyHex: publicKeyHex,
      schema: schema,
    );
    if (!reference.startsWith('${manifest.version}-${manifest.payloadHash}-') ||
        !manifest.supportsApp(appVersion)) {
      throw const FormatException('parser_compatibility');
    }
    final scriptBytes = File('$base/parser.js').readAsBytesSync();
    if (crypto.sha256.convert(scriptBytes).toString() != manifest.sha256) {
      throw const FormatException('parser_hash');
    }
    return ParserRelease(reference, manifest, utf8.decode(scriptBytes));
  }

  Future<ParserRelease> activate(
    SignedParserManifest manifest,
    List<int> parser,
  ) async {
    // The caller verifies before downloading; repeat checks at the commit boundary.
    final verified = await SignedParserManifest.verify(
      manifest.rawBytes,
      publicKeyHex: publicKeyHex,
      schema: schema,
    );
    if (!verified.supportsApp(appVersion) ||
        crypto.sha256.convert(parser).toString() != verified.sha256) {
      throw const FormatException('parser_candidate');
    }
    final state =
        readState(); // Malformed state fails closed, never resets the watermark.
    checkWatermark(verified, state);
    final previous = await load();
    final reference =
        '${verified.version}-${verified.payloadHash}-${DateTime.now().microsecondsSinceEpoch}';
    final releaseDirectory = Directory('${directory.path}/releases/$reference');
    releaseDirectory.createSync(recursive: true);
    File(
      '${releaseDirectory.path}/manifest.json',
    ).writeAsBytesSync(verified.rawBytes, flush: true);
    File(
      '${releaseDirectory.path}/parser.js',
    ).writeAsBytesSync(parser, flush: true);
    final candidate = await _read(reference);
    final next = {
      'current': reference,
      'previous': previous?.reference,
      'highestAcceptedManifestVersion': verified.version,
      'contentHash': verified.payloadHash,
    };
    // This single rename is the activation commit. Failures before it leave the old
    // selection AND watermark intact; incomplete directories are never read as active.
    _atomicWrite(_stateFile, utf8.encode(jsonEncode(next)));
    return candidate;
  }

  void writeRecognitionView(SignedParserManifest? manifest) {
    // This projection is an entrance hint, never a security authority.
    _atomicWrite(
      File('${directory.path}/link-recognition.json'),
      utf8.encode(
        jsonEncode(manifest?.recognitionView(appVersion) ?? {'sites': []}),
      ),
    );
  }

  void _atomicWrite(File target, List<int> bytes) {
    directory.createSync(recursive: true);
    final temp = File('${target.path}.tmp');
    temp.writeAsBytesSync(bytes, flush: true);
    temp.renameSync(target.path);
  }
}
