// Download history stored in a local sqflite table.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import 'clipboard_guard.dart';
import 'site_registry.dart';

enum FileStatus {
  unknown,
  found,
  notFound,
}

class HistoryFile {
  HistoryFile({
    required this.filename,
    required this.savedAt,
    this.mediaId,
    this.status = FileStatus.unknown,
    required this.itemIndex,
    this.isImage = true,
    this.assetId,
    this.relativePath,
    this.itemCount,
    this.capturedBy,
  });

  final String filename;
  final int savedAt;
  final String? mediaId;
  final FileStatus status;

  /// 1-based position in the original post. Never 0: an index taken straight
  /// from a list position made the first item indistinguishable from "unset"
  /// and produced a second row for the same album file.
  final int itemIndex;
  final bool isImage;

  /// Provenance asset ID (prov:assetId). Stored in files_json for reuse
  /// when re-downloading the same file across devices.
  final String? assetId;

  /// MediaStore RELATIVE_PATH (e.g. Pictures/EasySave/).
  /// May be null for older records before first gallery location.
  final String? relativePath;

  /// prov:itemCount exactly as written into the file. Null when the file was
  /// stored without provenance, so consumers must omit it instead of deriving
  /// a value from the number of rows in this record.
  final int? itemCount;

  /// prov:capturedBy exactly as written into the file. Null when unknown;
  /// never re-derived from the app version at export time.
  final String? capturedBy;

  Map<String, Object?> toMap() => {
    'filename': filename,
    'saved_at': savedAt,
    'media_id': mediaId,
    'status': status.name,
    'item_index': itemIndex,
    'is_image': isImage ? 1 : 0,
    'asset_id': assetId,
    'relative_path': relativePath,
    if (itemCount != null) 'item_count': itemCount,
    if (capturedBy != null) 'captured_by': capturedBy,
  };

  factory HistoryFile.fromMap(Map<String, Object?> map) => HistoryFile(
    filename: map['filename'] as String? ?? '',
    savedAt: (map['saved_at'] as num?)?.toInt() ?? 0,
    mediaId: map['media_id'] as String?,
    status: FileStatus.values.firstWhere(
      (s) => s.name == map['status'],
      orElse: () => FileStatus.unknown,
    ),
    itemIndex: (map['item_index'] as num?)?.toInt() ?? 0,
    isImage: (map['is_image'] as num?)?.toInt() != 0,
    assetId: map['asset_id'] as String?,
    relativePath: map['relative_path'] as String?,
    itemCount: (map['item_count'] as num?)?.toInt(),
    capturedBy: map['captured_by'] as String?,
  );

  HistoryFile copyWith({
    String? filename,
    int? savedAt,
    String? mediaId,
    FileStatus? status,
    int? itemIndex,
    bool? isImage,
    String? assetId,
    String? relativePath,
    int? itemCount,
    String? capturedBy,
  }) => HistoryFile(
    filename: filename ?? this.filename,
    savedAt: savedAt ?? this.savedAt,
    mediaId: mediaId ?? this.mediaId,
    status: status ?? this.status,
    itemIndex: itemIndex ?? this.itemIndex,
    isImage: isImage ?? this.isImage,
    assetId: assetId ?? this.assetId,
    relativePath: relativePath ?? this.relativePath,
    itemCount: itemCount ?? this.itemCount,
    capturedBy: capturedBy ?? this.capturedBy,
  );
}

/// Whether a stored file row is a *winner* when two rows describe the same
/// album file: a real 1-based index with written provenance is preferred.
int _keeperRank(HistoryFile file) =>
    (file.itemIndex >= 1 ? 2 : 0) + (file.assetId != null ? 1 : 0);

/// Repair the file list of one history record.
///
/// Two defects are healed, and nothing outside the database is touched:
/// * a legacy set inferred from `items_json` is entirely 0-based, so every
///   index is shifted to the 1-based form the rest of the app uses;
/// * two rows that point at the same MediaStore item (`mediaId`) are collapsed
///   to one, keeping the 1-based row that carries `prov:assetId` (the one
///   written with the real provenance) and dropping the inferred stray.
///
/// Returns null when the input already satisfies those rules, so callers can
/// skip a database write.
List<HistoryFile>? repairHistoryFiles(List<HistoryFile> files) {
  if (files.isEmpty) return null;
  var changed = false;
  var working = files;

  final keep = List<bool>.filled(working.length, true);
  final byMediaId = <String, List<int>>{};
  for (var i = 0; i < working.length; i++) {
    final id = working[i].mediaId;
    if (id == null || id.isEmpty) continue;
    byMediaId.putIfAbsent(id, () => []).add(i);
  }
  for (final group in byMediaId.values) {
    if (group.length < 2) continue;
    var keeper = group.first;
    for (final i in group.skip(1)) {
      if (_keeperRank(working[i]) > _keeperRank(working[keeper])) keeper = i;
    }
    for (final i in group) {
      if (i != keeper) keep[i] = false;
    }
    changed = true;
  }
  if (changed) {
    working = [
      for (var i = 0; i < working.length; i++)
        if (keep[i]) working[i],
    ];
  }
  if (working.isEmpty) return changed ? const [] : null;

  // A set numbered from 0 predates the 1-based rule. Shift the whole set so
  // relative order survives; a single leftover 0-based row is shifted too.
  final lowest = working.map((f) => f.itemIndex).reduce((a, b) => a < b ? a : b);
  if (lowest < 1) {
    final delta = 1 - lowest;
    working = [
      for (final f in working) f.copyWith(itemIndex: f.itemIndex + delta),
    ];
    changed = true;
  }

  if (!changed) return null;
  return working;
}

/// Reject a file list that breaks the 1-based index invariant before it is
/// written. Every producer numbers items from 1; a 0 here means a list
/// position was used by mistake, and it must not reach the database.
void validateHistoryFiles(Iterable<HistoryFile> files) {
  for (final file in files) {
    if (file.itemIndex < 1) {
      throw ArgumentError.value(
        file.itemIndex,
        'itemIndex',
        'history file index must be 1-based (file "${file.filename}")',
      );
    }
  }
}

/// Whether a stored `files_json` value still holds a 0-based or duplicated
/// row, i.e. whether reading it needs a database correction.
bool historyFilesNeedRepair(String? filesJson) {
  if (filesJson == null || filesJson.isEmpty) return false;
  try {
    final decoded = jsonDecode(filesJson);
    if (decoded is! List) return false;
    final files = [
      for (final raw in decoded)
        if (raw is Map) HistoryFile.fromMap(raw.cast<String, Object?>()),
    ];
    return repairHistoryFiles(files) != null;
  } catch (_) {
    return false;
  }
}

List<HistoryFile> inferHistoryFiles({
  required String postId,
  required String authorName,
  required DateTime createdAt,
  required String? itemsJson,
  String namePattern = '{id}_{seq}',
}) {
  final files = <HistoryFile>[];
  if (itemsJson == null || itemsJson.isEmpty) return files;
  try {
    final decoded = jsonDecode(itemsJson);
    if (decoded is! List) return files;

    final stamp =
        '${createdAt.year}${createdAt.month.toString().padLeft(2, '0')}${createdAt.day.toString().padLeft(2, '0')}';
    final safeAuthor = authorName.isEmpty ? 'unknown' : authorName;

    String resolveBase(int seq) {
      return namePattern
          .replaceAll('{id}', postId)
          .replaceAll('{seq}', '$seq')
          .replaceAll('{date}', stamp)
          .replaceAll('{author}', safeAuthor);
    }

    var seq = 0;
    for (var i = 0; i < decoded.length; i++) {
      final raw = decoded[i];
      if (raw is! Map) continue;
      final map = raw.cast<String, Object?>();
      final type = map['type'] as String? ?? 'image';
      seq++;
      final base = resolveBase(seq);

      if (type == 'live' && map['videoUrl'] != null) {
        files.add(
          HistoryFile(
            filename: '$base.jpg',
            savedAt: createdAt.millisecondsSinceEpoch,
            status: FileStatus.unknown,
            itemIndex: i + 1,
            isImage: true,
          ),
        );
        files.add(
          HistoryFile(
            filename: '$base.mp4',
            savedAt: createdAt.millisecondsSinceEpoch,
            status: FileStatus.unknown,
            itemIndex: i + 1,
            isImage: false,
          ),
        );
      } else if (type == 'video') {
        files.add(
          HistoryFile(
            filename: '$base.mp4',
            savedAt: createdAt.millisecondsSinceEpoch,
            status: FileStatus.unknown,
            itemIndex: i + 1,
            isImage: false,
          ),
        );
      } else {
        files.add(
          HistoryFile(
            filename: '$base.jpg',
            savedAt: createdAt.millisecondsSinceEpoch,
            status: FileStatus.unknown,
            itemIndex: i + 1,
            isImage: true,
          ),
        );
      }
    }
  } catch (_) {
    // Ignore malformed items.
  }
  return files;
}

class HistoryRecord {
  HistoryRecord({
    this.id,
    required this.platform,
    String? platformDisplayName,
    required this.postId,
    this.authorName,
    this.title,
    this.caption,
    this.aiLabel,
    this.aiLabelSource,
    this.thumbnailUrl,
    required this.postUrl,
    required this.fileCount,
    required this.createdAt,
    this.itemsJson,
    List<HistoryFile>? files,
    this.isDeleted = false,
  }) : platformDisplayName = platformDisplayName ?? SiteRegistry.current.byId(platform)?.displayName,
       files = files ?? const [];

  final int? id;
  final String platform;
  final String? platformDisplayName;
  final String postId;
  final String? authorName;
  final String? title;
  final String? caption;
  final String? aiLabel;
  final String? aiLabelSource;
  final String? thumbnailUrl;
  final String postUrl;
  final int fileCount;
  final DateTime createdAt;

  /// Full parsed items JSON (enables reopening preview offline).
  final String? itemsJson;

  final List<HistoryFile> files;

  /// Soft delete flag. When true, record is hidden from UI but files remain in gallery
  /// and can be restored on rebuild. See spec/metadata.md §7.1.
  final bool isDeleted;

  /// Rebuild the parsed post from the stored `items_json`. Shared by the
  /// history cards and the preview page so both decode identically. Falls back
  /// to the stored thumbnail when no item list was persisted.
  ParsedPost toPost() {
    final items = <MediaItem>[];
    if (itemsJson != null) {
      try {
        final decoded = jsonDecode(itemsJson!) as List;
        for (final raw in decoded) {
          final map = (raw as Map).cast<String, Object?>();
          items.add(
            MediaItem(
              type: map['type'] as String? ?? 'image',
              url: map['url'] as String? ?? '',
              videoUrl: map['videoUrl'] as String?,
              posterUrl: map['posterUrl'] as String?,
              width: map['width'] as num?,
              height: map['height'] as num?,
              duration: map['duration'] as num?,
              isGif: map['isGif'] as bool?,
              fallbacks:
                  (map['fallbacks'] as List?)?.whereType<String>().toList() ??
                  const [],
            ),
          );
        }
      } catch (_) {
        // Fall through to the single-thumbnail fallback.
      }
    }
    if (items.isEmpty && thumbnailUrl != null && thumbnailUrl!.isNotEmpty) {
      items.add(MediaItem(type: 'image', url: thumbnailUrl!));
    }
    if (items.isEmpty && files.isNotEmpty) {
      final byIndex = <int, List<HistoryFile>>{};
      for (final f in files) {
        byIndex.putIfAbsent(f.itemIndex, () => []).add(f);
      }
      final sortedIndices = byIndex.keys.toList()..sort();
      for (final idx in sortedIndices) {
        final group = byIndex[idx]!;
        final img = group.where((f) => f.isImage).firstOrNull;
        final vid = group.where((f) => !f.isImage).firstOrNull;
        if (img != null && vid != null) {
          items.add(
            MediaItem(
              type: 'live',
              url: img.filename,
              videoUrl: vid.filename,
            ),
          );
        } else if (img != null) {
          items.add(
            MediaItem(
              type: 'image',
              url: img.filename,
            ),
          );
        } else if (vid != null) {
          items.add(
            MediaItem(
              type: 'video',
              url: vid.filename,
              videoUrl: vid.filename,
            ),
          );
        }
      }
    }
    return ParsedPost(
      platform: platform,
      platformDisplayName: platformDisplayName,
      id: postId,
      url: postUrl,
      author: PostAuthor(name: authorName),
      items: items,
      title: title,
      caption: caption,
      aiLabel: aiLabel == null ? null : AiLabel(text: aiLabel!, source: aiLabelSource ?? 'unknown'),
    );
  }

  Map<String, Object?> toMap() => {
    'platform': platform,
    'platform_display_name': SiteRegistry.current.byId(platform)?.displayName ?? platformDisplayName,
    'post_id': postId,
    'author_name': authorName,
    'title': title,
    'caption': caption,
    'ai_label': aiLabel,
    'ai_label_source': aiLabelSource,
    'thumbnail_url': thumbnailUrl,
    'post_url': postUrl,
    'file_count': fileCount,
    'created_at': createdAt.millisecondsSinceEpoch,
    'items_json': itemsJson,
    'files_json': jsonEncode([for (final f in files) f.toMap()]),
    'is_deleted': isDeleted ? 1 : 0,
  };

  static HistoryRecord fromMap(Map<String, Object?> map) {
    final postId = map['post_id'] as String;
    final authorName = map['author_name'] as String?;
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      (map['created_at'] as num).toInt(),
    );
    final itemsJson = map['items_json'] as String?;
    final filesJsonStr = map['files_json'] as String?;
    final isDeleted = ((map['is_deleted'] as num?)?.toInt() ?? 0) != 0;

    List<HistoryFile> resolvedFiles = [];
    if (filesJsonStr != null && filesJsonStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(filesJsonStr) as List;
        resolvedFiles = [
          for (final f in decoded)
            if (f is Map) HistoryFile.fromMap(f.cast<String, Object?>()),
        ];
      } catch (_) {}
    }

    if (resolvedFiles.isEmpty) {
      resolvedFiles = inferHistoryFiles(
        postId: postId,
        authorName: authorName ?? '',
        createdAt: createdAt,
        itemsJson: itemsJson,
      );
    } else {
      resolvedFiles = repairHistoryFiles(resolvedFiles) ?? resolvedFiles;
    }

    return HistoryRecord(
      id: map['id'] as int?,
      platform: map['platform'] as String,
      platformDisplayName: map['platform_display_name'] as String?,
      postId: postId,
      authorName: authorName,
      title: map['title'] as String?,
      caption: map['caption'] as String?,
      aiLabel: map['ai_label'] as String?,
      aiLabelSource: map['ai_label_source'] as String?,
      thumbnailUrl: map['thumbnail_url'] as String?,
      postUrl: map['post_url'] as String,
      fileCount: (map['file_count'] as num).toInt(),
      createdAt: createdAt,
      itemsJson: itemsJson,
      files: resolvedFiles,
      isDeleted: isDeleted,
    );
  }
}

class HistoryDb {
  HistoryDb._(this._db);

  final Database _db;
  Future<void>? _activeFileRepair;

  /// Listeners are notified by the write methods themselves (never by their
  /// callers), so a new caller — a new delete gesture, a rebuild, the
  /// background isolate — cannot forget to refresh the UI.
  final _listeners = <VoidCallback>[];

  /// Handle identity, so a device log can prove every caller shares one store.
  String get _id => '#${identityHashCode(this)}';

  void addListener(VoidCallback listener) {
    if (_listeners.contains(listener)) {
      DevLog.write('HIST', 'listener already attached on $_id (${_listeners.length})'); // i18n:ignore 日志
      return;
    }
    _listeners.add(listener);
    DevLog.write('HIST', 'listener added on $_id, now ${_listeners.length}'); // i18n:ignore 日志
  }

  void removeListener(VoidCallback listener) {
    final removed = _listeners.remove(listener);
    DevLog.write(
      'HIST', // i18n:ignore 日志
      'listener ${removed ? 'removed' : 'not found'} on $_id, now ${_listeners.length}',
    );
  }

  /// Notify every listener that history data changed.
  ///
  /// [reason] ends up in the device log so a bug report shows which mutation
  /// ran and how many rows it touched. One failing listener must not stop the
  /// others, so each call is guarded.
  void notifyChanged([String reason = 'mutation']) {
    if (_listeners.isEmpty) {
      DevLog.write('HIST', 'notify ($reason) but no listeners attached on $_id', // i18n:ignore 日志
          level: DevLogLevel.warn);
      return;
    }
    DevLog.write('HIST', 'notify ($reason) -> ${_listeners.length} listener(s) on $_id'); // i18n:ignore 日志
    for (final listener in List<VoidCallback>.of(_listeners)) {
      try {
        listener();
      } catch (e) {
        DevLog.write('HIST', 'listener threw: $e', // i18n:ignore 日志
            level: DevLogLevel.warn);
      }
    }
  }

  static void resetInstanceForTesting() {
    _instances.clear();
  }

  static void setInstanceForTesting(HistoryDb? db) {
    if (db == null) {
      _instances.remove(_defaultKey);
    } else {
      _instances[_defaultKey] = Future.value(db);
    }
  }

  /// One history store per database file, per isolate.
  ///
  /// The *future* is cached, not just the result: `instance()` is called from
  /// several places while the first `openDatabase` is still in flight (main()
  /// init, ParsePage's listener attach, the gallery locator). Caching only the
  /// finished instance let those concurrent callers each open their own
  /// `HistoryDb`, and the listener list — which lives on the instance — was
  /// then split: the page subscribed to an orphaned handle while the history
  /// page deleted through a different one, so `notify()` reported "no
  /// listeners attached".
  static final Map<String, Future<HistoryDb>> _instances = {};

  /// Cache key for the default database (the only one the app uses).
  static const String _defaultKey = '<default>';

  static Future<HistoryDb> instance({String? dbPath}) {
    final key = dbPath ?? _defaultKey;
    return _instances[key] ??= _open(dbPath);
  }

  static Future<HistoryDb> _open(String? dbPath) async {
    final path = dbPath ?? '${await getDatabasesPath()}/easysave_history.db';
    final db = await openDatabase(
      path,
      version: 5,
      // Two engines (main UI isolate + background isolate) can hold a
      // connection to the same file. WAL lets readers work while a writer is
      // active, and busy_timeout makes a writer wait for the lock instead of
      // failing with SQLITE_BUSY.
      onConfigure: (db) => _applyPragmas(db),
      onOpen: (db) async {
        await _applyPragmas(db);
        // Operational barrier, separate from backed-up history schema/data.
        await db.execute('CREATE TABLE IF NOT EXISTS download_delete_barriers('
            'platform TEXT NOT NULL, post_id TEXT NOT NULL, deleted_at INTEGER NOT NULL,'
            'PRIMARY KEY(platform, post_id))');
        await db.execute('CREATE TABLE IF NOT EXISTS resolved_post_links('
            'link_key TEXT PRIMARY KEY, platform TEXT NOT NULL, post_id TEXT NOT NULL)');
      },
      onCreate: (db, version) => db.execute(
        'CREATE TABLE history_records('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'platform TEXT NOT NULL,'
        'platform_display_name TEXT,'
        'post_id TEXT NOT NULL,'
        'author_name TEXT,'
        'title TEXT,'
        'caption TEXT,'
        'ai_label TEXT,'
        'ai_label_source TEXT,'
        'thumbnail_url TEXT,'
        'post_url TEXT NOT NULL UNIQUE,'
        'file_count INTEGER NOT NULL,'
        'created_at INTEGER NOT NULL,'
        'items_json TEXT,'
        'files_json TEXT,'
        'is_deleted INTEGER DEFAULT 0)',
      ),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE history_records ADD COLUMN files_json TEXT');
          final rows = await db.query('history_records');
          for (final row in rows) {
            final id = row['id'] as int;
            final postId = row['post_id'] as String;
            final authorName = row['author_name'] as String? ?? '';
            final createdAt = DateTime.fromMillisecondsSinceEpoch(
              (row['created_at'] as num).toInt(),
            );
            final itemsJson = row['items_json'] as String?;
            final inferred = inferHistoryFiles(
              postId: postId,
              authorName: authorName,
              createdAt: createdAt,
              itemsJson: itemsJson,
            );
            await db.update(
              'history_records',
              {
                'files_json': jsonEncode([for (final f in inferred) f.toMap()]),
              },
              where: 'id = ?',
              whereArgs: [id],
            );
            DevLog.write('HIST', 'file rows written source=migration post=$postId count=${inferred.length}');
          }
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE history_records ADD COLUMN is_deleted INTEGER DEFAULT 0');
        }
        if (oldVersion < 5) {
          await db.execute('ALTER TABLE history_records ADD COLUMN platform_display_name TEXT');
        }
        if (oldVersion < 4) {
          await db.execute('ALTER TABLE history_records ADD COLUMN ai_label TEXT');
          await db.execute('ALTER TABLE history_records ADD COLUMN ai_label_source TEXT');
        }
      },
    );
    // Save names while a site is known, so later removal keeps records legible.
    for (final site in SiteRegistry.current.sites) {
      await db.update('history_records', {'platform_display_name': site.displayName},
        where: '(platform = ? OR platform = ?) AND (platform_display_name IS NULL OR platform_display_name = ?)',
        whereArgs: [site.id, site.platform, '']);
    }
    final historyDb = HistoryDb._(db);
    if (dbPath == null) {
      DevLog.write('HIST', 'instance opened #${identityHashCode(historyDb)} path=$path'); // i18n:ignore 日志
    }
    return historyDb;
  }

  /// Insert or merge a history record. The whole read-merge-write runs in one
  /// transaction so two engines writing at the same time cannot lose files
  /// (the second writer waits for the lock thanks to busy_timeout).
  /// Apply the concurrency pragmas. Every `PRAGMA` that returns a value must
  /// go through [Database.rawQuery] — sqflite's `execute` rejects statements
  /// with a result set ("Queries can be performed using ... rawQuery only").
  /// The result set is consumed so the statement really runs.
  static Future<void> _applyPragmas(Database db) async {
    try {
      final rows = await db.rawQuery('PRAGMA journal_mode=WAL');
      final mode = rows.isEmpty ? '' : '${rows.first.values.first}';
      if (mode.toLowerCase() != 'wal') {
        DevLog.write('V16DB', 'journal_mode is "$mode" (expected wal)');
      }
    } catch (e) {
      DevLog.write('V16DB', 'WAL not enabled ($e)');
    }
    try {
      final rows = await db.rawQuery('PRAGMA busy_timeout=5000');
      final value = rows.isEmpty ? '' : '${rows.first.values.first}';
      if (value != '5000') {
        DevLog.write('V16DB', 'busy_timeout is "$value" (expected 5000)');
      }
    } catch (e) {
      DevLog.write('V16DB', 'busy_timeout not set ($e)');
    }
    try {
      final rows = await db.rawQuery('PRAGMA synchronous=NORMAL');
      // Touch the cursor so the statement is actually executed.
      if (rows.isNotEmpty) rows.first.values.first;
    } catch (e) {
      DevLog.write('V16DB', 'synchronous not set ($e)');
    }
  }

  /// Insert or merge a history record.
  ///
  /// When [restoreDeleted] is true, merging will clear the isDeleted flag,
  /// restoring soft-deleted records. This should only be true for rebuild
  /// operations **and for user-initiated saves** (the user asked for this post
  /// to be saved again, so a record they had deleted must come back). Recovery
  /// paths (startup, batch adoption) keep the deletion state.
  Future<void> upsert(HistoryRecord record, {
    bool restoreDeleted = false,
    bool userSave = false,
    int? downloadStartedAt,
    String source = 'unspecified',
  }) async {
    validateHistoryFiles(record.files);
    DevLog.write(
      'HIST', // i18n:ignore 日志
      'history write post=${record.postId} files=${record.files.length} '
      'restoreDeleted=$restoreDeleted',
    );
    final writtenCount = await _db.transaction<int?>((txn) async {
      if (downloadStartedAt != null) {
        final barriers = await txn.query('download_delete_barriers',
          where: 'platform = ? AND post_id = ?', whereArgs: [record.platform, record.postId]);
        if (barriers.isNotEmpty && (barriers.first['deleted_at'] as int) >= downloadStartedAt) return null;
      }
      final existing = await _getByPostUrl(txn, record.postUrl) ??
          await _getByPostId(txn, record.postId);
      if (existing != null) {
        final recordByMediaId = <String, HistoryFile>{
          for (final f in record.files)
            if (f.mediaId != null && f.mediaId!.isNotEmpty) f.mediaId!: f,
        };

        final fileMap = <String, HistoryFile>{};
        for (final f in existing.files) {
          if (f.mediaId != null && recordByMediaId.containsKey(f.mediaId)) {
            continue;
          }
          fileMap['${f.itemIndex}_${f.isImage}'] = f;
        }
        for (final f in record.files) {
          fileMap['${f.itemIndex}_${f.isImage}'] = f;
        }
        final sortedFiles = fileMap.values.toList()
          ..sort((a, b) {
            final cmp = a.itemIndex.compareTo(b.itemIndex);
            if (cmp != 0) return cmp;
            return (a.isImage ? 0 : 1).compareTo(b.isImage ? 0 : 1);
          });
        // An inferred 0-based row can already be stored next to the 1-based row
        // written with the real provenance; collapse them before persisting.
        final mergedFiles = repairHistoryFiles(sortedFiles) ?? sortedFiles;
        validateHistoryFiles(mergedFiles);

        final resolvedCreatedAt = restoreDeleted && userSave && existing.isDeleted
            ? record.createdAt
            : record.createdAt.isBefore(existing.createdAt)
            ? record.createdAt
            : existing.createdAt;

        final mergedRecord = HistoryRecord(
          id: existing.id,
          platform: record.platform,
          platformDisplayName: record.platformDisplayName ?? existing.platformDisplayName,
          postId: record.postId,
          authorName: record.authorName?.trim().isNotEmpty == true ? record.authorName : existing.authorName,
          title: (record.title?.isNotEmpty == true) ? record.title : existing.title,
          caption: (record.caption?.isNotEmpty == true) ? record.caption : existing.caption,
          aiLabel: record.aiLabel?.trim().isNotEmpty == true ? record.aiLabel : existing.aiLabel,
          aiLabelSource: record.aiLabelSource?.trim().isNotEmpty == true ? record.aiLabelSource : existing.aiLabelSource,
          thumbnailUrl: record.thumbnailUrl ?? existing.thumbnailUrl,
          postUrl: record.postUrl,
          fileCount: mergedFiles.length,
          createdAt: resolvedCreatedAt,
          itemsJson: record.itemsJson ?? existing.itemsJson,
          files: mergedFiles,
          // Only restore deleted records when explicitly requested (rebuild flow)
          isDeleted: restoreDeleted ? false : existing.isDeleted,
        );
        await txn.update(
          'history_records',
          mergedRecord.toMap(),
          where: 'id = ?',
          whereArgs: [existing.id],
        );
        return mergedFiles.length;
      }

      await txn.insert(
        'history_records',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return record.files.length;
    });
    if (writtenCount != null) {
      DevLog.write('HIST', 'file rows written source=$source post=${record.postId} count=$writtenCount');
    }
    notifyChanged('upsert post=${record.postId}');
  }


  /// Refresh only metadata of an existing record; never restore deletion or
  /// change its saved time merely because a preview was opened.
  Future<ParsedPost> mergeParsedPost(ParsedPost fresh) async {
    final old = await getByPostUrl(fresh.url) ?? await getByPostId(fresh.id);
    if (old == null) return fresh;
    String? nonempty(String? value, String? fallback) =>
        value?.trim().isNotEmpty == true ? value : fallback;
    final oldPost = old.toPost();
    final merged = ParsedPost(platform: fresh.platform, id: fresh.id, url: fresh.url,
      author: PostAuthor(name: nonempty(fresh.author.name, old.authorName), id: fresh.author.id),
      items: fresh.items.isNotEmpty ? fresh.items : oldPost.items,
      title: nonempty(fresh.title, old.title), caption: nonempty(fresh.caption, old.caption),
      publishedAt: fresh.publishedAt,
      aiLabel: fresh.aiLabel?.text.trim().isNotEmpty == true ? fresh.aiLabel : oldPost.aiLabel);
    await _db.update('history_records', {
      'author_name': merged.author.name, 'title': merged.title, 'caption': merged.caption,
      'ai_label': merged.aiLabel?.text, 'ai_label_source': merged.aiLabel?.source,
      if (fresh.items.isNotEmpty) 'items_json': jsonEncode([for (final item in fresh.items) item.toJson()]),
    }, where: 'id = ?', whereArgs: [old.id]);
    notifyChanged('metadata refreshed');
    return merged;
  }

  Future<void> updateFiles(int id, List<HistoryFile> files, {String source = 'unspecified'}) async {
    validateHistoryFiles(files);
    final normalized = repairHistoryFiles(files) ?? files;
    final records = await _db.query(
      'history_records', columns: ['post_id'], where: 'id = ?', whereArgs: [id], limit: 1,
    );
    final rows = await _db.update(
      'history_records',
      {
        'files_json': jsonEncode([for (final f in normalized) f.toMap()]),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows > 0 && records.isNotEmpty) {
      DevLog.write('HIST', 'file rows written source=$source post=${records.first['post_id']} count=${normalized.length}');
    }
    notifyChanged('updateFiles id=$id rows=$rows');
  }

  /// Apply scan results to the current database rows, not the snapshot that
  /// was read before the asynchronous album lookup.
  Future<List<HistoryFile>> syncScannedFiles(
    int id,
    List<HistoryFile> before,
    List<HistoryFile> scanned,
  ) async {
    if (before.length != scanned.length) {
      throw ArgumentError('Scan results must match the input file list');
    }
    final result = await _db.transaction((txn) async {
      final rows = await txn.query(
        'history_records', where: 'id = ?', whereArgs: [id], limit: 1,
      );
      if (rows.isEmpty) throw StateError('History record no longer exists');
      final record = HistoryRecord.fromMap(rows.first);
      final changes = <String, (HistoryFile, HistoryFile)>{};
      for (var i = 0; i < before.length; i++) {
        final old = before[i], updated = scanned[i];
        if (old.itemIndex != updated.itemIndex || old.isImage != updated.isImage) {
          throw ArgumentError('Scan cannot change file identity');
        }
        changes['${old.itemIndex}_${old.isImage}'] = (old, updated);
      }
      final merged = <HistoryFile>[];
      final claimedMediaIds = record.files
          .map((file) => file.mediaId)
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toSet();
      for (final current in record.files) {
        final change = changes['${current.itemIndex}_${current.isImage}'];
        final proposedId = change?.$2.mediaId;
        if (change == null ||
            current.filename != change.$1.filename ||
            current.mediaId != change.$1.mediaId ||
            current.assetId != change.$1.assetId ||
            (proposedId != null && proposedId.isNotEmpty &&
                proposedId != current.mediaId && claimedMediaIds.contains(proposedId))) {
          merged.add(current);
        } else {
          if (proposedId != null && proposedId.isNotEmpty) claimedMediaIds.add(proposedId);
          merged.add(current.copyWith(
            mediaId: change.$2.mediaId,
            status: change.$2.status,
            relativePath: change.$2.relativePath,
          ));
        }
      }
      final repaired = repairHistoryFiles(merged) ?? merged;
      validateHistoryFiles(repaired);
      final encoded = jsonEncode([for (final file in repaired) file.toMap()]);
      final changed = encoded != rows.first['files_json'];
      if (changed) {
        await txn.update('history_records', {'files_json': encoded},
          where: 'id = ?', whereArgs: [id]);
      }
      return (files: repaired, postId: record.postId, changed: changed);
    });
    if (result.changed) {
      DevLog.write('HIST', 'file rows written source=gallery-scan post=${result.postId} count=${result.files.length}');
      notifyChanged('gallery scan post=${result.postId}');
    }
    return result.files;
  }

  /// Rewrite one stored record whose `files_json` still carries the 0-based or
  /// duplicated rows left by the old inference path. Only the database row
  /// changes: no album file is deleted, renamed or rewritten.
  Future<HistoryRecord> _persistFileRepair(HistoryRecord record) async {
    final id = record.id;
    if (id == null) return record;
    while (_activeFileRepair != null) {
      await _activeFileRepair;
    }
    final finished = Completer<void>();
    _activeFileRepair = finished.future;
    try {
      final result = await _db.transaction((txn) async {
        final rows = await txn.query('history_records', where: 'id = ?', whereArgs: [id], limit: 1);
        if (rows.isEmpty) return (record: record, deleted: 0, updated: 0, verified: false);
        final row = rows.first;
        final raw = row['files_json'] as String?;
        if (!historyFilesNeedRepair(raw)) {
          return (record: HistoryRecord.fromMap(row), deleted: 0, updated: 0, verified: false);
        }
        final decoded = jsonDecode(raw!) as List;
        final files = [
          for (final item in decoded)
            if (item is Map) HistoryFile.fromMap(item.cast<String, Object?>()),
        ];
        final repaired = repairHistoryFiles(files)!;
        final details = files.map((f) {
          final mediaId = f.mediaId;
          final safeId = mediaId != null && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(mediaId) ? mediaId : '-';
          return 'index=${f.itemIndex},mediaId=$safeId,assetId=${f.assetId != null && f.assetId!.isNotEmpty ? 1 : 0}';
        }).join(';');
        DevLog.write('HIST', 'file rows before repair post=${record.postId} count=${files.length} rows=[$details]');
        final updated = await txn.update(
          'history_records',
          {'files_json': jsonEncode([for (final f in repaired) f.toMap()])},
          where: 'id = ?',
          whereArgs: [id],
        );
        final verifiedRows = await txn.query('history_records', where: 'id = ?', whereArgs: [id], limit: 1);
        final verifiedJson = verifiedRows.first['files_json'] as String;
        final verifiedCount = (jsonDecode(verifiedJson) as List).length;
        if (updated != 1 || verifiedCount != repaired.length || historyFilesNeedRepair(verifiedJson)) {
          throw StateError('History file repair verification failed');
        }
        return (record: HistoryRecord.fromMap(verifiedRows.first), deleted: files.length - repaired.length, updated: updated, verified: true);
      });
      if (result.verified) {
        DevLog.write('HIST', 'file rows repaired post=${record.postId} kept=${result.record.files.length} deleted=${result.deleted} updated=${result.updated} committed=1 verified=1');
        DevLog.write('HIST', 'file rows written source=repair post=${record.postId} count=${result.record.files.length}');
        notifyChanged('file repair post=${record.postId}');
      }
      return result.record;
    } catch (error) {
      DevLog.write('HIST', 'file repair failed post=${record.postId} committed=0 exception=${error.runtimeType}', level: DevLogLevel.error);
      rethrow;
    } finally {
      _activeFileRepair = null;
      finished.complete();
    }
  }

  Future<HistoryRecord?> getByPostUrl(String postUrl) async {
    final record = await _getByPostUrl(_db, postUrl);
    if (record == null) return null;
    return _persistFileRepair(record);
  }

  Future<HistoryRecord?> getByPostId(String postId) async {
    final record = await _getByPostId(_db, postId);
    if (record == null) return null;
    return _persistFileRepair(record);
  }

  static Future<HistoryRecord?> _getByPostUrl(
    DatabaseExecutor db,
    String postUrl,
  ) async {
    final rows = await db.query(
      'history_records',
      where: 'post_url = ?',
      whereArgs: [postUrl],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return HistoryRecord.fromMap(rows.first);
  }

  static Future<HistoryRecord?> _getByPostId(
    DatabaseExecutor db,
    String postId,
  ) async {
    final rows = await db.query(
      'history_records',
      where: 'LOWER(post_id) = LOWER(?)',
      whereArgs: [postId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return HistoryRecord.fromMap(rows.first);
  }

  /// Find a history record matching a link (by postId, canonical URL, or resolved URL).
  Future<void> rememberParsedLink(String link, ParsedPost post) async {
    final uri = Uri.tryParse(link);
    final site = SiteRegistry.current.byId(post.platform);
    if (uri == null || site?.shortLink(uri) == null) return;
    await _db.insert('resolved_post_links', {'link_key': linkKey(link), 'platform': post.platform, 'post_id': post.id},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<HistoryRecord?> findRecordByLink(
    String link, {
    String? resolvedUrl,
  }) async {
    final aliases = await _db.query('resolved_post_links', where: 'link_key = ?', whereArgs: [linkKey(link)], limit: 1);
    if (aliases.isNotEmpty) {
      final record = await getByPostId(aliases.first['post_id'] as String);
      if (record != null && !record.isDeleted && record.platform == aliases.first['platform']) return record;
    }
    final id = postIdOfUrl(link) ??
        (resolvedUrl != null ? postIdOfUrl(resolvedUrl) : null);
    if (id != null) {
      final rec = await getByPostId(id);
      if (rec != null && !rec.isDeleted) return rec;
    }
    final byUrl = await getByPostUrl(link.trim());
    if (byUrl != null && !byUrl.isDeleted) return byUrl;

    if (resolvedUrl != null && resolvedUrl.trim().isNotEmpty) {
      final byResUrl = await getByPostUrl(resolvedUrl.trim());
      if (byResUrl != null && !byResUrl.isDeleted) return byResUrl;
    }

    final key = linkKey(link);
    final resKey = resolvedUrl != null ? linkKey(resolvedUrl) : null;
    final all = await recent(limit: 50);
    for (final r in all) {
      final rKey = linkKey(r.postUrl);
      if (rKey == key || (resKey != null && rKey == resKey)) {
        return r;
      }
    }
    return null;
  }

  Future<List<HistoryRecord>> recent({int limit = 50}) async {
    final rows = await _db.query(
      'history_records',
      where: 'is_deleted = 0',
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    final records = <HistoryRecord>[];
    for (final row in rows) {
      final record = HistoryRecord.fromMap(row);
      records.add(historyFilesNeedRepair(row['files_json'] as String?)
          ? await _persistFileRepair(record)
          : record);
    }
    return records;
  }

  Future<void> delete(int id) async {
    // Soft delete: mark as deleted instead of removing. The row count is logged
    // because a caller passing an id that does not exist silently changes
    // nothing — that used to look like "the list did not refresh".
    final rows = await _db.transaction((txn) async {
      final records = await txn.query('history_records', columns: ['platform', 'post_id'], where: 'id = ?', whereArgs: [id]);
      if (records.isNotEmpty) await txn.insert('download_delete_barriers', {
        'platform': records.first['platform'], 'post_id': records.first['post_id'],
        'deleted_at': DateTime.now().microsecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return txn.update('history_records', {'is_deleted': 1}, where: 'id = ?', whereArgs: [id]);
    });
    notifyChanged('delete id=$id rows=$rows');
  }

  Future<void> permanentlyDelete(int id) async {
    // Hard delete only used for testing or cleanup
    final rows =
        await _db.delete('history_records', where: 'id = ?', whereArgs: [id]);
    notifyChanged('permanentlyDelete id=$id rows=$rows');
  }

  Future<void> clear() async {
    final rows = await _db.delete('history_records');
    notifyChanged('clear rows=$rows');
  }

  /// Read all non-deleted records in a single read transaction for backup export.
  Future<List<HistoryRecord>> getAllActiveForBackup() async {
    return _db.transaction((txn) async {
      final rows = await txn.query(
        'history_records',
        where: 'is_deleted = 0',
        orderBy: 'created_at ASC, id ASC',
      );
      return rows.map(HistoryRecord.fromMap).toList();
    });
  }

  /// Total count of non-deleted records.
  Future<int> countActive() async {
    final result = await _db.rawQuery(
      'SELECT COUNT(*) as count FROM history_records WHERE is_deleted = 0',
    );
    return (result.first['count'] as num?)?.toInt() ?? 0;
  }

  /// Bring a record back after an undo.
  ///
  /// Only the undo affordance may call this: it clears the soft-delete flag by
  /// design. Recovery paths (batch adoption, startup backfill) must go through
  /// [upsert] with `restoreDeleted: false` instead, so a record the user
  /// deleted does not come back by itself. [reason] shows up in the device log
  /// to make that distinction visible.
  Future<void> reinsert(HistoryRecord record, {String reason = 'undo'}) async {
    final id = await _db.insert(
      'history_records',
      record.toMap()
        ..remove('id')
        ..['is_deleted'] = 0,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyChanged('reinsert ($reason) post=${record.postId} id=$id');
  }
}

/// A stored thumbnail pointing at a video file (mp4 etc.) can never render
/// in an image widget: feeding it to Image.network downloads megabytes of
/// video into the image pipeline and freezes the list. Resolve the display
/// thumbnail defensively: stored poster first, then the embedded items.
String? displayThumbnail(HistoryRecord record) {
  if (record.itemsJson != null) {
    try {
      final decoded = jsonDecode(record.itemsJson!) as List;
      String? firstImage;
      for (final raw in decoded) {
        final map = (raw as Map).cast<String, Object?>();
        final type = map['type'] as String?;
        if (type == 'video' && map['posterUrl'] is String) {
          return map['posterUrl'] as String;
        }
        if (type == 'image' && firstImage == null) {
          firstImage = map['url'] as String?;
        }
      }
      if (firstImage != null) return firstImage;
    } catch (_) {
      // Fall through to the stored thumbnail.
    }
  }
  final stored = record.thumbnailUrl;
  if (stored != null && !_looksLikeVideo(stored)) return stored;
  return null;
}

bool _looksLikeVideo(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  return path.endsWith('.mp4') ||
      path.endsWith('.mov') ||
      path.endsWith('.webm') ||
      path.endsWith('.m3u8');
}
