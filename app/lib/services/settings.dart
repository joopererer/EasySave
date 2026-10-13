// Download settings persisted with shared_preferences.

import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const defaultAlbumName = 'EasySave';
  static const defaultNamePattern = '{id}_{seq}';

  String albumName = defaultAlbumName;
  String namePattern = defaultNamePattern;
  bool saveCaptionTxt = false;
  bool autoClipboard = true;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings()
      ..albumName = prefs.getString('albumName') ?? defaultAlbumName
      ..namePattern = prefs.getString('namePattern') ?? defaultNamePattern
      ..saveCaptionTxt = prefs.getBool('saveCaptionTxt') ?? false
      ..autoClipboard = prefs.getBool('autoClipboard') ?? true;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('albumName', albumName);
    await prefs.setString('namePattern', namePattern);
    await prefs.setBool('saveCaptionTxt', saveCaptionTxt);
    await prefs.setBool('autoClipboard', autoClipboard);
  }

  /// Expand {id} {seq} {date} {author}; unknown tokens stay untouched.
  String fileName({
    required String postId,
    required int seq,
    required String author,
  }) {
    final date = DateTime.now();
    final stamp =
        '${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}';
    return namePattern
        .replaceAll('{id}', postId)
        .replaceAll('{seq}', '$seq')
        .replaceAll('{date}', stamp)
        .replaceAll('{author}', author.isEmpty ? 'unknown' : author);
  }
}
