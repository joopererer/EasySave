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
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/dev_log.dart';
import '../core/models.dart';
import '../metadata/metadata_service.dart';
import '../metadata/xmp_model.dart';
import 'gallery_locator_service.dart';
import 'history_db.dart';
import 'parse_service.dart';
import 'saver.dart';
import 'settings.dart';
import 'update_service.dart';


/// Max download attempts per file, first try included. The plugin's native
/// retries stay at 0 so this counter is the single source of truth.
const int kMaxAttempts = 3;

/// How long a batch snapshot may stay untouched before the other engine may
/// consider its owner dead and adopt the batch. The owner refreshes the
/// snapshot every 15s (heartbeat), so 90s is a safe margin.
const int kStalledBatchAgeMs = 90 * 1000;

/// Pure decision helper for the dual-engine ownership rules: may this engine
/// adopt a batch that was started by the other engine?
///
/// - a batch of the own source is never "foreign";
/// - a foreign batch that some engine already settled is never adopted again
///   (its jobs stay terminal forever, so nothing else would stop it);
/// - a foreign batch may only be adopted when its snapshot went stale (the
///   owner stopped heart-beating) **and** all of its tasks already reached a
///   terminal state — otherwise the owner is still working on it.
bool canAdoptForeignBatch({
  required String owner,
  required String batchSource,
  required int updatedAt,
  required int now,
  required bool allTasksTerminal,
  String? settledBy,
}) {
  if (batchSource == owner) return false;
  if (settledBy != null) return false;
  if (updatedAt <= 0) return false;
  if (now - updatedAt < kStalledBatchAgeMs) return false;
  return allTasksTerminal;
}

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
  
  /// Provenance assetId written to this file (if any).
  String? assetId;

  /// Real MediaStore id + actual on-disk title of the saved asset, captured
  /// right after import so history can locate the file by id instead of
  /// relying on a filename that the system may have changed.
  String? mediaId;
  String? savedTitle;

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
    'assetId': assetId,
    'mediaId': mediaId,
    'savedTitle': savedTitle,
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
    job.assetId = map['assetId'] as String?;
    job.mediaId = map['mediaId'] as String?;
    job.savedTitle = map['savedTitle'] as String?;
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
    this.authorId,
    this.publishedAt,
    this.itemsJson,
    this.postItemCount,
    this.source = sourceMain,
    this.updatedAt = 0,
    required this.jobs,
  });

  /// Which engine owns this batch. The main UI isolate and the background
  /// isolate each keep their own [DownloadManager] instance but share the
  /// batch snapshots (SharedPreferences) and the plugin's task database, so
  /// every batch must state its owner: only the owner may save to the album
  /// and write history.
  static const String sourceMain = 'main';
  static const String sourceBackground = 'background';

  final String batchId;
  final String album;
  final String postUrl;
  final String platform;
  final String postId;
  final String? authorName;
  final String? title;
  final String? caption;
  final String? authorId;
  final DateTime? publishedAt;
  final String? itemsJson;

  /// Total number of media items in the whole post (`post.items.length`),
  /// independent of which items the user selected for this batch.
  final int? postItemCount;

  /// Item count written to provenance metadata. Prefers the stored post
  /// total; snapshots written before [postItemCount] existed fall back to
  /// the length of [itemsJson], and finally to the number of image jobs.
  int get totalItems {
    if (postItemCount != null) return postItemCount!;
    if (itemsJson != null) {
      try {
        final decoded = jsonDecode(itemsJson!);
        if (decoded is List && decoded.isNotEmpty) return decoded.length;
      } catch (_) {
        // Fall through to the job-based estimate.
      }
    }
    return jobs.where((j) => j.isImage).length;
  }

  /// Owner engine: [sourceMain] or [sourceBackground].
  final String source;
  final List<DownloadJob> jobs;
  bool historyWritten = false;

  /// Engine that finished an adopted foreign batch.
  ///
  /// A completed background batch stays in the snapshot index (its jobs are
  /// terminal, so it keeps looking adoptable). Recording who settled it is
  /// what stops the next start from adopting — and re-reconciling — it again.
  String? settledBy;

  /// Last time the owner wrote this snapshot. The owner refreshes it with a
  /// heartbeat, so a stale value means "the owning engine is gone" and lets
  /// the other engine adopt the batch instead of dropping it.
  int updatedAt;

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
    'authorId': authorId,
    'publishedAt': publishedAt?.toIso8601String(),
    'itemsJson': itemsJson,
    'postItemCount': postItemCount,
    'source': source,
    'updatedAt': updatedAt,
    'jobs': [for (final j in jobs) j.toJson()],
    'historyWritten': historyWritten,
    'settledBy': settledBy,
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
    authorId: map['authorId'] as String?,
    publishedAt: map['publishedAt'] != null 
        ? DateTime.tryParse(map['publishedAt'] as String)
        : null,
    itemsJson: map['itemsJson'] as String?,
    postItemCount: (map['postItemCount'] as num?)?.toInt(),
    // Batches written before this field existed were created by the main
    // engine, so they default to it.
    source: map['source'] as String? ?? sourceMain,
    updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
    jobs: (map['jobs'] as List)
        .map((e) => DownloadJob.fromJson((e as Map).cast<String, Object?>()))
        .toList(),
  )
    ..historyWritten = map['historyWritten'] as bool? ?? false
    ..settledBy = map['settledBy'] as String?;
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
          itemIndex: index + 1, // 1-based position in original post
        ),
      );
      planned.add(
        PlannedFile(
          label: base,
          urls: [item.videoUrl!],
          filename: '${nameFor(base, seq, 'mp4')}.mp4',
          isImage: false,
          itemIndex: index + 1, // 1-based position in original post
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
          itemIndex: index + 1, // 1-based position in original post
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
          itemIndex: index + 1, // 1-based position in original post
        ),
      );
    }
  }
  return planned;
}

/// Provenance for one downloaded item of [batch]. `itemIndex` is the 1-based
/// position in the original post and `itemCount` the size of the whole post,
/// never the size of the user's selection (selecting items 2 and 4 of a
/// 5-item post must write 2/5 and 4/5).
XmpProvenance provenanceForBatchItem(
  DownloadBatch batch, {
  required int itemIndex,
  String? existingAssetId,
}) {
  return ProvenanceBuilder(
    platform: batch.platform,
    postId: batch.postId,
    postUrl: batch.postUrl,
    authorName: batch.authorName,
    title: batch.title,
    caption: batch.caption,
    authorId: batch.authorId,
    publishedAt: batch.publishedAt,
    itemIndex: itemIndex,
    itemCount: batch.totalItems,
    existingAssetId: existingAssetId,
  ).build();
}

/// Extracts the first image from the itemsJson of a batch for the thumbnail.
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

/// Write the history record for a finished batch.
///
/// When [recovered] is true (startup/foreground reconcile), this is a resumed
/// batch that was interrupted, so the deletion state should NOT be restored
/// (restoreDeleted: false). When false (live update from a user-initiated
/// download), the history write may restore soft-deleted records.
Future<void> writeBatchHistory(
  HistoryDb db,
  DownloadBatch batch, {
  required bool recovered,
}) async {
  final thumb = _thumbnailFor(batch);
  final files = [
    for (final job in batch.jobs)
      if (job.saved && job.state == JobState.done)
        HistoryFile(
          // Prefer the real on-disk title (system may rename on clash),
          // and pin the MediaStore id so the file is found by id later.
          filename: (job.savedTitle?.isNotEmpty == true)
              ? job.savedTitle!
              : job.filename,
          savedAt: DateTime.now().millisecondsSinceEpoch,
          mediaId: job.mediaId,
          itemIndex: job.itemIndex,
          isImage: job.isImage,
          assetId: job.assetId,
          status: job.mediaId != null
              ? FileStatus.found
              : FileStatus.unknown,
        ),
  ];
  await db.upsert(
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
    // User-initiated downloads (live updates): restore deleted records.
    // Startup-resumed / interrupted batches: preserve deletion state.
    restoreDeleted: !recovered,
  );
}

class DownloadManager extends ChangeNotifier {
  DownloadManager._();

  static final DownloadManager instance = DownloadManager._();

  /// Which engine this instance belongs to. Statics are isolate-local, so the
  /// main UI isolate stays [DownloadBatch.sourceMain] while the background
  /// isolate sets [DownloadBatch.sourceBackground] before touching the
  /// manager.
  static String owner = DownloadBatch.sourceMain;

  /// Log tag for the dual-engine verification (adb logcat -s V16DL).
  static const String logTag = 'V16DL';

  /// Structured log used by the dual-engine verification. It is written to
  /// logcat (tag "flutter") and to the app's external files dir (v16dl.log)
  /// so it can be pulled with adb.
  static void _log(String message) {
    DevLog.write(logTag, '[$owner] $message');
  }

  final Map<String, DownloadBatch> _batches = {};
  StreamSubscription<TaskUpdate>? _updatesSub;
  Timer? _heartbeat;
  bool _ready = false;

  final _notifications = FlutterLocalNotificationsPlugin();
  static const _channelId = 'easysave_downloads';
  final Map<String, int> _lastShownPercent = {};

  // Retained: dropping the broadcast subscription would stop updates.
  Future<void> close() async {
    _heartbeat?.cancel();
    _heartbeat = null;
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
          android: AndroidInitializationSettings('@drawable/ic_stat_easysave'),
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
    // Heartbeat: refresh the snapshot of running batches so the other engine
    // can tell "the owner is alive" from "the owner died mid-batch".
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _heartbeatTick(),
    );
    await _loadAndReconcile();
  }

  /// Persist the running batches so their `updatedAt` stays fresh while the
  /// owning engine is alive.
  Future<void> _heartbeatTick() async {
    for (final batch in _batches.values.toList()) {
      if (batch.isTerminal) continue;
      await _persist(batch);
    }
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
            icon: '@drawable/ic_stat_easysave',
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
    bool requestGalleryAccess = true,
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
      // The background flow must never raise a system permission dialog;
      // callers there pass requestGalleryAccess:false and surface the
      // missing-permission error to the user instead.
      if (!requestGalleryAccess) {
        throw const FileSystemException('NO_GALLERY_ACCESS');
      }
      final granted = await Gal.requestAccess();
      if (!granted) throw const FileSystemException('没有相册访问权限');
    }
    // The batch id carries the owner so ownership is visible in the shared
    // snapshot store (SharedPreferences) and in the plugin's task groups.
    final batchId =
        '${DownloadManager.owner}-${DateTime.now().millisecondsSinceEpoch}';
    final planned = planFiles(post, selected, nameFor);
    final batch = DownloadBatch(
      batchId: batchId,
      album: album,
      postUrl: post.url,
      platform: post.platform,
      postId: post.id,
      authorName: post.author.name,
      authorId: post.author.id,
      title: post.title,
      caption: post.caption,
      publishedAt: post.publishedAt != null ? DateTime.tryParse(post.publishedAt!) : null,
      itemsJson: jsonEncode([for (final item in post.items) item.toJson()]),
      postItemCount: post.items.length,
      source: DownloadManager.owner,
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
    _log('batch start id=$batchId source=${batch.source} post=${batch.postId}');
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
    
    // Look up existing assetId for this file (for re-download reuse)
    String? existingAssetId;
    try {
      final db = await HistoryDb.instance();
      final existing = await db.getByPostId(batch.postId);
      if (existing != null) {
        final existingFile = existing.files.where((f) => f.itemIndex == job.itemIndex && f.isImage == job.isImage).firstOrNull;
        existingAssetId = existingFile?.assetId;
      }
    } catch (_) {
      // Best effort - continue without assetId
    }
    
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
        'itemIndex': job.itemIndex,
        'isImage': job.isImage,
        'existingAssetId': existingAssetId,
      }),
    );
    await _persist(batch);
    notifyListeners();
    await FileDownloader().enqueue(task);
  }

  void _onUpdate(TaskUpdate update) {
    final task = update.task;
    final batch = _batches[task.group];
    if (batch == null) {
      // A task of another engine's batch (the plugin can route an update to
      // the wrong engine when its per-task channel is gone). It is NOT ours:
      // ignore it so the file is never saved twice.
      _log('ignore foreign task update group=${task.group} id=${task.taskId}');
      return;
    }
    if (batch.source != DownloadManager.owner) {
      _log('ignore update of foreign batch ${batch.batchId}');
      return;
    }
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
        unawaited(_afterTerminal(batch, recovered: false));
      case TaskStatus.paused:
      case TaskStatus.enqueued:
      case TaskStatus.waitingToRetry:
        notifyListeners();
    }
  }

  /// Batches whose album was already indexed for the idempotency guard.
  final Set<String> _albumIndexed = <String>{};

  /// Look for an already-imported file with the planned name. The album is
  /// indexed once per batch (it is needed to see files saved by an earlier
  /// run), and only when the user granted album read access — without it we
  /// simply proceed and save the file.
  Future<AssetEntity?> _findExistingAlbumAsset(
    DownloadBatch batch,
    DownloadJob job,
  ) async {
    final locator = GalleryLocatorService.instance;
    if (!locator.hasAccess) return null;
    if (_albumIndexed.add(batch.batchId)) {
      try {
        await locator.scanAlbum(force: true);
      } catch (_) {
        // Indexing is best effort.
      }
    }
    final name = job.filename;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return locator.assetByBaseName(base);
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
      await _afterTerminal(batch, recovered: false);
      return;
    }
    
    // Parse metadata for provenance
    String? existingAssetId;
    int? itemIndex;
    bool isImage = true;
    try {
      final meta = jsonDecode(task.metaData);
      existingAssetId = meta['existingAssetId'] as String?;
      itemIndex = meta['itemIndex'] as int?;
      isImage = meta['isImage'] as bool? ?? true;
    } catch (_) {}
    
    try {
      final file = File(path);
      if (!await file.exists()) {
        job.error = '文件丢失，请重试';
        job.state = JobState.failed;
      } else {
        // Idempotency guard: if a file with the same name is already in the
        // album, the import already happened (e.g. the process died between
        // the copy and the snapshot write) — reuse it instead of saving a
        // second copy.
        final existing = await _findExistingAlbumAsset(batch, job);
        if (existing != null) {
          _log('gallery import skipped, already saved: ${job.filename}');
          job.mediaId = existing.id;
          job.savedTitle = existing.title;
          job.state = JobState.done;
          job.progress = 1;
          job.saved = true;
          try {
            await file.delete();
          } catch (_) {
            // Temp file cleanup is best effort.
          }
        } else {
          // Embed provenance metadata before saving to gallery
          String? writtenAssetId;
          if (isImage) {
            writtenAssetId = await _embedProvenance(
              filePath: path,
              batch: batch,
              job: job,
              existingAssetId: existingAssetId,
              itemIndex: itemIndex ?? job.itemIndex,
            );
          }
          
          final saved = await saveToGallery(path, isImage, batch.album);
          _log('gallery import done: ${job.filename} -> ${saved.mediaId}');
          job.mediaId = saved.mediaId;
          job.savedTitle = saved.title;
          job.state = JobState.done;
          job.progress = 1;
          job.saved = true;
          
          // Store assetId for reuse
          job.assetId = writtenAssetId;
        }
      }
    } catch (e) {
      job.error = '$e';
      job.state = JobState.failed;
    }
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch, recovered: false);
  }
  
  /// Embed provenance metadata into an image file.
  /// Returns the assetId if written, null if skipped or failed.
  Future<String?> _embedProvenance({
    required String filePath,
    required DownloadBatch batch,
    required DownloadJob job,
    String? existingAssetId,
    required int itemIndex,
  }) async {
    try {
      // Check setting
      final settings = await AppSettings.load();
      if (!settings.saveProvenanceInImages) {
        _log('provenance skipped (setting disabled): ${job.filename}');
        return null;
      }
      
      // Build provenance metadata
      final provenance = provenanceForBatchItem(
        batch,
        itemIndex: itemIndex,
        existingAssetId: existingAssetId,
      );
      
      // Embed into file
      final result = await MetadataService.embedProvenance(
        filePath: filePath,
        provenance: provenance,
        checkC2pa: true,
      );
      
      if (result.skippedC2pa) {
        _log('provenance skipped (C2PA detected): ${job.filename}');
      } else if (result.success) {
        _log('provenance embedded: ${job.filename}');
        return provenance.assetId;
      } else {
        _log('provenance embed failed: ${job.filename} - ${result.errorMessage}');
      }
    } catch (e) {
      _log('provenance embed error: ${job.filename} - $e');
      // Metadata failures are logged but do not block the save
    }
    return null;
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
    await _afterTerminal(batch, recovered: false);
  }

  /// [recovered] is true only when the batch is finished by the startup /
  /// foreground reconcile ([reconcile]); live updates and user actions on a
  /// running batch pass false. It decides whether the history write may
  /// restore a soft-deleted record (see [writeBatchHistory]).
  Future<void> _afterTerminal(
    DownloadBatch batch, {
    required bool recovered,
  }) async {
    if (!batch.isTerminal) return;
    if (!batch.historyWritten) {
      batch.historyWritten = true;
      final db = await HistoryDb.instance();
      await writeBatchHistory(db, batch, recovered: recovered);
      final locator = GalleryLocatorService.instance;
      if (locator.hasAccess) {
        unawaited(locator.scanAlbum(force: true));
      }
    }
    // Record who finished a batch it did not start. The snapshot keeps its
    // terminal jobs, so this flag is the only thing that stops the next start
    // from adopting the same completed batch again.
    if (batch.source != DownloadManager.owner && batch.settledBy == null) {
      batch.settledBy = DownloadManager.owner;
      _log(
        'settle foreign batch ${batch.batchId} '
        '(source=${batch.source} by=${batch.settledBy} recovered=$recovered)',
      );
    }
    await _persist(batch);
    notifyListeners();
    unawaited(_refreshNotification(batch));
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

  /// Retry every failed job in the batch (manual "重试" from the preview page).
  Future<void> retryBatch(DownloadBatch batch) async {
    final failed = batch.jobs
        .where((j) => j.state == JobState.failed)
        .toList();
    for (final job in failed) {
      await retryJob(batch, job);
    }
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
    await _afterTerminal(batch, recovered: false);
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
      var adopted = 0;
      for (final batchId in index) {
        final raw = prefs.getString(_batchKey(batchId));
        if (raw == null) continue;
        final batch = DownloadBatch.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
        );
        // Ownership: the batch snapshots live in a SharedPreferences file
        // that BOTH engines can read. Only the engine that started the batch
        // may reconcile it, otherwise the album file would be saved twice.
        if (batch.source != DownloadManager.owner) {
          if (batch.settledBy != null) {
            // Already finished by one of the engines. Its jobs stay terminal
            // forever, so without this check every start would adopt (and
            // re-reconcile) it again.
            _log(
              'skip settled foreign batch ${batch.batchId} '
              '(settled by ${batch.settledBy})',
            );
            continue;
          }
          if (await _isStalledForeignBatch(batch)) {
            // The owner is gone (its engine was killed) and every task of the
            // batch already finished: adopt it so the album import and the
            // history record still happen exactly once.
            _log('adopt stalled foreign batch ${batch.batchId}');
            adopted++;
            _batches[batchId] = batch;
            if (await _reconcileBatch(batch)) changed = true;
          } else {
            _log('skip foreign batch ${batch.batchId} (${batch.source})');
          }
          continue;
        }
        _batches[batchId] = batch;
        if (await _reconcileBatch(batch)) changed = true;
      }
      // One line per start makes two launches directly comparable in the log.
      _log('reconcile done batches=${index.length} adopted=$adopted');
      if (changed) notifyListeners();
    } catch (_) {
      // Recovery is best effort; live updates still drive the UI.
    }
  }

  /// A foreign batch can be adopted when its owner stopped refreshing the
  /// snapshot (heartbeat) and all of its tasks already reached a terminal
  /// state — i.e. nobody is going to finish it any more.
  Future<bool> _isStalledForeignBatch(DownloadBatch batch) async {
    final allTerminal = await _allTasksTerminal(batch);
    return canAdoptForeignBatch(
      owner: DownloadManager.owner,
      batchSource: batch.source,
      updatedAt: batch.updatedAt,
      now: DateTime.now().millisecondsSinceEpoch,
      allTasksTerminal: allTerminal,
      settledBy: batch.settledBy,
    );
  }

  Future<bool> _allTasksTerminal(DownloadBatch batch) async {
    try {
      final records = await FileDownloader().database.allRecords(
        group: batch.batchId,
      );
      if (records.isEmpty) return false;
      for (final r in records) {
        final s = r.status;
        if (s != TaskStatus.complete &&
            s != TaskStatus.failed &&
            s != TaskStatus.notFound &&
            s != TaskStatus.canceled) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
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
      await _afterTerminal(batch, recovered: true);
      changed = true;
    }
    return changed;
  }

  Future<void> _persist(DownloadBatch batch) async {
    try {
      batch.updatedAt = DateTime.now().millisecondsSinceEpoch;
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
