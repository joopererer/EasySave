// Download settings persisted with shared_preferences.

import 'package:shared_preferences/shared_preferences.dart';

/// History page view modes (ui-spec §2.4.1).
enum HistoryView { posts, all, creators }

/// Posts-view layout (ui-spec §2.4.3 / §2.4.4).
enum HistoryLayout { waterfall, list }

/// Sort modes (ui-spec §2.4.7).
enum HistorySort { latest, earliest, type, mostFiles, author }

class AppSettings {
  static const defaultAlbumName = 'EasySave';
  static const defaultNamePattern = '{id}_{seq}';

  String albumName = defaultAlbumName;
  String namePattern = defaultNamePattern;
  bool saveCaptionTxt = false;
  bool autoClipboard = true;

  /// Every album the app has ever saved into (the current one plus the ones
  /// used earlier). The rebuild scan works on this list.
  ///
  /// The names are never derived from file names: they come from the album
  /// the user picked in the settings and from MediaStore
  /// (BUCKET_DISPLAY_NAME / RELATIVE_PATH) for the files that were located.
  List<String> usedAlbumNames = <String>[];

  /// Save provenance metadata (XMP) to downloaded images. When false, skips
  /// XMP embedding but still writes assetId to HistoryDb.
  bool saveProvenanceInImages = true;

  /// Show a Toast for background (share / tile / bubble) download progress:
  /// "下载准备中…", start, error and completion. Some users prefer the
  /// notification instead.
  bool backgroundToast = true;

  /// Floating bubble (roadmap v1.6), default off.
  bool bubbleEnabled = false;

  /// Whether the one-time "allow autostart so the bubble survives swipe"
  /// hint has been shown.
  bool bubbleAutoStartHintShown = false;

  // Persisted history page preferences.
  HistoryView historyView = HistoryView.posts;
  HistoryLayout historyLayout = HistoryLayout.waterfall;
  HistorySort historySort = HistorySort.latest;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings()
      ..albumName = prefs.getString('albumName') ?? defaultAlbumName
      ..namePattern = prefs.getString('namePattern') ?? defaultNamePattern
      ..saveCaptionTxt = prefs.getBool('saveCaptionTxt') ?? false
      ..autoClipboard = prefs.getBool('autoClipboard') ?? true
      ..backgroundToast = prefs.getBool('backgroundToast') ?? true
      ..bubbleEnabled = prefs.getBool('bubbleEnabled') ?? false
      ..bubbleAutoStartHintShown = prefs.getBool('bubbleAutoStartHintShown') ?? false
      ..historyView = _enumFromName(
        HistoryView.values,
        prefs.getString('historyView'),
        HistoryView.posts,
      )
      ..historyLayout = _enumFromName(
        HistoryLayout.values,
        prefs.getString('historyLayout'),
        HistoryLayout.waterfall,
      )
      ..historySort = _enumFromName(
        HistorySort.values,
        prefs.getString('historySort'),
        HistorySort.latest,
      )
      ..saveProvenanceInImages = prefs.getBool('saveProvenanceInImages') ?? true
      ..usedAlbumNames = prefs.getStringList('usedAlbumNames') ?? const [];
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('albumName', albumName);
    await prefs.setString('namePattern', namePattern);
    await prefs.setBool('saveCaptionTxt', saveCaptionTxt);
    await prefs.setBool('autoClipboard', autoClipboard);
    await prefs.setBool('backgroundToast', backgroundToast);
    await prefs.setBool('bubbleEnabled', bubbleEnabled);
    await prefs.setBool('bubbleAutoStartHintShown', bubbleAutoStartHintShown);
    await prefs.setString('historyView', historyView.name);
    await prefs.setString('historyLayout', historyLayout.name);
    await prefs.setString('historySort', historySort.name);
    await prefs.setBool('saveProvenanceInImages', saveProvenanceInImages);
    await prefs.setStringList('usedAlbumNames', usedAlbumNames);
  }

  /// Remember [albumName] as an album the app has used.
  ///
  /// Renaming the album appends: the old album still holds files, so the
  /// rebuild scan must keep looking there. Names are compared case
  /// insensitively; the first spelling wins.
  void rememberAlbum(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final exists = usedAlbumNames.any(
      (n) => n.trim().toLowerCase() == trimmed.toLowerCase(),
    );
    if (exists) return;
    usedAlbumNames.add(trimmed);
  }

  /// All albums the app has used: the current one plus the remembered ones.
  List<String> get effectiveAlbumNames {
    final names = <String>[];
    final seen = <String>{};
    for (final name in [albumName, ...usedAlbumNames]) {
      final trimmed = name.trim();
      if (trimmed.isEmpty) continue;
      final key = trimmed.toLowerCase();
      if (!seen.add(key)) continue;
      names.add(trimmed);
    }
    return names;
  }

  static T _enumFromName<T extends Enum>(List<T> values, String? name, T fallback) {
    if (name == null) return fallback;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
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
