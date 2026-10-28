import 'package:http/http.dart' as http;

/// Disable automatic redirects so every Location is checked before requesting it.
Future<http.Response> downloadParserHttps(http.Client client, Uri uri) async {
  for (var redirects = 0; ; redirects++) {
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('parser_redirect_scheme');
    }
    final request = http.Request('GET', uri)..followRedirects = false;
    final response = await client.send(request);
    if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
      await response.stream.drain<void>();
      final location = response.headers['location'];
      if (redirects >= 5 || location == null || location.isEmpty) {
        throw const FormatException('parser_redirect_limit');
      }
      uri = uri.resolve(location);
      continue;
    }
    return http.Response.fromStream(response);
  }
}
