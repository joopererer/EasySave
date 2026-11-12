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

enum ParserSelectionChoice { builtin, stored, none }

/// One startup comparison between the APK-bundled manifest and the stored
/// release, reported as a single `[ParserUpdate] event=select` line.
class ParserSelection {
  const ParserSelection({
    required this.builtin,
    required this.stored,
    required this.chosen,
    required this.reason,
  });

  final SignedParserManifest? builtin;
  final ParserRelease? stored;
  final ParserSelectionChoice chosen;

  /// `builtin_higher`, `stored_higher`, `same_sequence_same_content`,
  /// `same_sequence_different_content`, `stored_only`, `builtin_only`,
  /// `stored_none`, `stored_unreadable`, `builtin_unavailable` or
  /// `no_release`.
  final String reason;

  SignedParserManifest? get chosenManifest => switch (chosen) {
    ParserSelectionChoice.builtin => builtin,
    ParserSelectionChoice.stored => stored?.manifest,
    ParserSelectionChoice.none => null,
  };
}

/// Only the foreground updater calls activate. Readers never mutate state or caches.
/// One atomically replaced state file commits the selection and anti-rollback watermark.
class ParserReleaseStore {
  ParserReleaseStore(
    this.directory,
    this.publicKeyHex,
    this.appVersion,
    this.schema, {
    this.builtinManifest,
    this.onReadRejected,
  });
  final Directory directory;
  final String publicKeyHex;
  final String appVersion;
  final Map<String, dynamic> schema;
  final SignedParserManifest? builtinManifest;
  final void Function(Object)? onReadRejected;
  File get _stateFile => File('${directory.path}/state.json');

  Map<String, dynamic>? readState() {
    if (!_stateFile.existsSync()) return null;
    final state =
        jsonDecode(_stateFile.readAsStringSync()) as Map<String, dynamic>;
    if (state['highestAcceptedManifestVersion'] is! int ||
        (state['highestAcceptedManifestVersion'] as int) < 1 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(state['contentHash'] as String) ||
        (state['current'] != 'builtin' && !_validReference(state['current'])) ||
        (state['previous'] != null && !_validReference(state['previous']))) {
      throw const FormatException('parser_state');
    }
    return state;
  }

  bool _validReference(Object? value) =>
      value is String &&
      RegExp(r'^[0-9]+-[a-f0-9]{64}-[0-9]+$').hasMatch(value);

  /// Foreground only. Scan every complete cryptographically valid cached bundle;
  /// never infer a watermark from directory names or unverified JSON fields.
  Future<void> recoverStateIfNeeded() async {
    try {
      if (readState() != null) return;
      if (!Directory('${directory.path}/releases').existsSync()) return;
    } catch (_) {
      // Corrupt state is repaired below; readers do not call this method.
    }
    final valid = <ParserRelease>[];
    final releases = Directory('${directory.path}/releases');
    if (releases.existsSync()) {
      for (final entity in releases.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final ref = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        try {
          valid.add(await _read(ref, requireCompatible: false));
        } catch (_) {
          /* Unverified/incomplete bundles cannot raise the floor. */
        }
      }
    }
    valid.sort((a, b) {
      final version = b.manifest.version.compareTo(a.manifest.version);
      return version != 0
          ? version
          : a.manifest.payloadHash.compareTo(b.manifest.payloadHash);
    });
    final cached = valid.firstOrNull;
    final builtin = builtinManifest;
    if (cached == null && builtin == null) {
      throw const FormatException('parser_recovery_no_verified_version');
    }
    final useBuiltin =
        builtin != null &&
        (cached == null || builtin.version > cached.manifest.version);
    final highest = useBuiltin ? builtin : cached!.manifest;
    final current = useBuiltin ? 'builtin' : cached!.reference;
    final previous = valid
        .where(
          (r) => r.reference != current && r.manifest.supportsApp(appVersion),
        )
        .firstOrNull;
    _atomicWrite(
      _stateFile,
      utf8.encode(
        jsonEncode({
          'current': current,
          'previous': previous?.reference,
          'highestAcceptedManifestVersion': highest.version,
          'contentHash': highest.payloadHash,
        }),
      ),
    );
  }

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
    if (state['current'] == 'builtin') return null;
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
      } catch (error) {
        onReadRejected?.call(error);
        // A corrupt current version must not erase the previous usable version.
      }
    }
    return null;
  }

  /// Choose between the APK-bundled manifest and the stored release.
  ///
  /// `manifestVersion` is the release sequence, so it decides: the APK already
  /// carries a newer parser than the one on disk after every parser release, and
  /// never comparing them left the device on the downloaded bundle forever.
  /// Both sides are verified before they are compared — the builtin by
  /// [SignedParserManifest.fromBuiltin] (APK signature plus parser hash), the
  /// stored one by re-reading and re-verifying its Ed25519 envelope.
  ///
  /// Equal sequences are never resolved by picking a winner: identical content
  /// keeps whichever side is already current, and different content keeps the
  /// current side too, because activating the other would be exactly the
  /// equivocation the online check reports. Readers call this; they never write.
  Future<ParserSelection> select() async {
    final builtin = builtinManifest;
    Map<String, dynamic>? state;
    ParserRelease? stored;
    try {
      state = readState();
      stored = await load();
    } catch (_) {
      // An unreadable state file is not a selection: fall back to the floor.
      state = null;
      stored = null;
    }
    final storedManifest = stored?.manifest;
    if (storedManifest == null) {
      if (builtin == null) {
        return const ParserSelection(
          builtin: null,
          stored: null,
          chosen: ParserSelectionChoice.none,
          reason: 'no_release',
        );
      }
      return ParserSelection(
        builtin: builtin,
        stored: null,
        chosen: ParserSelectionChoice.builtin,
        reason: state == null
            ? 'builtin_only'
            : (state['current'] == 'builtin'
                  ? 'stored_none'
                  : 'stored_unreadable'),
      );
    }
    if (builtin == null) {
      return ParserSelection(
        builtin: null,
        stored: stored,
        chosen: ParserSelectionChoice.stored,
        reason: 'builtin_unavailable',
      );
    }
    if (builtin.version > storedManifest.version) {
      return ParserSelection(
        builtin: builtin,
        stored: stored,
        chosen: ParserSelectionChoice.builtin,
        reason: 'builtin_higher',
      );
    }
    if (storedManifest.version > builtin.version) {
      return ParserSelection(
        builtin: builtin,
        stored: stored,
        chosen: ParserSelectionChoice.stored,
        reason: 'stored_higher',
      );
    }
    final current = state?['current'] == 'builtin'
        ? ParserSelectionChoice.builtin
        : ParserSelectionChoice.stored;
    return ParserSelection(
      builtin: builtin,
      stored: stored,
      chosen: current,
      reason: builtin.payloadHash == storedManifest.payloadHash
          ? 'same_sequence_same_content'
          : 'same_sequence_different_content',
    );
  }

  /// Make the APK-bundled manifest the selection and lift the anti-rollback
  /// watermark to it.
  ///
  /// The watermark has to move with the selection, otherwise the next online
  /// check would compare a remote release against a floor the device no longer
  /// runs. It is only ever raised: a sequence already accepted above the builtin
  /// one (a damaged or unreadable cache) keeps its floor and its current
  /// reference, so the online check can still repair that release in place.
  /// Foreground startup is the only caller — readers stay read-only.
  void commitBuiltin(SignedParserManifest builtin, {String? previous}) {
    Map<String, dynamic>? state;
    try {
      state = readState();
    } catch (_) {
      state = null;
    }
    // Nothing was ever stored: the APK is the only source, so there is no
    // sequence to raise the floor to and no state file is created for it.
    if (state == null) return;
    final highest = state['highestAcceptedManifestVersion'] as int;
    if (highest > builtin.version) return;
    if (state['current'] == 'builtin' &&
        highest == builtin.version &&
        state['contentHash'] == builtin.payloadHash) {
      return;
    }
    final retained = state['previous'];
    _atomicWrite(
      _stateFile,
      utf8.encode(
        jsonEncode({
          'current': 'builtin',
          'previous': _validReference(previous)
              ? previous
              : (_validReference(retained) ? retained : null),
          'highestAcceptedManifestVersion': builtin.version,
          'contentHash': builtin.payloadHash,
        }),
      ),
    );
  }

  Future<ParserRelease> _read(
    String reference, {
    bool requireCompatible = true,
  }) async {
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
        (requireCompatible && !manifest.supportsApp(appVersion))) {
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
    final target = File('${directory.path}/link-recognition.json');
    if (manifest == null) {
      // The builtin APK asset is authoritative when no signed release is active.
      // A stale empty projection would mask every route in Kotlin.
      if (target.existsSync()) target.deleteSync();
      return;
    }
    _atomicWrite(
      target,
      utf8.encode(
        jsonEncode({
          ...manifest.recognitionView(appVersion),
          'activated': true,
        }),
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
