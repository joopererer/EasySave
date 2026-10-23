// Download history stored in a local sqflite table.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import 'clipboard_guard.dart';

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
    this.itemIndex = 0,
    this.isImage = true,
    this.assetId,
    this.relativePath,
  });

  final String filename;
  final int savedAt;
  final String? mediaId;
  final FileStatus status;
  final int itemIndex;
  final bool isImage;
  
  /// Provenance asset ID (prov:assetId). Stored in files_json for reuse
  /// when re-downloading the same file across devices.
  final String? assetId;

  /// MediaStore RELATIVE_PATH (e.g. Pictures/EasySave/).
  /// May be null for older records before first gallery location.
  final String? relativePath;

  Map<String, Object?> toMap() => {
    'filename': filename,
    'saved_at': savedAt,
    'media_id': mediaId,
    'status': status.name,
    'item_index': itemIndex,
    'is_image': isImage ? 1 : 0,
    'asset_id': assetId,
    'relative_path': relativePath,
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
  }) => HistoryFile(
    filename: filename ?? this.filename,
    savedAt: savedAt ?? this.savedAt,
    mediaId: mediaId ?? this.mediaId,
    status: status ?? this.status,
    itemIndex: itemIndex ?? this.itemIndex,
    isImage: isImage ?? this.isImage,
    assetId: assetId ?? this.assetId,
    relativePath: relativePath ?? this.relativePath,
  );
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
            itemIndex: i,
            isImage: true,
          ),
        );
        files.add(
          HistoryFile(
            filename: '$base.mp4',
            savedAt: createdAt.millisecondsSinceEpoch,
            status: FileStatus.unknown,
            itemIndex: i,
            isImage: false,
          ),
        );
      } else if (type == 'video') {
        files.add(
          HistoryFile(
            filename: '$base.mp4',
            savedAt: createdAt.millisecondsSinceEpoch,
            status: FileStatus.unknown,
            itemIndex: i,
            isImage: false,
          ),
        );
      } else {
        files.add(
          HistoryFile(
            filename: '$base.jpg',
            savedAt: createdAt.millisecondsSinceEpoch,
            status: FileStatus.unknown,
            itemIndex: i,
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
    required this.postId,
    this.authorName,
    this.title,
    this.caption,
    this.thumbnailUrl,
    required this.postUrl,
    required this.fileCount,
    required this.createdAt,
    this.itemsJson,
    List<HistoryFile>? files,
    this.isDeleted = false,
  }) : files = files ?? const [];

  final int? id;
  final String platform;
  final String postId;
  final String? authorName;
  final String? title;
  final String? caption;
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
      for (final f in files) {
        items.add(
          MediaItem(
            type: f.isImage ? 'image' : 'video',
            url: '',
          ),
        );
      }
    }
    return ParsedPost(
      platform: platform,
      id: postId,
      url: postUrl,
      author: PostAuthor(name: authorName),
      items: items,
      title: title,
      caption: caption,
    );
  }

  Map<String, Object?> toMap() => {
    'platform': platform,
    'post_id': postId,
    'author_name': authorName,
    'title': title,
    'caption': caption,
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
    }

    return HistoryRecord(
      id: map['id'] as int?,
      platform: map['platform'] as String,
      postId: postId,
      authorName: authorName,
      title: map['title'] as String?,
      caption: map['caption'] as String?,
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
      version: 3,
      // Two engines (main UI isolate + background isolate) can hold a
      // connection to the same file. WAL lets readers work while a writer is
      // active, and busy_timeout makes a writer wait for the lock instead of
      // failing with SQLITE_BUSY.
      onConfigure: (db) => _applyPragmas(db),
      onOpen: (db) => _applyPragmas(db),
      onCreate: (db, version) => db.execute(
        'CREATE TABLE history_records('
        'id INTEGER PRIMARY KEY AUTOINCREMENT,'
        'platform TEXT NOT NULL,'
        'post_id TEXT NOT NULL,'
        'author_name TEXT,'
        'title TEXT,'
        'caption TEXT,'
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
          }
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE history_records ADD COLUMN is_deleted INTEGER DEFAULT 0');
        }
        // Future migrations go here
      },
    );
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
  Future<void> upsert(HistoryRecord record, {bool restoreDeleted = false}) async {
    DevLog.write(
      'HIST', // i18n:ignore 日志
      'history write post=${record.postId} files=${record.files.length} '
      'restoreDeleted=$restoreDeleted',
    );
    await _db.transaction((txn) async {
      final existing = await _getByPostUrl(txn, record.postUrl) ??
          await _getByPostId(txn, record.postId);
      if (existing != null) {
        final fileMap = <String, HistoryFile>{};
        for (final f in existing.files) {
          fileMap['${f.itemIndex}_${f.isImage}'] = f;
        }
        for (final f in record.files) {
          fileMap['${f.itemIndex}_${f.isImage}'] = f;
        }
        final mergedFiles = fileMap.values.toList()
          ..sort((a, b) {
            final cmp = a.itemIndex.compareTo(b.itemIndex);
            if (cmp != 0) return cmp;
            return (a.isImage ? 0 : 1).compareTo(b.isImage ? 0 : 1);
          });

        final resolvedCreatedAt = record.createdAt.isBefore(existing.createdAt)
            ? record.createdAt
            : existing.createdAt;

        final mergedRecord = HistoryRecord(
          id: existing.id,
          platform: record.platform,
          postId: record.postId,
          authorName: record.authorName ?? existing.authorName,
          title: (record.title?.isNotEmpty == true) ? record.title : existing.title,
          caption: (record.caption?.isNotEmpty == true) ? record.caption : existing.caption,
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
        return;
      }

      await txn.insert(
        'history_records',
        record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    notifyChanged('upsert post=${record.postId}');
  }

  Future<void> updateFiles(int id, List<HistoryFile> files) async {
    final rows = await _db.update(
      'history_records',
      {
        'files_json': jsonEncode([for (final f in files) f.toMap()]),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyChanged('updateFiles id=$id rows=$rows');
  }

  Future<HistoryRecord?> getByPostUrl(String postUrl) async =>
      _getByPostUrl(_db, postUrl);

  Future<HistoryRecord?> getByPostId(String postId) async =>
      _getByPostId(_db, postId);

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
  Future<HistoryRecord?> findRecordByLink(
    String link, {
    String? resolvedUrl,
  }) async {
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
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(HistoryRecord.fromMap).toList();
  }

  Future<void> delete(int id) async {
    // Soft delete: mark as deleted instead of removing. The row count is logged
    // because a caller passing an id that does not exist silently changes
    // nothing — that used to look like "the list did not refresh".
    final rows = await _db.update(
      'history_records',
      {'is_deleted': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
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
        orderBy: 'created_at ASC',
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
