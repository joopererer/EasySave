// Download history stored in a local sqflite table.

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

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
  });

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
  };

  static HistoryRecord fromMap(Map<String, Object?> map) => HistoryRecord(
    id: map['id'] as int?,
    platform: map['platform'] as String,
    postId: map['post_id'] as String,
    authorName: map['author_name'] as String?,
    title: map['title'] as String?,
    caption: map['caption'] as String?,
    thumbnailUrl: map['thumbnail_url'] as String?,
    postUrl: map['post_url'] as String,
    fileCount: (map['file_count'] as num).toInt(),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (map['created_at'] as num).toInt(),
    ),
    itemsJson: map['items_json'] as String?,
  );
}

class HistoryDb {
  HistoryDb._(this._db);

  final Database _db;
  static HistoryDb? _instance;

  static Future<HistoryDb> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final db = await openDatabase(
      '${await getDatabasesPath()}/easysave_history.db',
      version: 1,
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
        'items_json TEXT)',
      ),
    );
    return _instance = HistoryDb._(db);
  }

  Future<void> upsert(HistoryRecord record) async {
    await _db.insert(
      'history_records',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
