// Batch downloads through background_downloader: true background work,
// per-file status, auto-retry and kill-recovery. Gallery import still goes
// through gal, and batch snapshots live in SharedPreferences.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gal/gal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';
import 'gallery_locator_service.dart';
import 'history_db.dart';
import 'parse_service.dart';
import 'saver.dart';
import 'update_service.dart';


/// Max download attempts per file, first try included. The plugin's native
/// retries stay at 0 so this counter is the single source of truth.
const int kMaxAttempts = 3;

enum JobState { queued, active, done, failed, canceled }

class DownloadJob {
  DownloadJob({
    required this.key,
    required this.label,
    required this.filename,
    required this.urls,
    required this.isImage,
    required this.itemIndex,
  });

  final String key;
  final String label;
  final String filename;
  List<String> urls;
  final bool isImage;
  final int itemIndex;

  JobState state = JobState.queued;
  double progress = 0;
  int attempts = 0;
  String? currentTaskId;
  bool saved = false;
  String? error;
  int? lastStatusCode;

  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    'filename': filename,
    'urls': urls,
    'isImage': isImage,
    'itemIndex': itemIndex,
    'state': state.index,
    'attempts': attempts,
    'currentTaskId': currentTaskId,
    'saved': saved,
    'error': error,
    'lastStatusCode': lastStatusCode,
  };

  static DownloadJob fromJson(Map<String, Object?> map) {
    final job = DownloadJob(
      key: map['key'] as String,
      label: map['label'] as String,
      filename: map['filename'] as String,
      urls: (map['urls'] as List).cast<String>(),
      isImage: map['isImage'] as bool,
      itemIndex: (map['itemIndex'] as num).toInt(),
    );
    job.state = JobState.values[(map['state'] as num).toInt()];
    job.attempts = (map['attempts'] as num).toInt();
    job.currentTaskId = map['currentTaskId'] as String?;
    job.saved = map['saved'] as bool? ?? false;
    job.error = map['error'] as String?;
    job.lastStatusCode = (map['lastStatusCode'] as num?)?.toInt();
    return job;
  }
}

class DownloadBatch {
  DownloadBatch({
    required this.batchId,
    required this.album,
    required this.postUrl,
    required this.platform,
    required this.postId,
    this.authorName,
    this.title,
    this.caption,
    this.itemsJson,
    required this.jobs,
  });

  final String batchId;
  final String album;
  final String postUrl;
  final String platform;
  final String postId;
  final String? authorName;
  final String? title;
  final String? caption;
  final String? itemsJson;
  final List<DownloadJob> jobs;
  bool historyWritten = false;

  bool get isTerminal => jobs.every(
    (j) =>
        j.state == JobState.done ||
        j.state == JobState.failed ||
        j.state == JobState.canceled,
  );

  int get succeeded => jobs.where((j) => j.state == JobState.done).length;

  Map<String, Object?> toJson() => {
    'batchId': batchId,
    'album': album,
    'postUrl': postUrl,
    'platform': platform,
    'postId': postId,
    'authorName': authorName,
    'title': title,
    'caption': caption,
    'itemsJson': itemsJson,
    'jobs': [for (final j in jobs) j.toJson()],
    'historyWritten': historyWritten,
  };

  static DownloadBatch fromJson(Map<String, Object?> map) => DownloadBatch(
    batchId: map['batchId'] as String,
    album: map['album'] as String,
    postUrl: map['postUrl'] as String,
    platform: map['platform'] as String,
    postId: map['postId'] as String,
    authorName: map['authorName'] as String?,
    title: map['title'] as String?,
    caption: map['caption'] as String?,
    itemsJson: map['itemsJson'] as String?,
    jobs: (map['jobs'] as List)
        .map((e) => DownloadJob.fromJson((e as Map).cast<String, Object?>()))
        .toList(),
  )..historyWritten = map['historyWritten'] as bool? ?? false;
}

/// One downloadable file derived from the selection. Pure function so the
/// URL rotation and naming stay unit-testable without native plugins.
class PlannedFile {
  PlannedFile({
    required this.label,
    required this.urls,
    required this.filename,
    required this.isImage,
    required this.itemIndex,
  });

  final String label;
  final List<String> urls;
  final String filename;
  final bool isImage;
  final int itemIndex;
}

List<PlannedFile> planFiles(
  ParsedPost post,
  List<int> selected,
  String Function(String label, int seq, String ext) nameFor,
) {
  final planned = <PlannedFile>[];
  final counters = <String, int>{};
  String nextLabel(String kind) {
    final n = (counters[kind] ?? 0) + 1;
    counters[kind] = n;
    return '$kind $n';
  }

  for (final index in selected) {
    final item = post.items[index];
    final seq = index + 1;
    // Display order: CDN originals first (the rewritten ci primary is
    // occasionally slow/unreachable from mobile networks); ci stays last
    // as a fallback so nothing is lost when only it serves the bytes.
    final imageUrls = [...item.fallbacks, item.url];
    if (item.type == 'live' && item.videoUrl != null) {
      final base = nextLabel('Live');
      planned.add(
        PlannedFile(
          label: base,
          urls: imageUrls,
          filename: '${nameFor(base, seq, 'jpg')}.jpg',
          isImage: true,
          itemIndex: index,
        ),
      );
      planned.add(
        PlannedFile(
          label: base,
          urls: [item.videoUrl!],
          filename: '${nameFor(base, seq, 'mp4')}.mp4',
          isImage: false,
          itemIndex: index,
        ),
      );
    } else if (item.type == 'video') {
      final label = nextLabel('视频');
      final url = item.videoUrl ?? item.url;
      planned.add(
        PlannedFile(
          label: label,
          urls: item.videoUrl != null ? [url, ...imageUrls] : imageUrls,
          filename: '${nameFor(label, seq, 'mp4')}.mp4',
          isImage: false,
          itemIndex: index,
        ),
      );
    } else {
      final label = nextLabel('图片');
      planned.add(
        PlannedFile(
          label: label,
          urls: imageUrls,
          filename: '${nameFor(label, seq, 'jpg')}.jpg',
          isImage: true,
          itemIndex: index,
        ),
      );
    }
  }
  return planned;
}

class DownloadManager extends ChangeNotifier {
  DownloadManager._();

  static final DownloadManager instance = DownloadManager._();

  final Map<String, DownloadBatch> _batches = {};
  StreamSubscription<TaskUpdate>? _updatesSub;
  bool _ready = false;

  final _notifications = FlutterLocalNotificationsPlugin();
  static const _channelId = 'easysave_downloads';
  final Map<String, int> _lastShownPercent = {};

  // Retained: dropping the broadcast subscription would stop updates.
  Future<void> close() async {
    await _updatesSub?.cancel();
    _updatesSub = null;
  }

  DownloadBatch? get currentBatch =>
      _batches.isEmpty ? null : _batches.values.last;

  DownloadBatch? batchById(String batchId) => _batches[batchId];

  static String _batchKey(String batchId) => 'easysave_batch_$batchId';
  static const _batchIndexKey = 'easysave_batches';

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    await FileDownloader().start();
    try {
      await _notifications.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      await _notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              '下载进度',
              importance: Importance.low,
            ),
          );
    } catch (_) {
      // Notifications are best effort; downloads run regardless.
    }
    _updatesSub = FileDownloader().updates.listen(_onUpdate);
    await _loadAndReconcile();
  }

  int _notificationId(DownloadBatch batch) =>
      batch.batchId.hashCode & 0x7fffffff;

  /// Single merged notification per batch with byte-level percent.
  Future<void> _refreshNotification(DownloadBatch batch) async {
    final active = [
      for (final j in batch.jobs)
        if (j.state != JobState.canceled) j,
    ];
    if (active.isEmpty) {
      await _cancelNotification(batch);
      return;
    }
    final done = batch.succeeded;
    final percent =
        (active.map((j) => j.progress).fold<double>(0, (a, b) => a + b) /
                active.length *
                100)
            .round()
            .clamp(0, 100);
    final terminal = batch.isTerminal;
    if (!terminal && _lastShownPercent[batch.batchId] == percent) return;
    _lastShownPercent[batch.batchId] = percent;
    try {
      if (terminal) {
        await _cancelNotification(batch);
        return;
      }
      await _notifications.show(
        id: _notificationId(batch),
        title: '正在下载 $done/${active.length}',
        body: '$percent%',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            '下载进度',
            showProgress: true,
            maxProgress: 100,
            progress: percent,
            ongoing: true,
            autoCancel: false,
            onlyAlertOnce: true,
          ),
        ),
      );
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _cancelNotification(DownloadBatch batch) async {
    _lastShownPercent.remove(batch.batchId);
    try {
      await _notifications.cancel(id: _notificationId(batch));
    } catch (_) {
      // Best effort.
    }
  }

  Future<DownloadBatch> startBatch(
    ParsedPost post,
    List<int> selected, {
    required String album,
    required String Function(String label, int seq, String ext) nameFor,
  }) async {
    await init();
    // Best effort: without the permission downloads still run, only the
    // notification progress is missing.
    try {
      await FileDownloader().permissions.request(PermissionType.notifications);
    } catch (_) {
      // Ignore: proceed without notifications.
    }
    if (!await Gal.hasAccess()) {
      final granted = await Gal.requestAccess();
      if (!granted) throw const FileSystemException('没有相册访问权限');
    }
    final batchId = DateTime.now().millisecondsSinceEpoch.toString();
    final planned = planFiles(post, selected, nameFor);
    final batch = DownloadBatch(
      batchId: batchId,
      album: album,
      postUrl: post.url,
      platform: post.platform,
      postId: post.id,
      authorName: post.author.name,
      title: post.title,
      caption: post.caption,
      itemsJson: jsonEncode([for (final item in post.items) item.toJson()]),
      jobs: [
        for (var i = 0; i < planned.length; i++)
          DownloadJob(
            key: '$batchId-$i',
            label: planned[i].label,
            filename: planned[i].filename,
            urls: planned[i].urls,
            isImage: planned[i].isImage,
            itemIndex: planned[i].itemIndex,
          ),
      ],
    );
    _batches[batchId] = batch;
    unawaited(_refreshNotification(batch));
    await _persist(batch);
    for (final job in batch.jobs) {
      await _enqueueAttempt(batch, job);
    }
    notifyListeners();
    return batch;
  }

  Map<String, String> _headersFor(String platform) {
    final manifestHeaders = ParserManager.instance.getPlatformHeaders(platform);
    final headers = <String, String>{
      'Referer': refererFor(platform),
      'User-Agent': 'Mozilla/5.0 (Linux; Android 10)',
    };
    if (manifestHeaders != null && manifestHeaders.isNotEmpty) {
      headers.addAll(manifestHeaders);
    }
    return headers;
  }


  Future<void> _enqueueAttempt(DownloadBatch batch, DownloadJob job) async {
    job.attempts++;
    final url = job.urls[(job.attempts - 1) % job.urls.length];
    final taskId = '${job.key}-try${job.attempts}';
    job.currentTaskId = taskId;
    job.state = job.attempts == 1 ? JobState.queued : JobState.active;
    job.error = null;
    final task = DownloadTask(
      taskId: taskId,
      url: url,
      filename: job.filename,
      headers: _headersFor(batch.platform),
      directory: 'easysave',
      baseDirectory: BaseDirectory.temporary,
      group: batch.batchId,
      updates: Updates.statusAndProgress,
      retries: 0,
      metaData: jsonEncode({
        'batchId': batch.batchId,
        'album': batch.album,
        'filename': job.filename,
        'label': job.label,
        'postUrl': batch.postUrl,
        'platform': batch.platform,
        'postId': batch.postId,
        'author': batch.authorName,
        'title': batch.title,
        'caption': batch.caption,
      }),
    );
    await _persist(batch);
    notifyListeners();
    await FileDownloader().enqueue(task);
  }

  void _onUpdate(TaskUpdate update) {
    final task = update.task;
    final batch = _batches[task.group];
    if (batch == null) return;
    DownloadJob? job;
    for (final j in batch.jobs) {
      if (j.currentTaskId == task.taskId) {
        job = j;
        break;
      }
    }
    if (job == null) return;
    if (update is TaskProgressUpdate) {
      if (update.progress >= 0) {
        job.state = JobState.active;
        job.progress = update.progress;
        notifyListeners();
        unawaited(_refreshNotification(batch));
      }
      return;
    }
    if (update is! TaskStatusUpdate) return;
    switch (update.status) {
      case TaskStatus.running:
        job.state = JobState.active;
        notifyListeners();
        unawaited(_refreshNotification(batch));
      case TaskStatus.complete:
        unawaited(_finishFile(batch, job, task));
      case TaskStatus.failed:
      case TaskStatus.notFound:
        job.lastStatusCode = update.responseStatusCode;
        unawaited(_failAttempt(batch, job, update));
      case TaskStatus.canceled:
        if (job.state != JobState.done) job.state = JobState.canceled;
        unawaited(_afterTerminal(batch));
      case TaskStatus.paused:
      case TaskStatus.enqueued:
      case TaskStatus.waitingToRetry:
        notifyListeners();
    }
  }

  /// Gallery import for a finished file, then temp cleanup.
  Future<void> _finishFile(
    DownloadBatch batch,
    DownloadJob job,
    Task task,
  ) async {
    final String path;
    try {
      path = await task.filePath();
    } catch (_) {
      job.error = '文件丢失，请重试';
      job.state = JobState.failed;
      await _persist(batch);
      notifyListeners();
      await _afterTerminal(batch);
      return;
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        job.error = '文件丢失，请重试';
        job.state = JobState.failed;
      } else {
        await saveToGallery(path, job.isImage, batch.album);
        job.state = JobState.done;
        job.progress = 1;
        job.saved = true;
      }
    } catch (e) {
      job.error = '$e';
      job.state = JobState.failed;
    }
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch);
  }

  Future<void> _failAttempt(
    DownloadBatch batch,
    DownloadJob job,
    TaskStatusUpdate update,
  ) async {
    if (job.attempts < kMaxAttempts) {
      await _enqueueAttempt(batch, job);
      return;
    }
    job.state = JobState.failed;
    job.error = update.responseStatusCode != null
        ? '下载失败（HTTP ${update.responseStatusCode}）'
        : (update.exception?.toString() ?? '下载失败');
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch);
  }

  Future<void> _afterTerminal(DownloadBatch batch) async {
    if (!batch.isTerminal) return;
    if (!batch.historyWritten) {
      batch.historyWritten = true;
      final thumb = _thumbnailFor(batch);
      final files = [
        for (final job in batch.jobs)
          if (job.saved && job.state == JobState.done)
            HistoryFile(
              filename: job.filename,
              savedAt: DateTime.now().millisecondsSinceEpoch,
              itemIndex: job.itemIndex,
              isImage: job.isImage,
              status: FileStatus.unknown,
            ),
      ];
      await HistoryDb.instance().then(
        (db) => db.upsert(
          HistoryRecord(
            platform: batch.platform,
            postId: batch.postId,
            authorName: batch.authorName,
            title: batch.title,
            caption: batch.caption,
            thumbnailUrl: thumb,
            postUrl: batch.postUrl,
            fileCount: batch.succeeded,
            createdAt: DateTime.now(),
            itemsJson: batch.itemsJson,
            files: files,
          ),
        ),
      );
      final locator = GalleryLocatorService.instance;
      if (locator.hasAccess) {
        unawaited(locator.scanAlbum(force: true));
      }
    }
    await _persist(batch);
    notifyListeners();
    unawaited(_refreshNotification(batch));
  }

  String? _thumbnailFor(DownloadBatch batch) {
    if (batch.itemsJson == null) return null;
    try {
      final decoded = jsonDecode(batch.itemsJson!) as List;
      String? firstImage;
      for (final raw in decoded) {
        final map = (raw as Map).cast<String, Object?>();
        if (map['type'] == 'video' && map['posterUrl'] is String) {
          return map['posterUrl'] as String;
        }
        if (map['type'] == 'image' && firstImage == null) {
          firstImage = map['url'] as String?;
        }
      }
      return firstImage;
    } catch (_) {
      return null;
    }
  }

  /// Manual per-row retry: re-parse the post first so 403/expired CDN links
  /// are refreshed; fall back to the stored URLs when parsing fails.
  Future<void> retryJob(DownloadBatch batch, DownloadJob job) async {
    if (job.state != JobState.failed) return;
    try {
      final outcome = await parsePostOutcome(batch.postUrl);
      final fresh = planFilesForItem(outcome.data, job.itemIndex);
      if (fresh != null && fresh.isNotEmpty) {
        job.urls = fresh;
      }
    } catch (_) {
      // Keep the stored URLs and try once more below.
    }
    job.attempts = 0;
    job.lastStatusCode = null;
    await _enqueueAttempt(batch, job);
  }

  Future<void> cancelBatch(DownloadBatch batch) async {
    final ids = [
      for (final job in batch.jobs)
        if (job.currentTaskId != null &&
            (job.state == JobState.queued || job.state == JobState.active))
          job.currentTaskId!,
    ];
    if (ids.isNotEmpty) {
      try {
        await FileDownloader().cancelTasksWithIds(ids);
      } catch (_) {
        // Best effort; terminal states arrive via updates anyway.
      }
    }
    for (final job in batch.jobs) {
      if (job.state == JobState.queued || job.state == JobState.active) {
        job.state = JobState.canceled;
      }
    }
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch);
  }

  /// Kill-recovery: finish gallery imports for tasks that completed while
  /// the app was dead, then write pending history records. Called on
  /// startup and when returning to the foreground.
  Future<void> reconcile() async {
    if (!_ready) {
      await init();
      return;
    }
    await _loadAndReconcile();
  }

  Future<void> _loadAndReconcile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final index = prefs.getStringList(_batchIndexKey) ?? [];
      var changed = false;
      for (final batchId in index) {
        final raw = prefs.getString(_batchKey(batchId));
        if (raw == null) continue;
        final batch = DownloadBatch.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
        );
        _batches[batchId] = batch;
        if (await _reconcileBatch(batch)) changed = true;
      }
      if (changed) notifyListeners();
    } catch (_) {
      // Recovery is best effort; live updates still drive the UI.
    }
  }

  /// Returns true when the batch snapshot changed.
  Future<bool> _reconcileBatch(DownloadBatch batch) async {
    var changed = false;
    List<TaskRecord> tracked;
    try {
      tracked = await FileDownloader().database.allRecords(
        group: batch.batchId,
      );
    } catch (_) {
      return false;
    }
    final byId = {for (final r in tracked) r.taskId: r};
    for (final job in batch.jobs) {
      if (job.saved) continue;
      final taskId = job.currentTaskId;
      if (taskId == null) continue;
      final record = byId[taskId];
      if (record == null) {
        // Task unknown to the tracker (e.g. never enqueued before the
        // kill): leave active jobs to resume via native updates, mark
        // stale queued jobs for a fresh attempt below.
        if (job.state == JobState.queued) {
          await _enqueueAttempt(batch, job);
          changed = true;
        }
        continue;
      }
      if (record.status == TaskStatus.complete) {
        await _finishFile(batch, job, record.task);
        changed = true;
      } else if (record.status == TaskStatus.failed ||
          record.status == TaskStatus.notFound) {
        if (job.attempts < kMaxAttempts) {
          await _enqueueAttempt(batch, job);
        } else {
          job.state = JobState.failed;
          job.error ??= '下载失败';
        }
        changed = true;
      }
    }
    if (batch.isTerminal) {
      await _afterTerminal(batch);
      changed = true;
    }
    return changed;
  }

  Future<void> _persist(DownloadBatch batch) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _batchKey(batch.batchId),
        jsonEncode(batch.toJson()),
      );
      final index = prefs.getStringList(_batchIndexKey) ?? [];
      if (!index.contains(batch.batchId)) {
        index.add(batch.batchId);
        while (index.length > 10) {
          final dropped = index.removeAt(0);
          await prefs.remove(_batchKey(dropped));
        }
        await prefs.setStringList(_batchIndexKey, index);
      }
    } catch (_) {
      // Snapshots are best effort; in-memory state still drives the UI.
    }
  }
}

/// Fresh CDN URLs for a single item after re-parsing (manual retry path).
/// Returns null when the item no longer exists in the refreshed post.
List<String>? planFilesForItem(ParsedPost post, int itemIndex) {
  if (itemIndex < 0 || itemIndex >= post.items.length) return null;
  final item = post.items[itemIndex];
  final imageUrls = [...item.fallbacks, item.url];
  if (item.type == 'live' && item.videoUrl != null) {
    return [imageUrls.first, item.videoUrl!];
  }
  if (item.type == 'video') {
    final url = item.videoUrl ?? item.url;
    return item.videoUrl != null ? [url, ...imageUrls] : imageUrls;
  }
  return imageUrls;
}
