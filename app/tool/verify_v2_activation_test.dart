import 'dart:convert';
import 'dart:io';
import 'package:easysave/services/parser_release_store.dart';
import 'package:easysave/services/signed_parser_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'actual v2 Release activates over build 24 builtin and survives store restart',
    () async {
      const key =
          'ca4f1c302d00220e32178d2e9b47fd589dffc38e8c9711fe93327a44aa199ded';
      final schema =
          jsonDecode(File('build/v110b/apk-schema.json').readAsStringSync())
              as Map<String, dynamic>;
      final builtin = SignedParserManifest.fromBuiltin(
        File('build/v110b/apk-builtin-manifest.json').readAsStringSync(),
        File('build/v110b/apk-parser.js').readAsBytesSync(),
        schema,
      );
      expect(builtin.version, 1);
      expect(builtin.parserVersion, '1.4.5');
      final manifest = await SignedParserManifest.verify(
        File('build/v110b/release147/manifest.json').readAsBytesSync(),
        publicKeyHex: key,
        schema: schema,
      );
      expect(manifest.version, 3);
      expect(manifest.parserVersion, '1.4.7');
      final bytes = File('build/v110b/release147/parser.js').readAsBytesSync();
      final directory = Directory(
        'build/v110b',
      ).createTempSync('live-activation-');
      ParserReleaseStore open() => ParserReleaseStore(
        directory,
        key,
        '1.10.0',
        schema,
        builtinManifest: builtin,
      );
      final first = open();
      await first.recoverStateIfNeeded();
      expect(first.readState(), isNull);
      expect(
        await first.load(),
        isNull,
      ); // Empty cache selects the separately verified builtin.
      final active = await first.activate(manifest, bytes);
      expect(active.manifest.parserVersion, '1.4.7');
      final restarted = open();
      await restarted.recoverStateIfNeeded();
      final loaded = await restarted.load();
      expect(loaded, isNotNull);
      expect(loaded!.manifest.parserVersion, '1.4.7');
      expect(loaded.reference, active.reference);
      expect(utf8.encode(loaded.script), bytes);
      expect(restarted.readState()!['highestAcceptedManifestVersion'], 3);
      print(
        'PASS: actual Release + build24 builtin schema; activation=1.4.7, reload=1.4.7, watermark=3',
      );
    },
  );
}
