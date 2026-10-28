import 'dart:convert';
import 'dart:io';
import 'package:provenance_dart/provenance_dart.dart' show normalizeUrl;

/// Release tooling calls the actual read-only dependency, not a JS reimplementation.
void main() {
  final sites = jsonDecode(stdin.readLineSync()!) as List;
  for (final site in sites.cast<Map>()) {
    final normalize = site['normalize'] as Map;
    final id = normalize['exampleId'];
    if (id is! String || id.isEmpty) {
      throw FormatException('Missing canonical example ID: ${site['id']}');
    }
    final template = normalize['canonicalTemplate'] as String;
    final url = template.replaceAll('{id}', Uri.encodeComponent(id));
    if (!template.contains('{id}') || normalizeUrl(url) != url) {
      throw FormatException('canonicalTemplate is not stable: ${site['id']}');
    }
  }
}
