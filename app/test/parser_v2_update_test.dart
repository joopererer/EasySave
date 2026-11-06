import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:easysave/generated/parser_version.dart';
import 'package:easysave/services/update_service.dart';
import 'package:easysave/services/signed_parser_manifest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
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
  var requests = 0;
  const script = '// signed v2 parser';
  final scriptBytes = utf8.encode(script);
  final repo = Directory.current.path.endsWith('app') ? '..' : '.';
  Map<String, dynamic> payload(int version) {
    final example =
        jsonDecode(
              File('assets/parser/builtin-manifest.json').readAsStringSync(),
            )
            as Map;
    final data = Map<String, dynamic>.from(example);
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

  Future<List<int>> sign(
    Map<String, dynamic> value, {
    bool pretty = false,
  }) async {
    final text = pretty
        ? const JsonEncoder.withIndent('  ').convert(value)
        : jsonEncode(value);
    final signature = await ed.sign(utf8.encode(text), keyPair: key);
    return utf8.encode(
      jsonEncode({
        'schemaVersion': 2,
        'payload': text,
        'signature': UpdateVerifier.bytesToHex(signature.bytes),
      }),
    );
  }

  Future<void> prepare({bool foreground = true}) async {
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
          return http.Response.bytes(
            remote,
            200,
            headers: {'etag': '"test-version"'},
          );
        }
        return http.Response.bytes(scriptBytes, 200);
      }),
    );
    await manager.init(canUpdate: foreground);
  }

  Map<String, dynamic> state() =>
      jsonDecode(File('${directory.path}/state.json').readAsStringSync())
          as Map<String, dynamic>;
  File releaseFile(String reference, String name) =>
      File('${directory.path}/releases/$reference/$name');
  Future<void> install(int version) async {
    remote = await sign(payload(version));
    expect(await manager.checkForUpdates(force: true), isTrue);
  }

  test(
    'signed bundle missing App navigation configuration never activates',
    () async {
      final lines = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) lines.add(message);
      };
      addTearDown(() => debugPrint = previous);
      final value = payload(50);
      final xhs = (value['sites'] as List).cast<Map>().firstWhere(
        (s) => s['id'] == 'xhs',
      );
      (xhs['shortLinks'] as List).cast<Map>().first.remove('stopAtPost');
      remote = await sign(value);
      await prepare();
      expect(await manager.checkForUpdates(force: true), isFalse);
      expect(manager.activeSource, ParserSource.builtin);
      expect(manager.activeVersion, ParserVersion.version);
      expect(await manager.getActiveScript(), contains('EasySaveParser'));
      expect(
        lines.join('\n'),
        contains(
          '[ParserUpdate] event=rejected reason=sites.xhs.shortLinks.stopAtPost',
        ),
      );
    },
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    directory = Directory.systemTemp.createTempSync('easysave_v2_');
    key = await ed.newKeyPair();
    publicKey = UpdateVerifier.bytesToHex((await key.extractPublicKey()).bytes);
    expect(publicKey, isNot(kDefaultParserPublicKeyHex));
    requests = 0;
    remote = await sign(payload(1));
    await prepare();
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('builtin mode removes stale empty recognition projection', () async {
    final view = File('${directory.path}/link-recognition.json');
    view.writeAsStringSync('{"sites":[]}');
    await manager.getActiveScript();
    expect(view.existsSync(), isFalse);
  });

  test(
    'valid original payload bytes and parser are cached unchanged and reverified',
    () async {
      remote = await sign(payload(1), pretty: true);
      expect(await manager.checkForUpdates(force: true), isTrue);
      expect(manager.activeVersion, '1.5.0');
      final cached = releaseFile(state()['current'] as String, 'manifest.json');
      expect(cached.readAsBytesSync(), remote);
      expect(await manager.getActiveScript(), script);
      final view =
          jsonDecode(
                File(
                  '${directory.path}/link-recognition.json',
                ).readAsStringSync(),
              )
              as Map;
      expect((view['sites'] as List).length, 4); // douyin remains disabled.
      expect(((view['sites'] as List).first as Map).keys.toSet(), {
        'id',
        'routes',
      });
    },
  );
  test(
    'tampered payload, wrong signature and unsigned candidate never activate',
    () async {
      final original = List<int>.from(remote);
      final changed = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
      changed['payload'] = '${changed['payload'] as String} ';
      remote = utf8.encode(jsonEncode(changed));
      expect(await manager.checkForUpdates(force: true), isFalse);
      changed['payload'] =
          (jsonDecode(utf8.decode(original)) as Map)['payload'];
      changed['signature'] = List.filled(128, '0').join();
      remote = utf8.encode(jsonEncode(changed));
      expect(await manager.checkForUpdates(force: true), isFalse);
      changed.remove('signature');
      remote = utf8.encode(jsonEncode(changed));
      expect(await manager.checkForUpdates(force: true), isFalse);
      expect(File('${directory.path}/state.json').existsSync(), isFalse);
      expect(manager.activeSource, ParserSource.builtin);
      expect(requests, 3); // Signature failures must not download a parser.
    },
  );
  test('hash mismatch keeps current bundle and watermark', () async {
    await install(3);
    final before = File('${directory.path}/state.json').readAsStringSync();
    final broken = payload(4)..['sha256'] = List.filled(64, '0').join();
    remote = await sign(broken);
    expect(await manager.checkForUpdates(force: true), isFalse);
    expect(File('${directory.path}/state.json').readAsStringSync(), before);
    expect(await manager.getActiveScript(), script);
  });
  test(
    'new remote watermark rejects older remote above builtin and same-sequence equivocation',
    () async {
      await install(20);
      remote = await sign(
        payload(19),
      ); // Same parserVersion, older release sequence.
      final before = requests;
      expect(await manager.checkForUpdates(force: true), isFalse);
      expect(requests, before + 1);
      final altered = payload(20)..['minAppVersion'] = '1.1.0';
      remote = await sign(altered);
      expect(await manager.checkForUpdates(force: true), isFalse);
      expect(state()['highestAcceptedManifestVersion'], 20);
      expect(await manager.getActiveScript(), script);
      await prepare(); // Restart cannot forget the accepted watermark.
      remote = await sign(payload(19));
      expect(await manager.checkForUpdates(force: true), isFalse);
    },
  );
  test(
    'same sequence same payload is reusable without a second download',
    () async {
      await install(2);
      final before = requests;
      expect(await manager.checkForUpdates(force: true), isFalse);
      expect(requests, before + 1);
    },
  );
  test('manifest-only update may retain built-in parser version', () async {
    final data = payload(1);
    data['parserVersion'] = ParserVersion.version;
    data['parserUrl'] =
        'https://github.com/joopererer/EasySave/releases/download/parser-v${ParserVersion.version}/parser.js';
    remote = await sign(data);
    expect(await manager.checkForUpdates(force: true), isTrue);
    expect(manager.activeSource, ParserSource.remote);
  });
  test(
    'too-high package minAppVersion keeps current version and watermark',
    () async {
      await install(1);
      final tooNew = payload(999)..['minAppVersion'] = '99.0.0';
      remote = await sign(tooNew);
      expect(await manager.checkForUpdates(force: true), isFalse);
      expect(state()['highestAcceptedManifestVersion'], 1);
      expect(manager.activeSource, ParserSource.remote);
    },
  );
  test(
    'too-high site version is excluded, while other sites remain active',
    () async {
      final data = payload(1);
      ((data['sites'] as List).first as Map)['minAppVersion'] = '99.0.0';
      remote = await sign(data);
      expect(await manager.checkForUpdates(force: true), isTrue);
      expect(manager.isPlatformEnabled('xhs'), isFalse);
      final view =
          jsonDecode(
                File(
                  '${directory.path}/link-recognition.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(
        (view['sites'] as List).any((s) => (s as Map)['id'] == 'xhs'),
        isFalse,
      );
      expect(
        (view['sites'] as List).any((s) => (s as Map)['id'] == 'instagram'),
        isTrue,
      );
    },
  );
  test(
    'cache parser corruption falls back to previous verified version without reducing watermark',
    () async {
      await install(1);
      await install(2);
      releaseFile(
        state()['current'] as String,
        'parser.js',
      ).writeAsStringSync('corrupt');
      await prepare(foreground: false);
      expect(manager.activeSource, ParserSource.remote);
      expect(manager.activeSignedManifest!.version, 1);
      expect(state()['highestAcceptedManifestVersion'], 2);
      expect(await manager.getActiveScript(), script);
      remote = await sign(payload(1));
      await prepare();
      expect(await manager.checkForUpdates(force: true), isFalse);
    },
  );
  test(
    'manifest corruption is detected on every use; two broken versions fall back to builtin',
    () async {
      await install(1);
      await install(2);
      releaseFile(
        state()['current'] as String,
        'manifest.json',
      ).writeAsStringSync('{}');
      expect(await manager.getActiveScript(), script);
      expect(manager.activeSignedManifest!.version, 1);
      releaseFile(
        state()['previous'] as String,
        'parser.js',
      ).writeAsStringSync('corrupt');
      expect(await manager.getActiveScript(), isNot(script));
      expect(manager.activeSource, ParserSource.builtin);
      expect(state()['highestAcceptedManifestVersion'], 2);
    },
  );
  test(
    'failed activation commit cannot advance watermark or replace current',
    () async {
      await install(1);
      final before = File('${directory.path}/state.json').readAsStringSync();
      Directory('${directory.path}/state.json.tmp').createSync();
      remote = await sign(payload(2));
      expect(await manager.checkForUpdates(force: true), isFalse);
      expect(File('${directory.path}/state.json').readAsStringSync(), before);
      expect(await manager.getActiveScript(), script);
    },
  );
  test(
    'background engine neither fetches nor writes projection; fresh directory remains absent',
    () async {
      await install(1);
      final view = File('${directory.path}/link-recognition.json');
      view.writeAsStringSync('recognition marker');
      await prepare(foreground: false);
      final before = requests;
      expect(await manager.checkForUpdates(force: true), isFalse);
      expect(await manager.getActiveScript(), script);
      expect(requests, before);
      expect(view.readAsStringSync(), 'recognition marker');
      manager.configure(cacheDir: Directory('${directory.path}/not-created'));
      await manager.init();
      expect(Directory('${directory.path}/not-created').existsSync(), isFalse);
    },
  );
  test(
    'automatic checks are daily, use ETag, and force bypasses both',
    () async {
      await install(1);
      final before = requests;
      expect(await manager.checkForUpdates(), isFalse);
      expect(requests, before);
      await prefs.setInt(kPrefKeyLastUpdateCheckMs, 0);
      manager.configure(
        client: MockClient((request) async {
          expect(request.headers['If-None-Match'], '"test-version"');
          return http.Response('', 304);
        }),
      );
      expect(await manager.checkForUpdates(), isFalse);
    },
  );
  test(
    'invalid sites or unsafe headers reject the entire signed candidate',
    () async {
      for (final mode in ['duplicate', 'cookie', 'domain', 'path', 'abi']) {
        final data = payload(1);
        final sites = data['sites'] as List;
        if (mode == 'duplicate') sites.add(sites.first);
        if (mode == 'cookie') {
          ((sites.first as Map)['download'] as Map)['headers'] = {
            'Cookie': 'forbidden',
          };
        }
        if (mode == 'domain') {
          (((sites.first as Map)['match'] as Map)['routes'] as List)
                  .first['hosts'][0]['domain'] =
              'example.com.evil/';
        }
        if (mode == 'path') {
          (((sites.first as Map)['match'] as Map)['routes'] as List)
              .first['pathPatterns'] = [
            '.*',
          ];
        }
        if (mode == 'abi') data['parserAbi'] = 99;
        remote = await sign(data);
        expect(
          await manager.checkForUpdates(force: true),
          isFalse,
          reason: mode,
        );
      }
      expect(File('${directory.path}/state.json').existsSync(), isFalse);
    },
  );
  test(
    'malformed state recovers highest verified local watermark and allows newer updates',
    () async {
      await install(10);
      File('${directory.path}/state.json').writeAsStringSync('{}');
      await prepare();
      expect(manager.activeSource, ParserSource.remote);
      expect(state()['highestAcceptedManifestVersion'], 10);
      remote = await sign(payload(1));
      expect(await manager.checkForUpdates(force: true), isFalse);
      remote = await sign(payload(11));
      expect(await manager.checkForUpdates(force: true), isTrue);
      expect(state()['highestAcceptedManifestVersion'], 11);
    },
  );

  test(
    'recovery ignores corrupt cache but includes a verified built-in floor',
    () async {
      await install(5);
      await install(6);
      releaseFile(
        state()['current'] as String,
        'parser.js',
      ).writeAsStringSync('bad');
      File('${directory.path}/state.json').writeAsStringSync('invalid');
      await prepare();
      final builtinVersion = (jsonDecode(File('assets/parser/builtin-manifest.json')
          .readAsStringSync()) as Map)['manifestVersion'] as int;
      expect(state()['highestAcceptedManifestVersion'], builtinVersion > 5 ? builtinVersion : 5);
      remote = await sign(payload(4));
      expect(await manager.checkForUpdates(force: true), isFalse);
      // Remove all cached candidates: the APK-bundled manifest still supplies a floor.
      Directory('${directory.path}/releases').deleteSync(recursive: true);
      File('${directory.path}/state.json').writeAsStringSync('{}');
      await prepare();
      expect(state()['current'], 'builtin');
      expect(
        state()['highestAcceptedManifestVersion'],
        greaterThanOrEqualTo(1),
      );
      remote = await sign(payload(7));
      expect(await manager.checkForUpdates(force: true), isTrue);
    },
  );

  test(
    'parser follows HTTPS Release redirect and hashes the final bytes',
    () async {
      manager.configure(
        client: MockClient((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            return http.Response.bytes(remote, 200);
          }
          expect(request.followRedirects, isFalse);
          if (request.url.host == 'github.com') {
            return http.Response(
              '',
              302,
              headers: {
                'location': 'https://objects.githubusercontent.com/parser.js',
              },
            );
          }
          return http.Response.bytes(scriptBytes, 200);
        }),
      );
      expect(await manager.checkForUpdates(force: true), isTrue);
      expect(await manager.getActiveScript(), script);
    },
  );

  test(
    'parser rejects HTTP downgrade, more than five redirects, and redirected wrong bytes',
    () async {
      for (final mode in ['http', 'loop', 'hash']) {
        var redirects = 0;
        manager.configure(
          client: MockClient((request) async {
            if (request.url.path.endsWith('manifest.json')) {
              return http.Response.bytes(remote, 200);
            }
            if (mode == 'loop' || redirects++ == 0) {
              return http.Response(
                '',
                302,
                headers: {
                  'location': mode == 'http'
                      ? 'http://objects.githubusercontent.com/parser.js'
                      : 'https://objects.githubusercontent.com/parser.js',
                },
              );
            }
            return http.Response('incorrect bytes', 200);
          }),
        );
        expect(
          await manager.checkForUpdates(force: true),
          isFalse,
          reason: mode,
        );
        expect(File('${directory.path}/state.json').existsSync(), isFalse);
      }
    },
  );

  test('parser permits exactly five HTTPS redirects', () async {
    var redirects = 0;
    manager.configure(
      client: MockClient((request) async {
        if (request.url.path.endsWith('manifest.json')) {
          return http.Response.bytes(remote, 200);
        }
        if (redirects++ < 5) {
          return http.Response(
            '',
            307,
            headers: {
              'location': 'https://objects.githubusercontent.com/parser.js',
            },
          );
        }
        return http.Response.bytes(scriptBytes, 200);
      }),
    );
    expect(await manager.checkForUpdates(force: true), isTrue);
  });
  test(
    'damaged current cache does not send ETag and can be repaired at the same watermark',
    () async {
      await install(1);
      await install(2);
      releaseFile(
        state()['current'] as String,
        'parser.js',
      ).writeAsStringSync('corrupt');
      await prefs.setInt(kPrefKeyLastUpdateCheckMs, 0);
      final signed = await sign(payload(2));
      manager.configure(
        client: MockClient((request) async {
          if (request.url.path.endsWith('manifest.json')) {
            expect(request.headers.containsKey('If-None-Match'), isFalse);
            return http.Response.bytes(signed, 200);
          }
          return http.Response.bytes(scriptBytes, 200);
        }),
      );
      expect(await manager.checkForUpdates(), isTrue);
      expect(state()['highestAcceptedManifestVersion'], 2);
      expect(manager.activeSignedManifest!.version, 2);
    },
  );

  test('concurrent foreground checks share one activation', () async {
    final results = await Future.wait([
      manager.checkForUpdates(force: true),
      manager.checkForUpdates(force: true),
    ]);
    expect(results, [true, true]);
    expect(requests, 2);
    expect(state()['highestAcceptedManifestVersion'], 1);
  });

  test('legacy platform getters remain available during 2a', () async {
    final data = payload(1);
    data['platforms'] = {
      'xhs': {'enabled': false, 'notice': '维护中'},
      'x': {
        'enabled': true,
        'notice': '',
        'endpoint': 'https://cdn.syndication.twimg.com/tweet-result?id={id}',
      },
    };
    data['headers'] = {
      'x': {'User-Agent': 'test agent'},
    };
    remote = await sign(data);
    expect(await manager.checkForUpdates(force: true), isTrue);
    expect(manager.isPlatformEnabled('xhs'), isFalse);
    expect(manager.getMaintenanceNotice('xhs'), '维护中');
    expect(manager.getPlatformHeaders('x'), {'User-Agent': 'test agent'});
    expect(manager.getPlatformEndpoint('x'), contains('tweet-result'));
  });

  test('schema asset matches repository schema', () {
    expect(
      File('assets/parser/sites-manifest.schema.json').readAsBytesSync(),
      File('$repo/spec/sites-manifest.schema.json').readAsBytesSync(),
    );
  });

  test(
    'Node-generated UTF-8 signature vector is accepted without normalization',
    () async {
      final vector =
          jsonDecode(
                File(
                  '$repo/spec/test-vectors/parser-manifest-v2.json',
                ).readAsStringSync(),
              )
              as Map;
      final schema =
          jsonDecode(
                File(
                  '$repo/spec/sites-manifest.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final manifest = await SignedParserManifest.verify(
        utf8.encode(jsonEncode(vector['envelope'])),
        publicKeyHex: vector['publicKeyHex'] as String,
        schema: schema,
      );
      expect(
        manifest.payloadHash,
        crypto.sha256
            .convert(
              utf8.encode((vector['envelope'] as Map)['payload'] as String),
            )
            .toString(),
      );
    },
  );
  test('strict version and schema validators reject malformed fields', () {
    expect(
      () => compareAppVersions('1.10.bad', '1.0.0'),
      throwsFormatException,
    );
    expect(compareAppVersions('1.10.0+10', '1.9.0'), greaterThan(0));
    expect(
      () => validateManifestSchema(null, {'unknown': true}, {}),
      throwsFormatException,
    );
  });
}
