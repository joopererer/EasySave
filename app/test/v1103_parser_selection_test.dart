// v1.10.3: startup must choose between the APK-bundled parser manifest and the
// stored (downloaded) one by `manifestVersion`. Before this, a device that ever
// downloaded a parser stayed on it forever: the bundled manifest was only
// consulted when nothing was stored.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:easysave/generated/parser_version.dart';
import 'package:easysave/services/parser_release_store.dart';
import 'package:easysave/services/signed_parser_manifest.dart';
import 'package:easysave/services/update_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ed = Ed25519();
  late Directory directory;
  late SimpleKeyPair key;
  late String publicKey;
  late ParserManager manager;
  late SharedPreferences prefs;
  late List<int> remote;
  late List<int> parserBody;
  late List<String> lines;
  var requests = 0;

  const script = '// signed v2 parser';
  final scriptBytes = utf8.encode(script);
  final builtinText =
      File('assets/parser/builtin-manifest.json').readAsStringSync();
  final builtinPayload =
      jsonDecode(builtinText) as Map<String, dynamic>;
  final builtinVersion = builtinPayload['manifestVersion'] as int;
  final builtinParser = File('assets/parser/parser.js').readAsBytesSync();
  final builtinHash = crypto.sha256.convert(utf8.encode(builtinText)).toString();
  final schema =
      jsonDecode(
            File('assets/parser/sites-manifest.schema.json').readAsStringSync(),
          )
          as Map<String, dynamic>;

  /// A signed release that is *not* the bundled one, so its payload hash and
  /// parser hash differ from the APK's copy at the same sequence.
  Map<String, dynamic> payload(int version) {
    final data = Map<String, dynamic>.from(builtinPayload);
    data['manifestVersion'] = version;
    data['parserVersion'] = '1.5.0';
    data['parserUrl'] =
        'https://github.com/joopererer/EasySave/releases/download/parser-v1.5.0/parser.js';
    data['minAppVersion'] = '1.0.0';
    data['sha256'] = crypto.sha256.convert(scriptBytes).toString();
    for (final site in (data['sites'] as List).cast<Map>()) {
      site['minAppVersion'] = '1.0.0';
      site['requiredCapabilities'] = [];
      if (site['id'] == 'xhs') {
        for (final rule in (site['shortLinks'] as List).cast<Map>()) {
          rule['stopAtPost'] = true;
        }
      }
    }
    return data;
  }

  Future<List<int>> envelope(String text) async {
    final signature = await ed.sign(utf8.encode(text), keyPair: key);
    return utf8.encode(
      jsonEncode({
        'schemaVersion': 2,
        'payload': text,
        'signature': UpdateVerifier.bytesToHex(signature.bytes),
      }),
    );
  }

  Future<List<int>> sign(Map<String, dynamic> value) => envelope(jsonEncode(value));

  Future<void> prepare() async {
    lines = [];
    manager = ParserManager.forTesting();
    manager.configure(
      cacheDir: directory,
      publicKeyHex: publicKey,
      appVersion: '1.10.0',
      prefs: prefs,
      manifestUrl: 'https://example.com/spec/v2/manifest.json',
      client: MockClient((request) async {
        requests++;
        if (request.url.path.endsWith('manifest.json')) {
          return http.Response.bytes(remote, 200);
        }
        return http.Response.bytes(parserBody, 200);
      }),
    );
    await manager.init(canUpdate: true);
  }

  Map<String, dynamic> state() =>
      jsonDecode(File('${directory.path}/state.json').readAsStringSync())
          as Map<String, dynamic>;
  String rawState() =>
      File('${directory.path}/state.json').readAsStringSync();
  String log() => lines.join('\n');

  /// Write a release directory plus the state that selects it, exactly as a
  /// previous install would have left them.
  Future<void> storeRelease(
    List<int> manifestBytes,
    List<int> parser, {
    required int highest,
    required String contentHash,
    bool current = true,
  }) async {
    final reference = '$highest-$contentHash-1000';
    final releases = Directory('${directory.path}/releases/$reference')
      ..createSync(recursive: true);
    File('${releases.path}/manifest.json').writeAsBytesSync(manifestBytes);
    File('${releases.path}/parser.js').writeAsBytesSync(parser);
    File('${directory.path}/state.json').writeAsStringSync(
      jsonEncode({
        'current': current ? reference : 'builtin',
        'previous': null,
        'highestAcceptedManifestVersion': highest,
        'contentHash': contentHash,
      }),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    directory = Directory.systemTemp.createTempSync('easysave_select_');
    key = await ed.newKeyPair();
    publicKey = UpdateVerifier.bytesToHex((await key.extractPublicKey()).bytes);
    requests = 0;
    parserBody = scriptBytes;
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('the APK-bundled manifest wins when its sequence is higher', () async {
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    await prepare();
    // A downloaded release one sequence below the APK's own one.
    remote = await sign(payload(builtinVersion - 1));
    expect(await manager.checkForUpdates(force: true), isTrue);
    expect(state()['current'], isNot('builtin'));
    expect(manager.activeSource, ParserSource.remote);

    await prepare(); // restart
    expect(manager.activeSource, ParserSource.builtin);
    expect(manager.activeVersion, ParserVersion.version);
    expect(manager.activeSignedManifest, isNull);
    expect(state()['current'], 'builtin');
    expect(state()['highestAcceptedManifestVersion'], builtinVersion);
    expect(state()['contentHash'], builtinHash);
    expect(
      log(),
      contains(
        'event=select builtin=${ParserVersion.version}/$builtinVersion '
        'stored=1.5.0/${builtinVersion - 1} chosen=builtin '
        'reason=builtin_higher',
      ),
    );
    expect(await manager.getActiveScript(), contains('EasySaveParser'));
  });

  test('a downloaded release above the APK sequence still runs', () async {
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() => debugPrint = previous);
    await prepare();
    remote = await sign(payload(builtinVersion + 1));
    expect(await manager.checkForUpdates(force: true), isTrue);

    await prepare(); // restart
    expect(manager.activeSource, ParserSource.remote);
    expect(manager.activeSignedManifest!.version, builtinVersion + 1);
    expect(state()['current'], isNot('builtin'));
    expect(state()['highestAcceptedManifestVersion'], builtinVersion + 1);
    expect(
      log(),
      contains('chosen=stored reason=stored_higher'),
    );
    expect(await manager.getActiveScript(), script);
  });

  test(
    'same sequence and same content keeps the stored release untouched',
    () async {
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = previous);
      // The device already runs exactly what this APK bundles.
      await storeRelease(
        await envelope(builtinText),
        builtinParser,
        highest: builtinVersion,
        contentHash: builtinHash,
      );
      final before = rawState();
      await prepare();
      expect(manager.activeSource, ParserSource.remote);
      expect(manager.activeSignedManifest!.version, builtinVersion);
      expect(rawState(), before);
      expect(
        log(),
        contains(
          'chosen=stored reason=same_sequence_same_content',
        ),
      );
    },
  );

  test(
    'same sequence with different content keeps the current source and logs it',
    () async {
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = previous);
      final different = await sign(payload(builtinVersion));
      final differentHash = crypto.sha256
          .convert(utf8.encode(jsonEncode(payload(builtinVersion))))
          .toString();
      await storeRelease(
        different,
        scriptBytes,
        highest: builtinVersion,
        contentHash: differentHash,
      );
      final before = rawState();
      await prepare();
      expect(manager.activeSource, ParserSource.remote);
      expect(manager.activeSignedManifest!.version, builtinVersion);
      expect(rawState(), before);
      expect(await manager.getActiveScript(), script);
      expect(
        log(),
        contains('chosen=stored reason=same_sequence_different_content'),
      );
    },
  );

  test(
    'an online release identical to the active builtin is a match, not equivocation',
    () async {
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = previous);
      await prepare();
      remote = await sign(payload(builtinVersion - 1));
      expect(await manager.checkForUpdates(force: true), isTrue);
      await prepare(); // the builtin takes over and lifts the watermark
      expect(manager.activeSource, ParserSource.builtin);

      // The channel still serves the same sequence with the same signed content.
      remote = await envelope(builtinText);
      final before = requests;
      expect(await manager.checkForUpdates(force: true), isFalse);
      expect(requests, before + 1); // Manifest only: no parser download.
      expect(
        log(),
        contains('result=same'),
        reason: log(),
      );
      expect(log(), contains('remoteManifest=$builtinVersion'), reason: log());
      expect(log(), contains('reason=same_as_builtin'), reason: log());
      expect(state()['current'], 'builtin');
      expect(state()['highestAcceptedManifestVersion'], builtinVersion);
      expect(manager.activeSource, ParserSource.builtin);
    },
  );

  test('the bundled manifest is hash-checked like a downloaded one', () async {
    expect(
      () => SignedParserManifest.fromBuiltin(
        builtinText,
        utf8.encode('// not the bundled parser'),
        schema,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'builtin_parser_hash',
        ),
      ),
    );
    final manifest = SignedParserManifest.fromBuiltin(
      builtinText,
      builtinParser,
      schema,
    );
    expect(manifest.version, builtinVersion);
    expect(manifest.payloadHash, builtinHash);
    // Same text, same hash: the signed envelope for this content is the same
    // release as the bundled one, which is what `same_as_builtin` relies on.
    final signed = await SignedParserManifest.verify(
      await envelope(builtinText),
      publicKeyHex: publicKey,
      schema: schema,
    );
    expect(signed.payloadHash, manifest.payloadHash);
    expect(signed.version, manifest.version);
  });

  test('selection reports both sides and the reason in one line', () async {
    await prepare();
    final selection = await ParserReleaseStore(
      directory,
      publicKey,
      '1.10.0',
      schema,
      builtinManifest: SignedParserManifest.fromBuiltin(
        builtinText,
        builtinParser,
        schema,
      ),
    ).select();
    expect(selection.chosen, ParserSelectionChoice.builtin);
    expect(selection.reason, anyOf('builtin_only', 'stored_none'));
    expect(selection.builtin!.version, builtinVersion);
    expect(selection.stored, isNull);
  });
}
