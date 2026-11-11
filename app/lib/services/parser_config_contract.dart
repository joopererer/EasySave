/// Fields consumed by this App outside the parser ABI. Older signed bundles
/// remain authentic, but cannot provide this App's final-navigation behavior.
void validateAppParserConfig(Map payload) {
  final sites = payload['sites'];
  if (sites is! List) throw const FormatException('sites');
  for (final site in sites.whereType<Map>()) {
    if (site['id'] != 'xhs' || site['enabled'] != true) continue;
    final auth = site['auth'];
    for (final key in ['openDomains', 'probeUrls', 'sessionCookieNames']) {
      if (auth is! Map || auth[key] == null) {
        throw FormatException('sites.xhs.auth.$key');
      }
    }
    for (final domain in ['xiaohongshu.com', 'rednote.com']) {
      if ((auth['openDomains'] as Map)[domain] is! String) {
        throw FormatException('sites.xhs.auth.openDomains.$domain');
      }
    }
    if ((site['load'] as Map?)?['terminalPages'] is! List) {
      throw const FormatException('sites.xhs.load.terminalPages');
    }
    // A signed bundle without the token rule cannot tell "no xsec_token" apart
    // from "post deleted"; this App refuses to guess.
    final load = site['load'] as Map;
    final tokens = load['accessTokenParams'];
    if (tokens is! List ||
        !tokens.contains('xsec_token') ||
        !(load['terminalPages'] as List).any(
          (rule) =>
              rule is Map &&
              rule['category'] == '404' &&
              rule['missingTokenCode'] is String &&
              rule['missingTokenMessage'] is String,
        )) {
      throw const FormatException('sites.xhs.load.accessTokenParams');
    }
    for (final rule in (site['shortLinks'] as List).whereType<Map>()) {
      if (rule['stopAtPost'] is! bool) {
        throw const FormatException('sites.xhs.shortLinks.stopAtPost');
      }
    }
  }
}
