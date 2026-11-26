// Download settings persisted with shared_preferences.

import 'package:shared_preferences/shared_preferences.dart';

import 'creator_sort.dart';
import 'image_format_preference.dart';

/// Compile-time default for manual resume fallback (v1.12 build 74).
/// When true, defaults to manual resume on network disconnect.
/// Set to false in build 74; if real-device test fails, flip this single constant to true in the next build.
const bool kDefaultManualResumeOnlyOnDisconnect = false;

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

  /// Whether to auto-hide the floating bubble to screen edge when idle
  /// (roadmap v1.7.1), default on.
  bool bubbleAutoHide = true;

  /// Whether long-pressing a thumbnail in the bubble "select download" panel
  /// opens a persistent fullscreen preview (default false = peek-and-release).
  bool bubblePreviewSticky = false;

  /// Whether the one-time "allow autostart so the bubble survives swipe"
  /// hint has been shown.
  bool bubbleAutoStartHintShown = false;

  // Persisted history page preferences.
  HistoryView historyView = HistoryView.posts;
  HistoryLayout historyLayout = HistoryLayout.waterfall;
  HistorySort historySort = HistorySort.latest;

  /// 我的 → 设置 → 下载 → 图片格式 (v1.11 batch 3). Only 小红书 stills are
  /// affected: other platforms hand out one kind of still URL.
  ImageFormatPreference imageFormat = ImageFormatPreference.compat;

  /// 创作者 view ordering (v1.11 batch 1): key plus direction, remembered
  /// across launches. 最近保存 descending is the default.
  CreatorSort creatorSort = CreatorSortState.defaults.mode;
  bool creatorSortDescending = CreatorSortState.defaults.descending;

  /// User-chosen directory tree URI for external automatic backups (v1.8).
  String? backupTreeUri;

  /// Display name of [backupTreeUri] (e.g. the folder name as the system shows
  /// it). Written into the backup so a restore can ask the user to re-authorise
  /// the same folder; the URI grant itself is never backed up.
  String? backupFolderName;

  /// Whether automatic backup to external SAF folder is enabled (v1.8).
  ///
  /// The backing value is only written back by a [save] of an instance that
  /// actually read it (or assigned it), so a default-constructed snapshot can
  /// never silently switch the feature off.
  bool get autoFolderBackupEnabled => _autoFolderBackup;
  set autoFolderBackupEnabled(bool value) {
    _autoFolderBackup = value;
    _autoFolderBackupKnown = true;
  }

  bool _autoFolderBackup = false;
  bool _autoFolderBackupKnown = false;

  /// Timestamp (ms) of the last successful backup (v1.8).
  int? lastBackupTime;

  /// Whether user clicked 'Skip' on the initial restore prompt (v1.8).
  bool skipRestoreHint = false;

  /// Whether user has dismissed the gentle reminder to set up backup folder (v1.8).
  bool backupFolderHintDismissed = false;

  /// Whether user has dismissed the one-time video provenance backfill hint (v1.8.2).
  bool videoBackfillHintDismissed = false;

  /// Whether the 开发者选项 group on the 我的 page is visible. Hidden for
  /// normal users and revealed by tapping the version number seven times
  /// (v1.11 batch 4); the state is persisted so it stays revealed.
  bool developerOptionsVisible = false;

  /// Fallback option in developer options (v1.12 build 73): when true, large files
  /// do not auto-resume on disconnect, but stop at "已中断，点继续" for manual resume.
  bool manualResumeOnlyOnDisconnect = kDefaultManualResumeOnlyOnDisconnect;

  /// Developer option (v1.13 P0-5): route downloads through TransferService (default true).
  bool useNewTransferPipeline = true;

  /// Set only by [clearBackupFolder]: a regular [save] must keep the folder.
  bool _forgetBackupFolder = false;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return AppSettings()
      ..albumName = prefs.getString('albumName') ?? defaultAlbumName
      ..namePattern = prefs.getString('namePattern') ?? defaultNamePattern
      ..saveCaptionTxt = prefs.getBool('saveCaptionTxt') ?? false
      ..autoClipboard = prefs.getBool('autoClipboard') ?? true
      ..backgroundToast = prefs.getBool('backgroundToast') ?? true
      ..bubbleEnabled = prefs.getBool('bubbleEnabled') ?? false
      ..bubbleAutoHide = prefs.getBool('bubbleAutoHide') ?? true
      ..bubblePreviewSticky = prefs.getBool('bubblePreviewSticky') ?? false
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
      ..imageFormat = _enumFromName(
        ImageFormatPreference.values,
        prefs.getString('imageFormat'),
        ImageFormatPreference.compat,
      )
      ..creatorSort = _enumFromName(
        CreatorSort.values,
        prefs.getString('creatorSort'),
        CreatorSortState.defaults.mode,
      )
      ..creatorSortDescending =
          prefs.getBool('creatorSortDescending') ??
              CreatorSortState.defaults.descending
      ..saveProvenanceInImages = prefs.getBool('saveProvenanceInImages') ?? true
      ..usedAlbumNames = List<String>.from(
        prefs.getStringList('usedAlbumNames') ?? const <String>[],
      )
      ..backupTreeUri = prefs.getString('backupTreeUri')
      ..backupFolderName = prefs.getString('backupFolderName')
      ..autoFolderBackupEnabled = prefs.getBool('autoFolderBackupEnabled') ?? false
      ..lastBackupTime = prefs.getInt('lastBackupTime')
      ..skipRestoreHint = prefs.getBool('skipRestoreHint') ?? false
      ..backupFolderHintDismissed = prefs.getBool('backupFolderHintDismissed') ?? false
      ..developerOptionsVisible = prefs.getBool('developerOptionsVisible') ?? false
      ..manualResumeOnlyOnDisconnect = prefs.getBool('manualResumeOnlyOnDisconnect') ?? kDefaultManualResumeOnlyOnDisconnect
      ..useNewTransferPipeline = prefs.getBool('useNewTransferPipeline') ?? true
      ..videoBackfillHintDismissed = prefs.getBool('videoBackfillHintDismissed') ?? false;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('albumName', albumName);
    await prefs.setString('namePattern', namePattern);
    await prefs.setBool('saveCaptionTxt', saveCaptionTxt);
    await prefs.setBool('autoClipboard', autoClipboard);
    await prefs.setBool('backgroundToast', backgroundToast);
    await prefs.setBool('bubbleEnabled', bubbleEnabled);
    await prefs.setBool('bubbleAutoHide', bubbleAutoHide);
    await prefs.setBool('bubblePreviewSticky', bubblePreviewSticky);
    await prefs.setBool('bubbleAutoStartHintShown', bubbleAutoStartHintShown);
    await prefs.setString('historyView', historyView.name);
    await prefs.setString('historyLayout', historyLayout.name);
    await prefs.setString('historySort', historySort.name);
    await prefs.setString('imageFormat', imageFormat.name);
    await prefs.setString('creatorSort', creatorSort.name);
    await prefs.setBool('creatorSortDescending', creatorSortDescending);
    await prefs.setBool('saveProvenanceInImages', saveProvenanceInImages);
    await prefs.setStringList('usedAlbumNames', usedAlbumNames);
    // The backup folder is only ever forgotten by clearBackupFolder(). A
    // full-object save (startup backup, bubble sync, restore, …) must never
    // remove it just because this snapshot was taken before the folder was
    // chosen: that is what made the folder and its switch disappear after an
    // app update.
    if (backupTreeUri != null && backupTreeUri!.isNotEmpty) {
      await prefs.setString('backupTreeUri', backupTreeUri!);
    } else if (_forgetBackupFolder) {
      await prefs.remove('backupTreeUri');
    }
    if (backupFolderName != null && backupFolderName!.isNotEmpty) {
      await prefs.setString('backupFolderName', backupFolderName!);
    } else if (_forgetBackupFolder) {
      await prefs.remove('backupFolderName');
    }
    if (_autoFolderBackupKnown) {
      await prefs.setBool('autoFolderBackupEnabled', _autoFolderBackup);
    }
    if (lastBackupTime != null) {
      await prefs.setInt('lastBackupTime', lastBackupTime!);
    } else {
      await prefs.remove('lastBackupTime');
    }
    await prefs.setBool('skipRestoreHint', skipRestoreHint);
    await prefs.setBool('backupFolderHintDismissed', backupFolderHintDismissed);
    await prefs.setBool('developerOptionsVisible', developerOptionsVisible);
    await prefs.setBool('manualResumeOnlyOnDisconnect', manualResumeOnlyOnDisconnect);
    await prefs.setBool('useNewTransferPipeline', useNewTransferPipeline);
    await prefs.setBool('videoBackfillHintDismissed', videoBackfillHintDismissed);
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
    usedAlbumNames = <String>[...usedAlbumNames, trimmed];
  }

  /// Forgets the backup folder and switches auto backup off. Only an explicit
  /// user action ("更换文件夹" → 移除, or a new folder) reaches this; a lost
  /// grant keeps both values so the user can re-authorise the same directory.
  Future<void> clearBackupFolder() async {
    backupTreeUri = null;
    backupFolderName = null;
    autoFolderBackupEnabled = false;
    _forgetBackupFolder = true;
    try {
      await save();
    } finally {
      _forgetBackupFolder = false;
    }
  }

  /// All albums the app has used: the current one plus the remembered ones.
  List<String> get effectiveAlbumNames {    final names = <String>[];
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
