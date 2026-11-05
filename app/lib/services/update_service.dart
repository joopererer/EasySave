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
import '../core/dev_log.dart';
import 'parser_config_contract.dart';
import 'signed_parser_manifest.dart';
import 'parser_release_store.dart';
import 'https_parser_download.dart';
import 'site_registry.dart';

/// Ed25519 public key (32 bytes raw, hex encoded) for parser bundle verification.
/// Replace this constant with your generated public key.
const String kDefaultParserPublicKeyHex =
    'ca4f1c302d00220e32178d2e9b47fd589dffc38e8c9711fe93327a44aa199ded';

const String kDefaultManifestUrl =
    'https://raw.githubusercontent.com/joopererer/EasySave/master/spec/v2/manifest.json';

const String kPrefKeyLastUpdateCheckMs = 'parser_v2_last_update_check_ms';

enum ParserSource { builtin, remote }

class PlatformConfig {
  PlatformConfig({
    this.enabled = true,
    this.notice = '',
    this.endpoint = '',
    this.tokenFormula = '',
  });

  final bool enabled;
  final String notice;
  final String endpoint;
  final String tokenFormula;

  factory PlatformConfig.fromJson(Map<String, dynamic> json) => PlatformConfig(
    enabled: json['enabled'] as bool? ?? true,
    notice: json['notice'] as String? ?? '',
    endpoint: json['endpoint'] as String? ?? '',
    tokenFormula: json['tokenFormula'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'notice': notice,
    if (endpoint.isNotEmpty) 'endpoint': endpoint,
    if (tokenFormula.isNotEmpty) 'tokenFormula': tokenFormula,
  };
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
  @visibleForTesting
  ParserManager.forTesting();
  static final ParserManager instance = ParserManager._();

  String _publicKeyHex = kDefaultParserPublicKeyHex;
  String _manifestUrl = kDefaultManifestUrl;
  http.Client _client = http.Client();
  Directory? _cacheDir;
  SharedPreferences? _prefs;
  String? _appVersion;
  Map<String, dynamic>? _schema;
  SignedParserManifest? _builtin;
  String? _lastActivation;
  bool _canUpdate = false;
  Future<bool>? _updating;

  String _activeVersion = ParserVersion.version;
  ParserSource _activeSource = ParserSource.builtin;
  ParserManifest? _activeManifest;
  SignedParserManifest? _signedManifest;

  String get activeVersion => _activeVersion;
  ParserSource get activeSource => _activeSource;
  String get activeSourceLabel =>
      _activeSource == ParserSource.remote ? '云端' : '内置';
  ParserManifest? get activeManifest => _activeManifest;
  SignedParserManifest? get activeSignedManifest => _signedManifest;

  void configure({
    String? publicKeyHex,
    String? manifestUrl,
    http.Client? client,
    Directory? cacheDir,
    SharedPreferences? prefs,
    String? appVersion,
  }) {
    if (publicKeyHex != null) _publicKeyHex = publicKeyHex;
    if (manifestUrl != null) _manifestUrl = manifestUrl;
    if (client != null) _client = client;
    if (cacheDir != null) _cacheDir = cacheDir;
    if (prefs != null) _prefs = prefs;
    if (appVersion != null) _appVersion = appVersion;
  }

  Future<ParserReleaseStore> _store() async {
    final base =
        _cacheDir ??
        Directory('${(await getApplicationSupportDirectory()).path}/parser_v2');
    _schema ??=
        jsonDecode(
              await rootBundle.loadString(
                'assets/parser/sites-manifest.schema.json',
              ),
            )
            as Map<String, dynamic>;
    _appVersion ??= (await PackageInfo.fromPlatform()).version;
    final builtin = SignedParserManifest.fromBuiltin(
      await rootBundle.loadString('assets/parser/builtin-manifest.json'),
      (await rootBundle.load('assets/parser/parser.js')).buffer.asUint8List(),
      _schema!,
    );
    _builtin = builtin;
    return ParserReleaseStore(
      base,
      _publicKeyHex,
      _appVersion!,
      _schema!,
      builtinManifest: builtin,
      onReadRejected: _logMissingConfig,
    );
  }

  Future<void> init({bool canUpdate = false}) async {
    _canUpdate = canUpdate;
    await _selectVerified();
    if (_canUpdate) await _refreshRecognitionView();
  }

  void _useBuiltin() {
    SiteRegistry.useBuiltin();
    _activeVersion = ParserVersion.version;
    _activeSource = ParserSource.builtin;
    _activeManifest = null;
    _signedManifest = null;
    _logActivation(_builtin, 'builtin');
  }

  void _logActivation(SignedParserManifest? manifest, String source) {
    if (manifest == null) return;
    final hash = crypto.sha256
        .convert(
          utf8.encode(
            jsonEncode({
              for (final e in manifest.payload.entries)
                if (!{
                  'manifestVersion',
                  'parserVersion',
                  'parserUrl',
                  'sha256',
                }.contains(e.key))
                  e.key: e.value,
            }),
          ),
        )
        .toString();
    final line =
        'event=activated version=${manifest.parserVersion} source=$source manifestVersion=${manifest.version} configHash=$hash';
    if (_lastActivation == line) return;
    _lastActivation = line;
    unawaited(DevLog.write('ParserUpdate', line));
  }

  void _validateConfig(SignedParserManifest manifest) {
    try {
      validateAppParserConfig(manifest.payload);
    } on FormatException catch (e) {
      unawaited(
        DevLog.write('ParserUpdate', 'event=rejected reason=${e.message}'),
      );
      _useBuiltin();
      rethrow;
    }
  }

  void _useRemote(ParserRelease release) {
    final manifest = release.manifest;
    _validateConfig(manifest);
    _signedManifest = manifest;
    SiteRegistry.activate(manifest.sitesFor(_appVersion!));
    _activeVersion = manifest.parserVersion;
    _activeSource = ParserSource.remote;
    // Temporary compatibility adapter: existing platform branches remain until 2b.
    final json = Map<String, dynamic>.from(manifest.payload);
    final platforms = Map<String, dynamic>.from(
      json['platforms'] as Map? ?? {},
    );
    final compatible = manifest
        .sitesFor(_appVersion!)
        .map((s) => s['id'])
        .toSet();
    for (final site in manifest.sites) {
      if (!compatible.contains(site['id'])) {
        platforms[site['id'] as String] = {
          'enabled': false,
          'notice': '请更新 EasySave 后使用该站点',
        };
      }
    }
    json['platforms'] = platforms;
    _activeManifest = ParserManifest.fromJson(json);
    _logActivation(manifest, 'remote');
  }

  Future<ParserRelease?> _selectVerified() async {
    try {
      final store = await _store();
      if (_canUpdate) await store.recoverStateIfNeeded();
      final release = await store.load();
      if (release != null) {
        _useRemote(release);
        return release;
      }
    } catch (error) {
      _logMissingConfig(error);
      debugPrint('ParserManager: local v2 bundle unavailable');
    }
    _useBuiltin();
    return null;
  }

  Future<void> _refreshRecognitionView() async {
    try {
      (await _store()).writeRecognitionView(_signedManifest);
    } catch (_) {
      // Projection failure does not undo a committed, verified release. Foreground
      // startup/use retries it. Kotlin only uses this file as a recognition hint.
      debugPrint('ParserManager: recognition projection unavailable');
    }
  }

  Future<String> getActiveScript() async {
    // Re-read and verify original manifest + parser bytes on every use, including
    // background-engine uses. No cached remote executable is trusted in memory.
    final release = await _selectVerified();
    if (_canUpdate) await _refreshRecognitionView();
    return release?.script ??
        await rootBundle.loadString('assets/parser/parser.js');
  }

  Future<bool> checkForUpdates({bool force = false}) {
    if (!_canUpdate) return Future.value(false);
    return _updating ??= _checkForUpdates(
      force,
    ).whenComplete(() => _updating = null);
  }

  Future<bool> _checkForUpdates(bool force) async {
    try {
      final store = await _store();
      await store.recoverStateIfNeeded();
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = prefs.getInt(kPrefKeyLastUpdateCheckMs) ?? 0;
      if (!force && now - last < const Duration(days: 1).inMilliseconds) {
        return false;
      }
      // Count failed attempts too: foreground automatic checks run at most daily.
      await prefs.setInt(kPrefKeyLastUpdateCheckMs, now);
      final uri = Uri.parse(_manifestUrl);
      if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) return false;
      final stateBeforeFetch = store.readState();
      final cachedBeforeFetch = await store.load();
      // A cached ETag cannot stand in for a damaged/missing current bundle.
      // Omit it so the server returns the bytes needed to repair that release.
      final etag =
          cachedBeforeFetch?.reference == stateBeforeFetch?['current'] &&
              cachedBeforeFetch != null
          ? prefs.getString('parser_v2_etag')
          : null;
      final response = await _client
          .get(
            uri,
            headers: {if (!force && etag != null) 'If-None-Match': etag},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 304) {
        await _selectVerified();
        await _refreshRecognitionView();
        return false;
      }
      if (response.statusCode != 200) return false;
      final manifest = await SignedParserManifest.verify(
        response.bodyBytes,
        publicKeyHex: _publicKeyHex,
        schema: _schema!,
      );
      if (!manifest.supportsApp(_appVersion!)) return false;
      _validateConfig(manifest);
      store.checkWatermark(manifest, store.readState());
      final current = await store.load();
      if (current != null &&
          current.manifest.version == manifest.version &&
          current.manifest.payloadHash == manifest.payloadHash) {
        return false;
      }
      final parser = await downloadParserHttps(
        _client,
        Uri.parse(manifest.parserUrl),
      ).timeout(const Duration(seconds: 30));
      if (parser.statusCode != 200 ||
          parser.bodyBytes.length > 10 * 1024 * 1024) {
        return false;
      }
      final release = await store.activate(manifest, parser.bodyBytes);
      _useRemote(release);
      await _refreshRecognitionView();
      final nextEtag = response.headers['etag'];
      if (nextEtag != null) {
        await prefs.setString('parser_v2_etag', nextEtag);
      } else {
        await prefs.remove('parser_v2_etag');
      }
      return true;
    } catch (error) {
      _logMissingConfig(error);
      debugPrint(
        'ParserManager: v2 update rejected; retaining current release',
      );
      return false;
    }
  }

  void _logMissingConfig(Object error) {
    if (error is! FormatException ||
        !error.message.startsWith('missing_config:')) {
      return;
    }
    final field = error.message.substring('missing_config:'.length);
    // Required names come from the trusted APK schema, never payload contents.
    if (!RegExp(r'^[A-Za-z0-9_.\[\]]{1,256}$').hasMatch(field)) return;
    unawaited(DevLog.write('ParserUpdate', 'event=rejected reason=$field'));
    _useBuiltin();
  }

  bool isPlatformEnabled(String platform) {
    return _activeManifest?.platforms[platform]?.enabled ?? true;
  }

  String? getMaintenanceNotice(String platform) {
    final cfg = _activeManifest?.platforms[platform];
    if (cfg == null || cfg.enabled) return null;
    return cfg.notice.isNotEmpty ? cfg.notice : '该平台解析服务维护中，请稍后再试';
  }

  Map<String, String>? getPlatformHeaders(String platform) {
    if (_activeManifest != null &&
        _activeManifest!.headers.containsKey(platform)) {
      return _activeManifest!.headers[platform];
    }
    if (platform == 'x') {
      return const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
      };
    }
    return null;
  }

  String getPlatformEndpoint(String platform) {
    final endpoint = _activeManifest?.platforms[platform]?.endpoint;
    if (endpoint != null && endpoint.isNotEmpty) return endpoint;
    if (platform == 'x') {
      return 'https://cdn.syndication.twimg.com/tweet-result?id={id}&lang=en&token={token}';
    }
    return '';
  }
}
