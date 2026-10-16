// Download history stored in a local sqflite table.

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

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
  });

  final String filename;
  final int savedAt;
  final String? mediaId;
  final FileStatus status;
  final int itemIndex;
  final bool isImage;

  Map<String, Object?> toMap() => {
    'filename': filename,
    'saved_at': savedAt,
    'media_id': mediaId,
    'status': status.name,
    'item_index': itemIndex,
    'is_image': isImage ? 1 : 0,
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
  );

  HistoryFile copyWith({
    String? filename,
    int? savedAt,
    String? mediaId,
    FileStatus? status,
    int? itemIndex,
    bool? isImage,
  }) => HistoryFile(
    filename: filename ?? this.filename,
    savedAt: savedAt ?? this.savedAt,
    mediaId: mediaId ?? this.mediaId,
    status: status ?? this.status,
    itemIndex: itemIndex ?? this.itemIndex,
    isImage: isImage ?? this.isImage,
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
  };

  static HistoryRecord fromMap(Map<String, Object?> map) {
    final postId = map['post_id'] as String;
    final authorName = map['author_name'] as String?;
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      (map['created_at'] as num).toInt(),
    );
    final itemsJson = map['items_json'] as String?;
    final filesJsonStr = map['files_json'] as String?;

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
    );
  }
}

class HistoryDb {
  HistoryDb._(this._db);

  final Database _db;
  static HistoryDb? _instance;

  static void resetInstanceForTesting() {
    _instance = null;
  }

  static Future<HistoryDb> instance({String? dbPath}) async {
    if (dbPath == null) {
      final existing = _instance;
      if (existing != null) return existing;
    }
    final path = dbPath ?? '${await getDatabasesPath()}/easysave_history.db';
    final db = await openDatabase(
      path,
      version: 2,
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
        'files_json TEXT)',
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
      },
    );
    final historyDb = HistoryDb._(db);
    if (dbPath == null) _instance = historyDb;
    return historyDb;
  }

  Future<void> upsert(HistoryRecord record) async {
    await _db.insert(
      'history_records',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateFiles(int id, List<HistoryFile> files) async {
    await _db.update(
      'history_records',
      {
        'files_json': jsonEncode([for (final f in files) f.toMap()]),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<HistoryRecord?> getByPostUrl(String postUrl) async {
    final rows = await _db.query(
      'history_records',
      where: 'post_url = ?',
      whereArgs: [postUrl],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return HistoryRecord.fromMap(rows.first);
  }

  Future<HistoryRecord?> getByPostId(String postId) async {
    final rows = await _db.query(
      'history_records',
      where: 'post_id = ?',
      whereArgs: [postId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return HistoryRecord.fromMap(rows.first);
  }

  Future<List<HistoryRecord>> recent({int limit = 50}) async {
    final rows = await _db.query(
      'history_records',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(HistoryRecord.fromMap).toList();
  }

  Future<void> delete(int id) async {
    await _db.delete('history_records', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clear() async {
    await _db.delete('history_records');
  }

  Future<void> reinsert(HistoryRecord record) async {
    await _db.insert(
      'history_records',
      record.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
