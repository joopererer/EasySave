// Parser hot-update manager: fetches manifest.json, verifies Ed25519
// signature and sha256 checksum, caches latest valid bundle locally,
// and enforces remote platform switches and maintenance notices.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../generated/parser_version.dart';

/// Ed25519 public key (32 bytes raw, hex encoded) for parser bundle verification.
/// Replace this constant with your generated public key.
const String kDefaultParserPublicKeyHex =
    'ca4f1c302d00220e32178d2e9b47fd589dffc38e8c9711fe93327a44aa199ded';

const String kDefaultManifestUrl =
    'https://raw.githubusercontent.com/joopererer/EasySave/master/spec/manifest.json';

const String kPrefKeyLastUpdateCheckMs = 'parser_last_update_check_ms';

enum ParserSource { builtin, remote }

class PlatformConfig {
  PlatformConfig({this.enabled = true, this.notice = ''});

  final bool enabled;
  final String notice;

  factory PlatformConfig.fromJson(Map<String, dynamic> json) => PlatformConfig(
    enabled: json['enabled'] as bool? ?? true,
    notice: json['notice'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'enabled': enabled, 'notice': notice};
}

class ParserManifest {
  ParserManifest({
    required this.parserVersion,
    required this.minAppVersion,
    required this.sha256,
    required this.signature,
    this.platforms = const {},
    this.headers = const {},
  });

  final String parserVersion;
  final String minAppVersion;
  final String sha256;
  final String signature;
  final Map<String, PlatformConfig> platforms;
  final Map<String, Map<String, String>> headers;

  factory ParserManifest.fromJson(Map<String, dynamic> json) {
    final rawPlatforms = json['platforms'] as Map?;
    final platforms = <String, PlatformConfig>{};
    if (rawPlatforms != null) {
      for (final entry in rawPlatforms.entries) {
        if (entry.value is Map) {
          platforms[entry.key.toString()] = PlatformConfig.fromJson(
            (entry.value as Map).cast<String, dynamic>(),
          );
        }
      }
    }

    final rawHeaders = json['headers'] as Map?;
    final headers = <String, Map<String, String>>{};
    if (rawHeaders != null) {
      for (final entry in rawHeaders.entries) {
        if (entry.value is Map) {
          headers[entry.key.toString()] = (entry.value as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          );
        }
      }
    }

    return ParserManifest(
      parserVersion: json['parserVersion'] as String? ?? '0.0.0',
      minAppVersion: json['minAppVersion'] as String? ?? '1.0.0',
      sha256: json['sha256'] as String? ?? '',
      signature: json['signature'] as String? ?? '',
      platforms: platforms,
      headers: headers,
    );
  }

  Map<String, dynamic> toJson() => {
    'parserVersion': parserVersion,
    'minAppVersion': minAppVersion,
    'sha256': sha256,
    'signature': signature,
    'platforms': platforms.map((k, v) => MapEntry(k, v.toJson())),
    'headers': headers,
  };
}

/// Utility functions for cryptography and version checking
class UpdateVerifier {
  static Uint8List hexToBytes(String hexString) {
    final clean = hexString.replaceAll(RegExp(r'\s+'), '');
    if (clean.length.isOdd) {
      throw FormatException('Invalid hex length');
    }
    final bytes = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < clean.length; i += 2) {
      bytes[i ~/ 2] = int.parse(clean.substring(i, i + 2), radix: 16);
    }
    return bytes;
  }

  static String bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Verify SHA-256 hash using package:crypto
  static bool verifySha256(Uint8List content, String expectedSha256Hex) {
    if (expectedSha256Hex.isEmpty) return false;
    final digest = crypto.sha256.convert(content);
    return digest.toString().toLowerCase() == expectedSha256Hex.toLowerCase();
  }

  /// Verify Ed25519 signature using package:cryptography
  static Future<bool> verifyEd25519(
    Uint8List content, {
    required String signatureHex,
    required String publicKeyHex,
  }) async {
    try {
      final sigBytes = hexToBytes(signatureHex);
      final pubBytes = hexToBytes(publicKeyHex);
      if (sigBytes.length != 64 || pubBytes.length != 32) {
        return false;
      }
      final algorithm = Ed25519();
      final publicKey = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
      final signature = Signature(sigBytes, publicKey: publicKey);
      return await algorithm.verify(content, signature: signature);
    } catch (_) {
      return false;
    }
  }

  /// Canonicalize manifest JSON by sorting keys recursively (omitting 'signature')
  /// into compact JSON matching Node.js JSON.stringify.
  static String canonicalizeManifest(Map<String, dynamic> json) {
    dynamic sortVal(dynamic v) {
      if (v is Map) {
        final sortedKeys = v.keys.map((k) => k.toString()).toList()..sort();
        final map = <String, dynamic>{};
        for (final k in sortedKeys) {
          if (k == 'signature') continue;
          map[k] = sortVal(v[k]);
        }
        return map;
      }
      return v;
    }

    final sorted = sortVal(json);
    return jsonEncode(sorted);
  }

  /// Compare two semantic version strings (ignoring +build metadata).
  /// Returns > 0 if v1 > v2, < 0 if v1 < v2, 0 if v1 == v2.
  static int compareVersions(String v1, String v2) {
    final v1Clean = v1.split('+').first.trim();
    final v2Clean = v2.split('+').first.trim();

    final p1 = v1Clean.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final p2 = v2Clean.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    while (p1.length < 3) {
      p1.add(0);
    }
    while (p2.length < 3) {
      p2.add(0);
    }

    for (var i = 0; i < 3; i++) {
      if (p1[i] > p2[i]) return 1;
      if (p1[i] < p2[i]) return -1;
    }
    return 0;
  }

  /// Check if currentAppVersion meets minAppVersion requirement.
  /// Ignores build numbers (e.g. 1.0.0+2 -> 1.0.0).
  static bool isAppVersionSupported(
    String currentAppVersion,
    String minAppVersion,
  ) {
    return compareVersions(currentAppVersion, minAppVersion) >= 0;
  }
}

class ParserManager {
  ParserManager._();
  static final ParserManager instance = ParserManager._();

  String _publicKeyHex = kDefaultParserPublicKeyHex;
  String _manifestUrl = kDefaultManifestUrl;
  http.Client _client = http.Client();
  Directory? _cacheDir;
  SharedPreferences? _prefs;

  String _activeVersion = ParserVersion.version;
  ParserSource _activeSource = ParserSource.builtin;
  String? _activeScript;
  ParserManifest? _activeManifest;

  String get activeVersion => _activeVersion;
  ParserSource get activeSource => _activeSource;
  String get activeSourceLabel =>
      _activeSource == ParserSource.remote ? '云端' : '内置';
  ParserManifest? get activeManifest => _activeManifest;

  void configure({
    String? publicKeyHex,
    String? manifestUrl,
    http.Client? client,
    Directory? cacheDir,
    SharedPreferences? prefs,
  }) {
    if (publicKeyHex != null) _publicKeyHex = publicKeyHex;
    if (manifestUrl != null) _manifestUrl = manifestUrl;
    if (client != null) _client = client;
    if (cacheDir != null) _cacheDir = cacheDir;
    if (prefs != null) _prefs = prefs;
  }

  Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/parser_cache');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<SharedPreferences> _getPrefs() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Initialize and load the active parser. Checks local cache first;
  /// if verified, loads cached remote parser; otherwise falls back to builtin.
  Future<void> init() async {
    _activeVersion = ParserVersion.version;
    _activeSource = ParserSource.builtin;
    _activeScript = null;
    _activeManifest = null;

    try {
      final dir = await _getCacheDir();
      final scriptFile = File('${dir.path}/parser.js');
      final manifestFile = File('${dir.path}/manifest.json');

      if (scriptFile.existsSync() && manifestFile.existsSync()) {
        final manifestJson =
            jsonDecode(manifestFile.readAsStringSync(encoding: utf8))
                as Map<String, dynamic>;
        final manifest = ParserManifest.fromJson(manifestJson);
        final scriptBytes = scriptFile.readAsBytesSync();

        // Verify hash
        final isHashValid = UpdateVerifier.verifySha256(
          scriptBytes,
          manifest.sha256,
        );
        // Verify signature of canonical manifest
        final canonicalString =
            UpdateVerifier.canonicalizeManifest(manifestJson);
        final canonicalBytes = Uint8List.fromList(utf8.encode(canonicalString));
        final isSigValid = await UpdateVerifier.verifyEd25519(
          canonicalBytes,
          signatureHex: manifest.signature,
          publicKeyHex: _publicKeyHex,
        );
        // Verify minAppVersion
        String appVersion = '1.0.0';
        try {
          final info = await PackageInfo.fromPlatform();
          appVersion = info.version;
        } catch (_) {}

        final isAppSupported = UpdateVerifier.isAppVersionSupported(
          appVersion,
          manifest.minAppVersion,
        );

        // Anti-downgrade check: remote parserVersion must be strictly greater than built-in version
        final isNewerThanBuiltin = UpdateVerifier.compareVersions(
          manifest.parserVersion,
          ParserVersion.version,
        ) > 0;

        if (isHashValid && isSigValid && isAppSupported && isNewerThanBuiltin) {
          _activeVersion = manifest.parserVersion;
          _activeSource = ParserSource.remote;
          _activeScript = utf8.decode(scriptBytes);
          _activeManifest = manifest;
          debugPrint(
            'ParserManager: loaded remote parser v$_activeVersion from cache',
          );
          return;
        } else {
          debugPrint(
            'ParserManager: cached parser verification failed; falling back to builtin',
          );
          // Invalidate broken cache
          try {
            scriptFile.deleteSync();
            manifestFile.deleteSync();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint(
        'ParserManager: cache read error: $e; falling back to builtin',
      );
    }

    await _loadBuiltin();
  }

  Future<void> _loadBuiltin() async {
    _activeVersion = ParserVersion.version;
    _activeSource = ParserSource.builtin;
    _activeScript = await rootBundle.loadString('assets/parser/parser.js');
    _activeManifest = null;
    debugPrint('ParserManager: using builtin parser v$_activeVersion');
  }

  Future<String> getActiveScript() async {
    if (_activeScript != null && _activeScript!.isNotEmpty) {
      return _activeScript!;
    }
    await _loadBuiltin();
    return _activeScript!;
  }

  /// Check remote server for updates (at most once every 6 hours unless forced)
  Future<bool> checkForUpdates({bool force = false}) async {
    try {
      final prefs = await _getPrefs();
      final now = DateTime.now().millisecondsSinceEpoch;
      final lastCheck = prefs.getInt(kPrefKeyLastUpdateCheckMs) ?? 0;

      const sixHoursMs = 6 * 3600 * 1000;
      if (!force && (now - lastCheck < sixHoursMs)) {
        debugPrint(
          'ParserManager: update check throttled (< 6 hours since last check)',
        );
        return false;
      }

      final baseManifestUri = Uri.parse(_manifestUrl);
      final manifestUri = force
          ? baseManifestUri.replace(queryParameters: {
              ...baseManifestUri.queryParameters,
              't': '$now',
            })
          : baseManifestUri;
      final manifestResp = await _client
          .get(manifestUri, headers: const {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 10));
      if (manifestResp.statusCode != 200) {
        debugPrint(
          'ParserManager: manifest fetch failed (HTTP ${manifestResp.statusCode})',
        );
        return false;
      }

      final manifestJson =
          jsonDecode(utf8.decode(manifestResp.bodyBytes))
              as Map<String, dynamic>;
      final manifest = ParserManifest.fromJson(manifestJson);

      // Verify minAppVersion
      String appVersion = '1.0.0';
      try {
        final info = await PackageInfo.fromPlatform();
        appVersion = info.version;
      } catch (_) {}

      // Anti-downgrade check: remote parserVersion must be strictly greater than built-in version
      if (UpdateVerifier.compareVersions(
            manifest.parserVersion,
            ParserVersion.version,
          ) <=
          0) {
        debugPrint(
          'ParserManager: remote parserVersion (${manifest.parserVersion}) <= builtin (${ParserVersion.version}), skipping',
        );
        return false;
      }

      if (!UpdateVerifier.isAppVersionSupported(
        appVersion,
        manifest.minAppVersion,
      )) {
        debugPrint(
          'ParserManager: minAppVersion (${manifest.minAppVersion}) > current ($appVersion), skipping',
        );
        return false;
      }

      // Download parser.js
      final baseParserUri = manifestUri.resolve('parser.js');
      final parserUri = force
          ? baseParserUri.replace(queryParameters: {
              ...baseParserUri.queryParameters,
              't': '$now',
            })
          : baseParserUri;
      final parserResp = await _client
          .get(parserUri, headers: const {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 15));
      if (parserResp.statusCode != 200) {
        debugPrint(
          'ParserManager: parser.js fetch failed (HTTP ${parserResp.statusCode})',
        );
        return false;
      }

      final parserBytes = parserResp.bodyBytes;

      // Verify SHA256
      if (!UpdateVerifier.verifySha256(parserBytes, manifest.sha256)) {
        debugPrint(
          'ParserManager: parser.js SHA256 mismatch! Remote rejected.',
        );
        return false;
      }

      // Verify Ed25519 signature of canonical manifest
      final canonicalString =
          UpdateVerifier.canonicalizeManifest(manifestJson);
      final canonicalBytes = Uint8List.fromList(utf8.encode(canonicalString));
      final isSigValid = await UpdateVerifier.verifyEd25519(
        canonicalBytes,
        signatureHex: manifest.signature,
        publicKeyHex: _publicKeyHex,
      );
      if (!isSigValid) {
        debugPrint(
          'ParserManager: manifest Ed25519 signature invalid! Remote rejected.',
        );
        return false;
      }

      // Save to local cache
      final dir = await _getCacheDir();
      final scriptFile = File('${dir.path}/parser.js');
      final manifestFile = File('${dir.path}/manifest.json');
      scriptFile.writeAsBytesSync(parserBytes, flush: true);
      manifestFile.writeAsStringSync(
        jsonEncode(manifest.toJson()),
        encoding: utf8,
        flush: true,
      );

      // Activate remote version
      _activeVersion = manifest.parserVersion;
      _activeSource = ParserSource.remote;
      _activeScript = utf8.decode(parserBytes);
      _activeManifest = manifest;

      // Update check timestamp
      await prefs.setInt(kPrefKeyLastUpdateCheckMs, now);
      debugPrint(
        'ParserManager: successfully updated to remote parser v$_activeVersion',
      );
      return true;
    } catch (e) {
      debugPrint('ParserManager: error during update check: $e');
      return false;
    }
  }

  /// Remote platform switch: check if platform is currently enabled
  bool isPlatformEnabled(String platform) {
    if (_activeManifest == null) return true;
    final cfg = _activeManifest!.platforms[platform];
    return cfg?.enabled ?? true;
  }

  /// Remote platform maintenance notice
  String? getMaintenanceNotice(String platform) {
    if (_activeManifest == null) return null;
    final cfg = _activeManifest!.platforms[platform];
    if (cfg == null || cfg.enabled) return null;
    return cfg.notice.isNotEmpty ? cfg.notice : '该平台解析服务维护中，请稍后再试';
  }
}
