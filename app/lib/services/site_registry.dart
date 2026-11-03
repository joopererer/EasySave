import 'dart:convert';
import '../generated/builtin_sites.dart';

class SiteDefinition {
  SiteDefinition(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get platform => data['platform'] as String;
  String get displayName => data['displayName'] as String;
  String get creditName => data['creditName'] as String;
  String? get assetKey => (data['icon'] as Map?)?['assetKey'] as String?;
  bool get enabled => data['enabled'] == true;
  Map get auth => data['auth'] as Map;
  Map get load => data['load'] as Map;
  List get terminalPages =>
      (load['terminalPages'] as List?) ??
      (SiteRegistry.builtinById(id)?.load['terminalPages'] as List?) ??
      const [];
  Map get normalization => data['normalize'] as Map;
  String get parserModule => data['parserModule'] as String;
  String get authorIdRule =>
      (data['metadata'] as Map)['authorIdRule'] as String;

  bool matches(Uri uri) =>
      ((data['match'] as Map)['routes'] as List).cast<Map>().any(
        (route) =>
            (route['hosts'] as List).cast<Map>().any(
              (host) => matchesHost(uri.host, host),
            ) &&
            (route['pathPatterns'] as List).cast<String>().any(
              (p) => RegExp(p).hasMatch(uri.path),
            ),
      );

  bool hasHost(String host) =>
      ((data['match'] as Map)['routes'] as List).cast<Map>().any(
        (r) =>
            (r['hosts'] as List).cast<Map>().any((h) => matchesHost(host, h)),
      );

  Map? shortLink(Uri uri) => (data['shortLinks'] as List)
      .cast<Map>()
      .where(
        (r) =>
            matchesHost(uri.host, r['host'] as Map) &&
            (r['pathPatterns'] == null ||
                (r['pathPatterns'] as List).cast<String>().any(
                  (p) => RegExp(p).hasMatch(uri.path),
                )),
      )
      .firstOrNull;

  String? shortLinkFallback(Uri uri, Map rule) =>
      (rule['fallbackStrategy'] as String?) ??
      (SiteRegistry.builtinById(id)?.shortLink(uri)?['fallbackStrategy'] as String?);

  String? sourceId(Uri uri) {
    final source = normalization['sourceId'] as Map;
    final value = source['source'] == 'query'
        ? uri.queryParameters[source['queryKey']]
        : uri.path;
    if (value == null) return null;
    final match = RegExp(source['pattern'] as String).firstMatch(value);
    if (match == null) return null;
    return [
      for (var i = 1; i <= match.groupCount; i++) match.group(i),
    ].whereType<String>().firstOrNull;
  }

  String canonical(String id) => (normalization['canonicalTemplate'] as String)
      .replaceAll('{id}', Uri.encodeComponent(id));
  bool allowsAuthorId(String? value) =>
      value != null &&
      value.isNotEmpty &&
      (authorIdRule == 'opaque' ||
          (authorIdRule == 'numeric' && RegExp(r'^\d+$').hasMatch(value)));
}

bool matchesHost(String host, Map rule) {
  host = host.toLowerCase();
  final domain = rule['domain'] as String;
  return host == domain ||
      (rule['includeSubdomains'] == true && host.endsWith('.$domain'));
}

class SiteRegistry {
  SiteRegistry(Iterable<Map<String, dynamic>> definitions)
    : sites = List.unmodifiable(definitions.map(SiteDefinition.new));
  final List<SiteDefinition> sites;
  static SiteRegistry _builtin() => SiteRegistry(
    (jsonDecode(builtinSitesJson) as List).cast<Map<String, dynamic>>(),
  );
  static final SiteRegistry _builtinDefinitions = _builtin();
  static SiteDefinition? builtinById(String id) => _builtinDefinitions.byId(id);
  static SiteRegistry current = _builtin();
  static void useBuiltin() => current = _builtin();
  static void activate(Iterable<Map<String, dynamic>> sites) =>
      current = SiteRegistry(sites);

  SiteDefinition? byId(String id) =>
      sites.where((s) => s.id == id || s.platform == id).firstOrNull;
  SiteDefinition? forHost(String host) =>
      sites.where((s) => s.hasHost(host)).firstOrNull;
  String? canonicalUrl(String text) {
    final site = match(text);
    if (site == null) return null;
    final id = site.sourceId(Uri.parse(text));
    return id == null ? null : site.canonical(id);
  }

  SiteDefinition? match(String text, {bool includeDisabled = false}) {
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty) {
      return null;
    }
    return sites
        .where((s) => (includeDisabled || s.enabled) && s.matches(uri))
        .firstOrNull;
  }
}
