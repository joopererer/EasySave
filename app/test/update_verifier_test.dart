import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:easysave/services/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test(
      'verifyEd25519 verifies valid and rejects tampered signatures',
      () async {
        final ed = Ed25519();
        final keyPair = await ed.newKeyPair();
        final pubKey = await keyPair.extractPublicKey();
        final pubHex = UpdateVerifier.bytesToHex(pubKey.bytes);

        final message = Uint8List.fromList(
          utf8.encode('parser bundle content'),
        );
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
        final tamperedMessage = Uint8List.fromList(
          utf8.encode('tampered parser'),
        );
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
      },
    );

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
}
