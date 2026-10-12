import 'package:easysave/core/instagram.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shortcodeToMediaId', () {
    test('converts known shortcodes with BigInt precision', () {
      expect(shortcodeToMediaId('Ddl1WWnGyCN'), equals('3991831277305798797'));
      expect(shortcodeToMediaId('DeTOj5WRMIh'), equals('4004608533072232993'));
    });

    test('rejects empty input and characters outside the alphabet', () {
      expect(shortcodeToMediaId(''), isNull);
      expect(shortcodeToMediaId('abc\$defghij'), isNull);
      expect(shortcodeToMediaId('ab cd'), isNull);
    });

    test('round-trips single characters against the base64url alphabet', () {
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
      for (var i = 0; i < alphabet.length; i++) {
        expect(shortcodeToMediaId(alphabet[i]), equals('$i'));
      }
    });
  });
}
