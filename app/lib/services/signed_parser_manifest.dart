import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

/// Ed25519 signs the decoded payload string's UTF-8 bytes, never re-encoded JSON.
class SignedParserManifest {
  SignedParserManifest._(this.payload, this.rawBytes, this.payloadHash);
  final Map<String, dynamic> payload;
  final Uint8List rawBytes;
  final String payloadHash;
  int get version => payload['manifestVersion'] as int;
  String get parserVersion => payload['parserVersion'] as String;
  String get parserUrl => payload['parserUrl'] as String;
  String get sha256 => payload['sha256'] as String;
  List<Map<String, dynamic>> get sites =>
      (payload['sites'] as List).cast<Map<String, dynamic>>();

  /// APK-bundled metadata is trusted by the App signature, never accepted from
  /// network/cache as an unsigned envelope. Its parser hash is still checked.
  static SignedParserManifest fromBuiltin(
    String text,
    List<int> parser,
    Map<String, dynamic> schema,
  ) {
    final payload = jsonDecode(text) as Map<String, dynamic>;
    validateManifestSchema(
      payload,
      (schema[r'$defs'] as Map)['payload'] as Map,
      schema,
    );
    _validateSemantics(payload);
    if (crypto.sha256.convert(parser).toString() != payload['sha256']) {
      throw const FormatException('builtin_parser_hash');
    }
    return SignedParserManifest._(
      Map.unmodifiable(payload),
      Uint8List(0),
      crypto.sha256.convert(utf8.encode(text)).toString(),
    );
  }

  static Future<SignedParserManifest> verify(
    List<int> bytes, {
    required String publicKeyHex,
    required Map<String, dynamic> schema,
  }) async {
    if (bytes.length > 1024 * 1024) {
      throw const FormatException('manifest_size');
    }
    final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    validateManifestSchema(envelope, schema, schema);
    final message = utf8.encode(envelope['payload'] as String);
    final valid = await Ed25519().verify(
      message,
      signature: Signature(
        _hex(envelope['signature'] as String),
        publicKey: SimplePublicKey(
          _hex(publicKeyHex),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) throw const FormatException('manifest_signature');
    final payload =
        jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
    validateManifestSchema(
      payload,
      (schema[r'$defs'] as Map)['payload'] as Map,
      schema,
    );
    _validateSemantics(payload);
    return SignedParserManifest._(
      Map.unmodifiable(payload),
      Uint8List.fromList(bytes),
      crypto.sha256.convert(message).toString(),
    );
  }

  bool supportsApp(String version) =>
      compareAppVersions(version, payload['minAppVersion'] as String) >= 0;
  List<Map<String, dynamic>> sitesFor(String version) => [
    for (final site in sites)
      if (compareAppVersions(version, site['minAppVersion'] as String) >= 0 &&
          (site['requiredCapabilities'] as List).every(
            (c) => const {'registry_v2', 'parser_abi_1'}.contains(c),
          ))
        site,
  ];
  Map<String, dynamic> recognitionView(String version) => {
    'sites': [
      for (final site in sitesFor(version))
        if (site['enabled'] == true)
          {'id': site['id'], 'routes': (site['match'] as Map)['routes']},
    ],
  };
  static List<int> _hex(String value) {
    if (!RegExp(r'^(?:[a-fA-F0-9]{2})+$').hasMatch(value)) {
      throw const FormatException('manifest_hex');
    }
    return [
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ];
  }
}

int compareAppVersions(String first, String second) {
  List<int> parts(String value) {
    final core = value.split('+').first;
    if (!RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
    ).hasMatch(core)) {
      throw const FormatException('manifest_version');
    }
    return core.split('.').map(int.parse).toList();
  }

  final a = parts(first), b = parts(second);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}

/// Same restricted schema vocabulary as scripts/sites_config.js.
/// The schema is trusted App data, not fetched from the network.
void validateManifestSchema(Object? value, Map rule, Map schema) {
  const annotations = {
    r'$schema',
    r'$id',
    'title',
    'description',
    r'$defs',
    'contentMediaType',
    'contentSchema',
  };
  const supported = {
    r'$ref',
    'type',
    'properties',
    'additionalProperties',
    'required',
    'items',
    'minItems',
    'maxItems',
    'uniqueItems',
    'minLength',
    'maxLength',
    'pattern',
    'enum',
    'const',
    'minimum',
    'maximum',
    'format',
  };
  Never fail() => throw const FormatException('manifest_schema');
  if (rule.keys.any(
    (k) => !annotations.contains(k) && !supported.contains(k),
  )) {
    fail();
  }
  if (rule.containsKey(r'$ref')) {
    Object? target = schema;
    for (final key in (rule[r'$ref'] as String).split('/').skip(1)) {
      target = (target as Map)[key];
    }
    validateManifestSchema(value, target as Map, schema);
    return;
  }
  if (rule.containsKey('const') && value != rule['const']) fail();
  if (rule['enum'] is List && !(rule['enum'] as List).contains(value)) fail();
  switch (rule['type']) {
    case 'object':
      if (value is! Map) fail();
      for (final key in rule['required'] as List? ?? []) {
        if (!value.containsKey(key)) fail();
      }
      final properties = rule['properties'] as Map? ?? {};
      for (final entry in value.entries) {
        final child = properties[entry.key] ?? rule['additionalProperties'];
        if (child == false) fail();
        if (child is Map) validateManifestSchema(entry.value, child, schema);
      }
    case 'array':
      if (value is! List) fail();
      if (value.length < (rule['minItems'] as int? ?? 0) ||
          value.length > (rule['maxItems'] as int? ?? 1 << 30)) {
        fail();
      }
      if (rule['uniqueItems'] == true &&
          value.map(jsonEncode).toSet().length != value.length) {
        fail();
      }
      for (final item in value) {
        validateManifestSchema(item, rule['items'] as Map, schema);
      }
    case 'string':
      if (value is! String) fail();
      if (value.length < (rule['minLength'] as int? ?? 0) ||
          value.length > (rule['maxLength'] as int? ?? 1 << 30)) {
        fail();
      }
      if (rule['pattern'] is String &&
          !RegExp(rule['pattern'] as String).hasMatch(value)) {
        fail();
      }
      if (rule['format'] == 'uri' && !Uri.parse(value).hasScheme) fail();
    case 'integer':
      if (value is! int ||
          value < (rule['minimum'] as num? ?? -double.infinity) ||
          value > (rule['maximum'] as num? ?? double.infinity)) {
        fail();
      }
    case 'boolean':
      if (value is! bool) fail();
  }
}

void _validateSemantics(Map<String, dynamic> payload) {
  final url = Uri.parse(payload['parserUrl'] as String);
  if (url.scheme != 'https' ||
      url.host != 'github.com' ||
      url.hasPort ||
      url.userInfo.isNotEmpty ||
      url.hasQuery ||
      url.hasFragment ||
      !RegExp(
        r'^/[^/]+/[^/]+/releases/download/parser-v[0-9]+\.[0-9]+\.[0-9]+/parser\.js$',
      ).hasMatch(url.path) ||
      !url.path.endsWith(
        '/parser-v${payload['parserVersion'] as String}/parser.js',
      )) {
    throw const FormatException('manifest_parser_url');
  }
  final ids = <String>{};
  final domain = RegExp(
    r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*$',
  );
  for (final site in (payload['sites'] as List).cast<Map>()) {
    if (!ids.add(site['id'] as String)) {
      throw const FormatException('manifest_duplicate_site');
    }
    final routes = ((site['match'] as Map)['routes'] as List).cast<Map>();
    final download = site['download'] as Map;
    if (download['urlOrder'] != null &&
        !const {'primaryFirst', 'fallbackFirst'}.contains(download['urlOrder'])) {
      throw const FormatException('manifest_url_order');
    }
    final hosts = [
      for (final route in routes) ...(route['hosts'] as List).cast<Map>(),
      for (final short in (site['shortLinks'] as List).cast<Map>())
        short['host'] as Map,
      ...(download['mediaHosts'] as List).cast<Map>(),
    ];
    final domains = [
      for (final host in hosts) host['domain'] as String,
      ...(download['cookieDomains'] as List).cast<String>(),
    ];
    if (domains.any((d) => !domain.hasMatch(d))) {
      throw const FormatException('manifest_domain');
    }
    for (final route in routes) {
      if ((route['hosts'] as List).isEmpty ||
          (route['pathPatterns'] as List).isEmpty) {
        throw const FormatException('manifest_route');
      }
      for (final pattern in (route['pathPatterns'] as List).cast<String>()) {
        if (!pattern.startsWith('^/')) {
          throw const FormatException('manifest_path');
        }
        RegExp(pattern);
      }
    }
    _validateHeaderValues(download['headers'] as Map);

    final declaredCookies = (download['cookieDomains'] as List).cast<String>().toSet();
    for (final entry in ((download['resourceDefaults'] as Map?) ?? {}).values) {
      final defaults = entry as Map;
      _validateHeaderValues(defaults['headers'] as Map? ?? {});
      if ((defaults['cookieDomains'] as List? ?? []).any((d) => !declaredCookies.contains(d))) {
        throw const FormatException('manifest_cookie_domain');
      }
    }
    final auth = site['auth'] as Map;
    if (auth['mode'] != 'none' && auth['loginUrl'] == null) {
      throw const FormatException('manifest_login_url');
    }
    for (final raw in [
      if (auth['loginUrl'] != null) auth['loginUrl'],
      ...auth['cookieUrls'] as List? ?? [],
    ]) {
      final uri = Uri.parse(raw as String);
      final allowed = routes.any(
        (r) => (r['hosts'] as List).cast<Map>().any(
          (h) =>
              uri.host == h['domain'] ||
              (h['includeSubdomains'] == true &&
                  uri.host.endsWith('.${h['domain']}')),
        ),
      );
      if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || !allowed) {
        throw const FormatException('manifest_login_url');
      }
    }
    if (auth['userAgent'] != null) {
      _validateHeaderValues({'User-Agent': auth['userAgent']});
    }
  }
  for (final headers in (payload['headers'] as Map? ?? {}).values) {
    _validateHeaderValues(headers as Map);
  }
}

void _validateHeaderValues(Map headers) {
  if (headers.values.any((v) => RegExp(r'[\r\n\x00]').hasMatch(v as String))) {
    throw const FormatException('manifest_header');
  }
}
