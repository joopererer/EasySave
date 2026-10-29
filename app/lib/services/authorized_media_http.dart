import 'dart:async';

import 'package:http/http.dart' as http;

import '../core/media_request.dart';
import 'media_request_policy.dart';

/// A bounded request that asks the policy to authorize each network hop.
/// The caller owns [client]. Cookies are held only in the current request.
Future<http.StreamedResponse> sendAuthorizedMediaGet(
  http.Client client,
  MediaRequestPolicy policy,
  MediaRequestResource resource, {
  Duration timeout = const Duration(seconds: 15),
  int maxRedirects = 5,
}) async {
  var current = await policy.authorize(resource);
  for (var hop = 0; hop <= maxRedirects; hop++) {
    final request = http.Request('GET', current.uri)
      ..followRedirects = false
      ..headers.addAll(current.wireHeaders);
    final response = await client.send(request).timeout(timeout);
    if (response.statusCode < 300 || response.statusCode >= 400) {
      return response;
    }
    final location = response.headers['location'];
    await response.stream.drain<void>();
    if (location == null || hop == maxRedirects) {
      policy.rejectRedirect(current.uri);
    }
    current = await policy.redirect(current, location);
  }
  policy.rejectRedirect(current.uri);
}
