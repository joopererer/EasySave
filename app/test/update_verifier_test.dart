import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:easysave/generated/parser_version.dart';
import 'package:easysave/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateVerifier', () {
    test('verifySha256 validates correctly', () {
      final data = Uint8List.fromList(utf8.encode('hello world'));
      const expected =
          'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9';
      expect(UpdateVerifier.verifySha256(data, expected), isTrue);
      expect(UpdateVerifier.verifySha256(data, expected.toUpperCase()), isTrue);
      expect(UpdateVerifier.verifySha256(data, 'wronghash'), isFalse);
      expect(UpdateVerifier.verifySha256(data, ''), isFalse);
    });

    test('verifyEd25519 verifies valid and rejects tampered signatures', () async {
      final ed = Ed25519();
      final keyPair = await ed.newKeyPair();
      final pubKey = await keyPair.extractPublicKey();
      final pubHex = UpdateVerifier.bytesToHex(pubKey.bytes);

      final message = Uint8List.fromList(utf8.encode('parser bundle content'));
      final signature = await ed.sign(message, keyPair: keyPair);
      final sigHex = UpdateVerifier.bytesToHex(signature.bytes);

      // Valid signature
      final valid = await UpdateVerifier.verifyEd25519(
        message,
        signatureHex: sigHex,
        publicKeyHex: pubHex,
      );
      expect(valid, isTrue);

      // Tampered message
      final tamperedMessage = Uint8List.fromList(utf8.encode('tampered parser'));
      final tamperedValid = await UpdateVerifier.verifyEd25519(
        tamperedMessage,
        signatureHex: sigHex,
        publicKeyHex: pubHex,
      );
      expect(tamperedValid, isFalse);

      // Tampered signature
      final badSigHex =
          '${sigHex.substring(0, 126)}${sigHex.endsWith('00') ? '11' : '00'}';
      final badSigValid = await UpdateVerifier.verifyEd25519(
        message,
        signatureHex: badSigHex,
        publicKeyHex: pubHex,
      );
      expect(badSigValid, isFalse);

      // Malformed hex or wrong length
      expect(
        await UpdateVerifier.verifyEd25519(
          message,
          signatureHex: '1234',
          publicKeyHex: pubHex,
        ),
        isFalse,
      );
    });

    test('canonicalizeManifest sorts keys recursively and omits signature', () {
      final input = {
        'signature': 'should_be_omitted',
        'parserVersion': '1.0.0',
        'platforms': {
          'xhs': {'notice': 'msg', 'enabled': false},
          'instagram': {'enabled': true, 'notice': ''},
        },
        'minAppVersion': '1.0.0',
        'sha256': 'abc',
      };
      final canonical = UpdateVerifier.canonicalizeManifest(input);
      expect(canonical.contains('signature'), isFalse);
      // Ensure keys are sorted: minAppVersion before parserVersion before platforms before sha256
      expect(
        canonical,
        equals(
          '{"minAppVersion":"1.0.0","parserVersion":"1.0.0","platforms":{"instagram":{"enabled":true,"notice":""},"xhs":{"enabled":false,"notice":"msg"}},"sha256":"abc"}',
        ),
      );
    });

    test('compareVersions logic', () {
      expect(UpdateVerifier.compareVersions('1.0.0', '1.0.0'), equals(0));
      expect(UpdateVerifier.compareVersions('1.0.1', '1.0.0'), greaterThan(0));
      expect(UpdateVerifier.compareVersions('1.0.0', '1.0.1'), lessThan(0));
      expect(UpdateVerifier.compareVersions('1.1.0', '1.0.9'), greaterThan(0));
      expect(UpdateVerifier.compareVersions('0.9.0', '1.0.0'), lessThan(0));
      expect(UpdateVerifier.compareVersions('1.0.0+2', '1.0.0'), equals(0));
    });

    test('isAppVersionSupported comparison logic', () {
      expect(UpdateVerifier.isAppVersionSupported('1.0.0', '1.0.0'), isTrue);
      expect(UpdateVerifier.isAppVersionSupported('1.3.0', '1.0.0'), isTrue);
      expect(UpdateVerifier.isAppVersionSupported('1.0.0+2', '1.0.0'), isTrue);
      expect(UpdateVerifier.isAppVersionSupported('1.0.0', '1.0.1'), isFalse);
      expect(UpdateVerifier.isAppVersionSupported('1.0.0', '2.0.0'), isFalse);
      expect(UpdateVerifier.isAppVersionSupported('2.1.0', '2.0.5'), isTrue);
    });
  });

  group('ParserManager', () {
    late Directory tempDir;
    late SimpleKeyPair testKeyPair;
    late String testPubHex;
    final ed = Ed25519();

    Future<String> signManifest(Map<String, dynamic> manifest) async {
      final canonicalString = UpdateVerifier.canonicalizeManifest(manifest);
      final sig = await ed.sign(
        Uint8List.fromList(utf8.encode(canonicalString)),
        keyPair: testKeyPair,
      );
      return UpdateVerifier.bytesToHex(sig.bytes);
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tempDir = Directory.systemTemp.createTempSync('parser_test_');

      testKeyPair = await ed.newKeyPair();
      final pub = await testKeyPair.extractPublicKey();
      testPubHex = UpdateVerifier.bytesToHex(pub.bytes);

      // Key isolation assertion: test public key MUST NOT match production public key
      expect(testPubHex, isNot(equals(kDefaultParserPublicKeyHex)));
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('test key isolation: test key != kDefaultParserPublicKeyHex', () {
      expect(testPubHex, isNot(equals(kDefaultParserPublicKeyHex)));
    });

    test('fallback to builtin when cache does not exist', () async {
      final manager = ParserManager.instance;
      manager.configure(
        cacheDir: tempDir,
        publicKeyHex: testPubHex,
      );
      await manager.init();

      expect(manager.activeVersion, equals(ParserVersion.version));
      expect(manager.activeSource, equals(ParserSource.builtin));
      expect(manager.activeSourceLabel, equals('内置'));
      expect(manager.isPlatformEnabled('xhs'), isTrue);
    });

    test('successful update check downloads, verifies canonical manifest, and activates remote parser', () async {
      const remoteJs = 'console.log("remote parser v1.5.0");';
      final remoteBytes = Uint8List.fromList(utf8.encode(remoteJs));
      final shaHex = crypto.sha256.convert(remoteBytes).toString();

      final manifestMap = {
        'parserVersion': '1.5.0',
        'minAppVersion': '1.0.0',
        'sha256': shaHex,
        'platforms': {
          'xhs': {'enabled': false, 'notice': '小红书维护中'},
          'instagram': {'enabled': true, 'notice': ''},
        },
      };
      final sigHex = await signManifest(manifestMap);
      manifestMap['signature'] = sigHex;

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('manifest.json')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode(manifestMap)),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        } else if (request.url.path.endsWith('parser.js')) {
          return http.Response.bytes(remoteBytes, 200);
        }
        return http.Response('Not Found', 404);
      });

      final manager = ParserManager.instance;
      manager.configure(
        cacheDir: tempDir,
        publicKeyHex: testPubHex,
        client: mockClient,
        manifestUrl: 'https://example.com/manifest.json',
      );

      final updated = await manager.checkForUpdates(force: true);
      expect(updated, isTrue);
      expect(manager.activeVersion, equals('1.5.0'));
      expect(manager.activeSource, equals(ParserSource.remote));
      expect(manager.activeSourceLabel, equals('云端'));

      // Check remote platform switch
      expect(manager.isPlatformEnabled('xhs'), isFalse);
      expect(manager.getMaintenanceNotice('xhs'), equals('小红书维护中'));
      expect(manager.isPlatformEnabled('instagram'), isTrue);
      expect(manager.getMaintenanceNotice('instagram'), isNull);

      // Verify that cache files were written
      expect(File('${tempDir.path}/parser.js').existsSync(), isTrue);
      expect(File('${tempDir.path}/manifest.json').existsSync(), isTrue);
    });

    test('tampering with platform switch in manifest invalidates signature and rejects update', () async {
      const remoteJs = 'console.log("remote parser v1.5.0");';
      final remoteBytes = Uint8List.fromList(utf8.encode(remoteJs));
      final shaHex = crypto.sha256.convert(remoteBytes).toString();

      final manifestMap = {
        'parserVersion': '1.5.0',
        'minAppVersion': '1.0.0',
        'sha256': shaHex,
        'platforms': {
          'xhs': {'enabled': false, 'notice': '小红书维护中'},
        },
      };
      // Sign with xhs.enabled = false
      final sigHex = await signManifest(manifestMap);
      manifestMap['signature'] = sigHex;

      // Attacker tampers with platform switch to enabled: true without valid re-signing
      final tamperedManifest = {
        'parserVersion': '1.5.0',
        'minAppVersion': '1.0.0',
        'sha256': shaHex,
        'signature': sigHex,
        'platforms': {
          'xhs': {'enabled': true, 'notice': '小红书维护中'},
        },
      };

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('manifest.json')) {
          return http.Response.bytes(
            utf8.encode(jsonEncode(tamperedManifest)),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        } else if (request.url.path.endsWith('parser.js')) {
          return http.Response.bytes(remoteBytes, 200);
        }
        return http.Response('Not Found', 404);
      });

      final manager = ParserManager.instance;
      manager.configure(
        cacheDir: tempDir,
        publicKeyHex: testPubHex,
        client: mockClient,
        manifestUrl: 'https://example.com/manifest.json',
      );

      await manager.init();
      final updated = await manager.checkForUpdates(force: true);
      expect(updated, isFalse);
      expect(manager.activeVersion, equals(ParserVersion.version));
      expect(manager.activeSource, equals(ParserSource.builtin));
    });

    test('anti-downgrade: remote parserVersion <= builtin version is rejected', () async {
      const remoteJs = 'console.log("older or same parser");';
      final remoteBytes = Uint8List.fromList(utf8.encode(remoteJs));
      final shaHex = crypto.sha256.convert(remoteBytes).toString();

      // Test 1: parserVersion equal to builtin (e.g. 1.0.0 == 1.0.0)
      final equalManifest = {
        'parserVersion': ParserVersion.version,
        'minAppVersion': '1.0.0',
        'sha256': shaHex,
      };
      equalManifest['signature'] = await signManifest(equalManifest);

      // Test 2: parserVersion lower than builtin (e.g. 0.9.0 < 1.0.0)
      final lowerManifest = {
        'parserVersion': '0.9.0',
        'minAppVersion': '1.0.0',
        'sha256': shaHex,
      };
      lowerManifest['signature'] = await signManifest(lowerManifest);

      var currentManifest = equalManifest;

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(currentManifest), 200);
        } else if (request.url.path.endsWith('parser.js')) {
          return http.Response.bytes(remoteBytes, 200);
        }
        return http.Response('Not Found', 404);
      });

      final manager = ParserManager.instance;
      manager.configure(
        cacheDir: tempDir,
        publicKeyHex: testPubHex,
        client: mockClient,
        manifestUrl: 'https://example.com/manifest.json',
      );

      await manager.init();

      // Equal version rejected
      currentManifest = equalManifest;
      final updatedEqual = await manager.checkForUpdates(force: true);
      expect(updatedEqual, isFalse);
      expect(manager.activeVersion, equals(ParserVersion.version));
      expect(manager.activeSource, equals(ParserSource.builtin));

      // Lower version rejected
      currentManifest = lowerManifest;
      final updatedLower = await manager.checkForUpdates(force: true);
      expect(updatedLower, isFalse);
      expect(manager.activeVersion, equals(ParserVersion.version));
      expect(manager.activeSource, equals(ParserSource.builtin));
    });

    test('anti-downgrade: cached parser with version <= builtin is purged upon init', () async {
      const cachedJs = 'console.log("cached old version");';
      final cachedBytes = Uint8List.fromList(utf8.encode(cachedJs));
      final shaHex = crypto.sha256.convert(cachedBytes).toString();

      final cachedManifest = {
        'parserVersion': ParserVersion.version, // equal to builtin version
        'minAppVersion': '1.0.0',
        'sha256': shaHex,
      };
      cachedManifest['signature'] = await signManifest(cachedManifest);

      File('${tempDir.path}/parser.js').writeAsBytesSync(cachedBytes);
      File('${tempDir.path}/manifest.json').writeAsStringSync(jsonEncode(cachedManifest));

      final manager = ParserManager.instance;
      manager.configure(
        cacheDir: tempDir,
        publicKeyHex: testPubHex,
      );

      await manager.init();

      // Rejected because parserVersion <= builtin version
      expect(manager.activeVersion, equals(ParserVersion.version));
      expect(manager.activeSource, equals(ParserSource.builtin));
      // Purged
      expect(File('${tempDir.path}/parser.js').existsSync(), isFalse);
      expect(File('${tempDir.path}/manifest.json').existsSync(), isFalse);
    });

    test('update check with invalid signature is rejected and falls back', () async {
      const remoteJs = 'console.log("bad signature");';
      final remoteBytes = Uint8List.fromList(utf8.encode(remoteJs));
      final shaHex = crypto.sha256.convert(remoteBytes).toString();

      final manifestMap = {
        'parserVersion': '2.0.0',
        'minAppVersion': '1.0.0',
        'sha256': shaHex,
        'signature': '00' * 64, // invalid signature
        'platforms': {},
      };

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(manifestMap), 200);
        } else if (request.url.path.endsWith('parser.js')) {
          return http.Response.bytes(remoteBytes, 200);
        }
        return http.Response('Not Found', 404);
      });

      final manager = ParserManager.instance;
      manager.configure(
        cacheDir: tempDir,
        publicKeyHex: testPubHex,
        client: mockClient,
        manifestUrl: 'https://example.com/manifest.json',
      );

      await manager.init(); // builtin
      final updated = await manager.checkForUpdates(force: true);
      expect(updated, isFalse);
      expect(manager.activeVersion, equals(ParserVersion.version));
      expect(manager.activeSource, equals(ParserSource.builtin));
    });

    test('update check with SHA256 mismatch is rejected and falls back', () async {
      const remoteJs = 'console.log("tampered bundle");';
      final remoteBytes = Uint8List.fromList(utf8.encode(remoteJs));

      final manifestMap = {
        'parserVersion': '2.0.0',
        'minAppVersion': '1.0.0',
        'sha256': '11' * 32, // mismatched sha256
        'platforms': {},
      };
      manifestMap['signature'] = await signManifest(manifestMap);

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(manifestMap), 200);
        } else if (request.url.path.endsWith('parser.js')) {
          return http.Response.bytes(remoteBytes, 200);
        }
        return http.Response('Not Found', 404);
      });

      final manager = ParserManager.instance;
      manager.configure(
        cacheDir: tempDir,
        publicKeyHex: testPubHex,
        client: mockClient,
        manifestUrl: 'https://example.com/manifest.json',
      );

      await manager.init();
      final updated = await manager.checkForUpdates(force: true);
      expect(updated, isFalse);
      expect(manager.activeVersion, equals(ParserVersion.version));
      expect(manager.activeSource, equals(ParserSource.builtin));
    });

    test('update check with minAppVersion > current app version is rejected', () async {
      const remoteJs = 'console.log("future app required");';
      final remoteBytes = Uint8List.fromList(utf8.encode(remoteJs));
      final shaHex = crypto.sha256.convert(remoteBytes).toString();

      final manifestMap = {
        'parserVersion': '3.0.0',
        'minAppVersion': '99.0.0', // Too high
        'sha256': shaHex,
        'platforms': {},
      };
      manifestMap['signature'] = await signManifest(manifestMap);

      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(manifestMap), 200);
        }
        return http.Response('Not Found', 404);
      });

      final manager = ParserManager.instance;
      manager.configure(
        cacheDir: tempDir,
        publicKeyHex: testPubHex,
        client: mockClient,
        manifestUrl: 'https://example.com/manifest.json',
      );

      await manager.init();
      final updated = await manager.checkForUpdates(force: true);
      expect(updated, isFalse);
      expect(manager.activeVersion, equals(ParserVersion.version));
      expect(manager.activeSource, equals(ParserSource.builtin));
    });

    test('corrupted cache on disk is deleted and falls back to builtin upon init', () async {
      // Write corrupted files to cache
      File('${tempDir.path}/parser.js').writeAsStringSync('corrupted file');
      File('${tempDir.path}/manifest.json').writeAsStringSync(jsonEncode({
        'parserVersion': '9.9.9',
        'minAppVersion': '1.0.0',
        'sha256': 'wrong_sha256',
        'signature': 'wrong_sig',
      }));

      final manager = ParserManager.instance;
      manager.configure(
        cacheDir: tempDir,
        publicKeyHex: testPubHex,
      );

      await manager.init();
      expect(manager.activeVersion, equals(ParserVersion.version));
      expect(manager.activeSource, equals(ParserSource.builtin));
      // Broken cache should have been removed
      expect(File('${tempDir.path}/parser.js').existsSync(), isFalse);
    });
  });
}
