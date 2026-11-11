// Batch downloads through background_downloader: true background work,
// per-file status, auto-retry and kill-recovery. Gallery import still goes
// through gal, and batch snapshots live in SharedPreferences.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gal/gal.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_version.dart';
import '../core/dev_log.dart';
import '../core/models.dart';
import '../core/media_request.dart';
import '../metadata/metadata_service.dart';
import '../metadata/site_provenance.dart';
import 'backup/local_auto_backup.dart';
import 'backup/saf_service.dart';
import 'gallery_locator_service.dart';
import 'history_db.dart';
import 'history_io.dart';
import 'image_dimensions.dart';
import 'mp4_audio_probe.dart';
import 'storage_guard.dart';
import 'parse_service.dart';
import 'saver.dart';
import 'download_provenance.dart';
import 'export_names.dart';
import 'download_claims.dart';
import 'provenance_pair.dart';
import 'save_collision.dart';
import 'session_media_download.dart';
import 'media_request_policy.dart';
import 'site_registry.dart';
import 'settings.dart';

/// Max download attempts per file, first try included. The plugin's native
/// retries stay at 0 so this counter is the single source of truth.
const int kMaxAttempts = 3;

int maxAttemptsFor(DownloadBatch batch, DownloadJob job) =>
    (SiteRegistry.current.byId(batch.platform)?.data['download']
            as Map?)?['transport'] ==
        'session'
    ? job.urls.length
    : kMaxAttempts;

bool needsSessionDownload(DownloadBatch batch, DownloadJob job) {
  if (job.resources.isNotEmpty) {
    return job.resources.first.request.transport == MediaTransport.session;
  }
  final config =
      SiteRegistry.current.byId(batch.platform)?.data['download'] as Map?;
  if (config == null) return false;
  final defaults =
      (config['resourceDefaults'] as Map?)?[job.isImage ? 'image' : 'video']
          as Map?;
  return (defaults?['transport'] ?? config['transport']) == 'session';
}

bool recoverSessionJob(DownloadBatch batch, DownloadJob job) {
  if (!needsSessionDownload(batch, job) || job.isTerminal) return false;
  job.state = JobState.failed;
  job.progress = 0;
  job.currentTaskId = null;
  job.error = interruptedMediaMessage;
  return true;
}

/// Whether a downloaded video at [path] lacks a sound track while a later
/// candidate URL of [job] is still untried. Images, Live Photo motion clips,
/// the last candidate and files that cannot be read as MP4 are kept.
Future<bool> shouldRetryForMissingAudio(
  DownloadJob job,
  String path, {
  Future<bool?> Function(String path)? probe,
}) async {
  if (job.isImage || job.isLivePhoto || job.attempts >= job.urls.length) {
    return false;
  }
  final hasAudio =
      await (probe ?? (path) => mp4HasAudioTrack(File(path)))(path);
  return hasAudio == false;
}

List<String> orderedMediaUrls(ParsedPost post, MediaItem item) {
  // A parser-ranked order wins (XHS images: original resolution first,
  // preview variants never).
  if (item.downloadOrder.isNotEmpty) return item.downloadOrder;
  return (SiteRegistry.current.byId(post.platform)?.data['download']
              as Map?)?['urlOrder'] ==
          'primaryFirst'
      ? [item.url, ...item.fallbacks]
      : [...item.fallbacks, item.url];
}

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

/// What the watchdog does with a job that showed no life for
/// [kStalledBatchAgeMs].
enum StalledAction { keepWaiting, finishFile, retry, fail }

/// Pure decision for a stuck `queued`/`active` job, given the status the
/// native task database reports for its current task ([nativeStatus] is null
/// when the record is missing, e.g. the task was lost with a killed engine).
///
/// Anything the native side still works on is left alone; a finished task
/// whose import never ran is imported now; lost or failed tasks are retried
/// until [kMaxAttempts] is used up, then failed so the batch can finish.
StalledAction decideStalledAction({
  required TaskStatus? nativeStatus,
  required int attempts,
  int maxAttempts = kMaxAttempts,
}) {
  switch (nativeStatus) {
    case TaskStatus.complete:
      return StalledAction.finishFile;
    case TaskStatus.enqueued:
    case TaskStatus.running:
    case TaskStatus.waitingToRetry:
    case TaskStatus.paused:
      return StalledAction.keepWaiting;
    case TaskStatus.failed:
    case TaskStatus.notFound:
    case TaskStatus.canceled:
    case null:
      return attempts < maxAttempts ? StalledAction.retry : StalledAction.fail;
  }
}

/// Own live batches win over their (older) snapshot copies; newest first.
List<DownloadBatch> mergeBatchViews(
  Iterable<DownloadBatch> own,
  Iterable<DownloadBatch> snapshots,
) {
  final byId = <String, DownloadBatch>{
    for (final b in snapshots) b.batchId: b,
    for (final b in own) b.batchId: b,
  };
  final list = byId.values.toList()
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  return list;
}

/// Longest the gallery import of one finished file may take.
const Duration kFinishFileTimeout = Duration(seconds: 60);

/// Import budget for a file of [bytes]: the base budget plus one second per
/// 8 MiB, because a large video is rewritten for provenance and then copied
/// into the album (a 1 GB video gets about 3 minutes instead of 60 s).
Duration finishTimeoutFor(int? bytes) =>
    kFinishFileTimeout + Duration(seconds: (bytes ?? 0) ~/ (8 * 1024 * 1024));

/// Short reason shown in history next to "下载失败".
String? shortFailureReason(DownloadJob job) {
  if (job.state != JobState.failed) return null;
  final error = job.error ?? '';
  if (job.errorCode == storageFullCode || isStorageFullError(error)) {
    return '存储空间不足';
  }
  final status = job.lastStatusCode ??
      int.tryParse(RegExp(r'HTTP (\d{3})').firstMatch(error)?.group(1) ?? '');
  if (status != null) return 'HTTP $status';
  if (error.contains('超时')) return '保存超时';
  if (error.contains('过期')) return '链接已过期';
  if (error.contains('允许范围')) return '地址不被允许';
  if (error.contains('文件丢失')) return '文件丢失';
  if (error.contains('来源信息')) return '来源信息写入失败';
  return '下载出错';
}

/// `paused` is appended last: job states are persisted by index.
enum JobState { queued, active, done, failed, canceled, paused }

/// Running work takes precedence over an old failure, regardless of snapshot
/// timestamps (a late failure may be newer than the current download).
DownloadBatch? previewBatchForPost(
  Iterable<DownloadBatch> batches,
  String platform,
  String postId,
) {
  final matching = batches
      .where(
        (b) =>
            SiteRegistry.current.sameSite(b.platform, platform) &&
            b.postId == postId,
      )
      .toList();
  return matching.where((b) => !b.isTerminal).firstOrNull ??
      matching.where((b) => b.failedCount > 0).firstOrNull;
}

class DownloadJob {
  DownloadJob({
    required this.key,
    required this.label,
    required this.filename,
    required this.urls,
    required this.isImage,
    required this.itemIndex,
    this.isLivePhoto = false,
    this.resources = const [],
  });
  final String key;
  final String label;
  final String filename;
  List<String> urls;
  List<MediaRequestResource> resources;
  final bool isImage;
  final int itemIndex;
  final bool isLivePhoto;

  JobState state = JobState.queued;
  double progress = 0;
  int attempts = 0;
  String? currentTaskId;
  bool saved = false;
  String? error;
  int? lastStatusCode;

  /// Machine-readable failure code ([storageFullCode]) next to [error].
  String? errorCode;

  /// Content-Length of the media when known (storage preflight).
  int? expectedBytes;

  /// Size of the file handed to the album (after provenance), used to decide
  /// whether an album copy found on retry is complete.
  int? fileBytes;

  /// Declared pixel size of an image; a download clearly smaller is retried
  /// with the next candidate.
  int? expectedWidth;
  int? expectedHeight;

  /// Largest too-small download kept while better candidates are tried.
  String? lowResPath;
  int? lowResPixels;

  /// All candidates were too small; the largest was saved ("非原图").
  bool notOriginal = false;

  /// Provenance assetId written to this file (if any).
  String? assetId;

  /// Real MediaStore id + actual on-disk title of the saved asset, captured
  /// right after import so history can locate the file by id instead of
  /// relying on a filename that the system may have changed.
  String? mediaId;
  String? savedTitle;
  String? metadataNotice;
  String? relativePath;

  /// prov:itemCount and prov:capturedBy of the provenance actually written into
  /// the file (or read back from the reused file). History stores these so the
  /// backup export can report what the file says instead of guessing.
  int? provenanceItemCount;
  String? provenanceCapturedBy;

  /// Last time this job showed life (enqueued, progress or status update), in
  /// epoch ms. The watchdog and the stale-batch check use it; 0 = unknown
  /// (snapshots written before this field existed).
  int lastProgressAt = 0;

  bool get isTerminal =>
      state == JobState.done ||
      state == JobState.failed ||
      state == JobState.canceled;

  Map<String, Object?> toJson() => {
    'lastProgressAt': lastProgressAt,
    'key': key,
    'label': label,
    'filename': filename,
    'urls': urls,
    if (resources.isNotEmpty)
      'resources': [for (final r in resources) r.toJson()],
    'isImage': isImage,
    'itemIndex': itemIndex,
    'isLivePhoto': isLivePhoto,
    'state': state.index,
    'attempts': attempts,
    'currentTaskId': currentTaskId,
    'saved': saved,
    'error': error,
    'lastStatusCode': lastStatusCode,
    if (errorCode != null) 'errorCode': errorCode,
    if (expectedBytes != null) 'expectedBytes': expectedBytes,
    if (fileBytes != null) 'fileBytes': fileBytes,
    if (expectedWidth != null) 'expectedWidth': expectedWidth,
    if (expectedHeight != null) 'expectedHeight': expectedHeight,
    if (lowResPath != null) 'lowResPath': lowResPath,
    if (lowResPixels != null) 'lowResPixels': lowResPixels,
    if (notOriginal) 'notOriginal': true,
    'assetId': assetId,
    'mediaId': mediaId,
    'savedTitle': savedTitle,
    'metadataNotice': metadataNotice,
    'relativePath': relativePath,
    if (provenanceItemCount != null) 'provenanceItemCount': provenanceItemCount,
    if (provenanceCapturedBy != null)
      'provenanceCapturedBy': provenanceCapturedBy,
  };

  static DownloadJob fromJson(Map<String, Object?> map) {
    final job = DownloadJob(
      key: map['key'] as String,
      label: map['label'] as String,
      filename: map['filename'] as String,
      urls: (map['urls'] as List).cast<String>(),
      resources: [
        for (final raw in map['resources'] as List? ?? const [])
          MediaRequestResource.fromJson((raw as Map).cast<String, dynamic>()),
      ],
      isImage: map['isImage'] as bool,
      itemIndex: (map['itemIndex'] as num).toInt(),
      isLivePhoto: map['isLivePhoto'] as bool? ?? false,
    );
    job.state = JobState.values[(map['state'] as num).toInt()];
    job.attempts = (map['attempts'] as num).toInt();
    job.currentTaskId = map['currentTaskId'] as String?;
    job.saved = map['saved'] as bool? ?? false;
    job.error = map['error'] as String?;
    job.lastStatusCode = (map['lastStatusCode'] as num?)?.toInt();
    job.errorCode = map['errorCode'] as String?;
    job.expectedBytes = (map['expectedBytes'] as num?)?.toInt();
    job.fileBytes = (map['fileBytes'] as num?)?.toInt();
    job.expectedWidth = (map['expectedWidth'] as num?)?.toInt();
    job.expectedHeight = (map['expectedHeight'] as num?)?.toInt();
    job.lowResPath = map['lowResPath'] as String?;
    job.lowResPixels = (map['lowResPixels'] as num?)?.toInt();
    job.notOriginal = map['notOriginal'] as bool? ?? false;
    job.assetId = map['assetId'] as String?;
    job.mediaId = map['mediaId'] as String?;
    job.savedTitle = map['savedTitle'] as String?;
    job.metadataNotice = map['metadataNotice'] as String?;
    job.relativePath = map['relativePath'] as String?;
    job.provenanceItemCount = (map['provenanceItemCount'] as num?)?.toInt();
    job.provenanceCapturedBy = map['provenanceCapturedBy'] as String?;
    job.lastProgressAt = (map['lastProgressAt'] as num?)?.toInt() ?? 0;
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
    this.aiLabel,
    this.aiLabelSource,
    this.authorId,
    this.publishedAt,
    this.itemsJson,
    this.postItemCount,
    this.source = sourceMain,
    this.updatedAt = 0,
    required this.jobs,
    int? startedAt,
  }) : startedAt = startedAt ?? DateTime.now().microsecondsSinceEpoch;

  final int startedAt;
  bool cancelledByDeletion = false;

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
  final String? aiLabel;
  final String? aiLabelSource;
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

  /// Overall progress 0..1 across the jobs that were not canceled.
  double get progress {
    final live = jobs.where((j) => j.state != JobState.canceled).toList();
    if (live.isEmpty) return 0;
    var sum = 0.0;
    for (final j in live) {
      sum += j.state == JobState.done ? 1.0 : j.progress.clamp(0.0, 1.0);
    }
    return sum / live.length;
  }

  /// Unfinished and every unfinished job is paused by the user.
  /// Session-only TikTok videos cannot resume a paused transfer.
  bool get supportsPause => !jobs.any((job) => needsSessionDownload(this, job));

  bool get isPaused {
    final open = jobs.where((j) => !j.isTerminal);
    return open.isNotEmpty && open.every((j) => j.state == JobState.paused);
  }

  int get doneCount => jobs.where((j) => j.state == JobState.done).length;
  int get failedCount => jobs.where((j) => j.state == JobState.failed).length;

  /// Short reason of the first failed job, for the history card.
  String? get failureReason => jobs
      .map(shortFailureReason)
      .whereType<String>()
      .firstOrNull;

  /// Newest sign of life among the unfinished jobs; falls back to the
  /// snapshot time for snapshots without per-job timestamps.
  int get lastActivityAt {
    var last = 0;
    for (final j in jobs) {
      if (!j.isTerminal && j.lastProgressAt > last) last = j.lastProgressAt;
    }
    return last > 0 ? last : updatedAt;
  }

  /// A non-terminal batch whose jobs showed no life for
  /// [kStalledBatchAgeMs]. Such a batch is not really running any more, so it
  /// must not block other work (e.g. restoring a backup).
  bool isStalledAt(int now) {
    if (isTerminal) return false;
    // A batch the user paused is waiting on purpose, not stuck.
    if (isPaused) return false;
    final last = lastActivityAt;
    if (last <= 0) return false;
    return now - last >= kStalledBatchAgeMs;
  }

  /// Copy of this batch owned by [owner], used when this engine takes over a
  /// batch whose owner is gone (so its task updates are no longer ignored).
  DownloadBatch copyOwnedBy(String owner) {
    final json = Map<String, Object?>.from(toJson())
      ..['source'] = owner
      ..['settledBy'] = null;
    return DownloadBatch.fromJson(json);
  }

  Map<String, Object?> toJson() => {
    'batchId': batchId,
    'album': album,
    'postUrl': postUrl,
    'platform': platform,
    'postId': postId,
    'authorName': authorName,
    'title': title,
    'caption': caption,
    'aiLabel': aiLabel,
    'aiLabelSource': aiLabelSource,
    'authorId': authorId,
    'publishedAt': publishedAt?.toIso8601String(),
    'itemsJson': itemsJson,
    'postItemCount': postItemCount,
    'source': source,
    'updatedAt': updatedAt,
    'jobs': [for (final j in jobs) j.toJson()],
    'historyWritten': historyWritten,
    'startedAt': startedAt,
    'cancelledByDeletion': cancelledByDeletion,
    'settledBy': settledBy,
  };

  static DownloadBatch fromJson(Map<String, Object?> map) =>
      DownloadBatch(
          batchId: map['batchId'] as String,
          startedAt: (map['startedAt'] as num?)?.toInt() ?? 0,
          album: map['album'] as String,
          postUrl: map['postUrl'] as String,
          platform: map['platform'] as String,
          postId: map['postId'] as String,
          authorName: map['authorName'] as String?,
          title: map['title'] as String?,
          caption: map['caption'] as String?,
          aiLabel: map['aiLabel'] as String?,
          aiLabelSource: map['aiLabelSource'] as String?,
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
              .map(
                (e) => DownloadJob.fromJson((e as Map).cast<String, Object?>()),
              )
              .toList(),
        )
        ..historyWritten = map['historyWritten'] as bool? ?? false
        ..cancelledByDeletion = map['cancelledByDeletion'] as bool? ?? false
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
    this.isLivePhoto = false,
    this.expectedWidth,
    this.expectedHeight,
  });

  final String label;
  final List<String> urls;

  /// Declared pixel size of an image (for the low-resolution check).
  final int? expectedWidth;
  final int? expectedHeight;
  final String filename;
  final bool isImage;
  final int itemIndex;
  final bool isLivePhoto;
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
    final imageUrls = orderedMediaUrls(post, item);
    if (item.type == 'live' && item.videoUrl != null) {
      final base = nextLabel('Live');
      planned.add(
        PlannedFile(
          label: base,
          urls: imageUrls,
          filename: '${nameFor(base, seq, 'jpg')}.jpg',
          isImage: true,
          itemIndex: index + 1, // 1-based position in original post
          isLivePhoto: true,
          expectedWidth: item.width?.toInt(),
          expectedHeight: item.height?.toInt(),
        ),
      );
      planned.add(
        PlannedFile(
          label: base,
          urls: [item.videoUrl!],
          filename: '${nameFor(base, seq, 'mp4')}.mp4',
          isImage: false,
          itemIndex: index + 1, // 1-based position in original post
          isLivePhoto: true,
        ),
      );
    } else if (item.type == 'video') {
      final label = nextLabel('视频');
      final url = item.videoUrl ?? item.url;
      planned.add(
        PlannedFile(
          label: label,
          // With a separate videoUrl, url/fallbacks describe the still poster.
          // Otherwise the parser ranks the video first and its fallbacks are
          // the next renditions to try (e.g. when a file has no audio track).
          urls: item.videoUrl != null ? [url] : [item.url, ...item.fallbacks],
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
          expectedWidth: item.width?.toInt(),
          expectedHeight: item.height?.toInt(),
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
  String? capturedBy,
  String? pairId,
}) {
  return buildSiteProvenance(
    platform: batch.platform,
    capturedBy: capturedBy ?? AppVersion.capturedBy,
    sourceId: batch.postId,
    sourceUrl: batch.postUrl,
    authorName: batch.authorName,
    title: batch.title,
    caption: batch.caption,
    aiLabel: batch.aiLabel,
    aiLabelSource: batch.aiLabelSource,
    authorId: batch.authorId,
    publishedAt: batch.publishedAt,
    itemIndex: itemIndex,
    itemCount: batch.totalItems,
    existingAssetId: existingAssetId,
  ).copyWith(pairId: pairId);
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
  if (batch.cancelledByDeletion) return;
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
          relativePath: job.relativePath,
          itemCount: job.provenanceItemCount,
          capturedBy: job.provenanceCapturedBy,
          // A finished save is a confirmation: the album accepted the file.
          // The history only counts confirmed rows, so a successful save must
          // not be written as `unknown` just because MediaStore returned no id.
          status: FileStatus.found,
          size: job.fileBytes,
          notOriginal: job.notOriginal,
        ),
  ];
  DevLog.write(
    DownloadManager.logTag,
    'history write post=${batch.postId} recovered=$recovered '
    'restoreDeleted=${!recovered} files=${files.length}',
  );
  await db.upsert(
    HistoryRecord(
      platform: batch.platform,
      postId: batch.postId,
      authorName: batch.authorName,
      title: batch.title,
      caption: batch.caption,
      aiLabel: batch.aiLabel,
      aiLabelSource: batch.aiLabelSource,
      thumbnailUrl: thumb,
      postUrl: batch.postUrl,
      fileCount: batch.succeeded,
      createdAt: DateTime.now(),
      itemsJson: batch.itemsJson,
      files: files,
      downloadError: batch.failedCount > 0 ? batch.failureReason ?? '下载出错' : null,
    ),
    // User-initiated downloads (live updates): restore deleted records.
    // Startup-resumed / interrupted batches: preserve deletion state.
    restoreDeleted: !recovered,
    userSave: !recovered,
    downloadStartedAt: batch.startedAt,
    source: recovered ? 'download-recovery' : 'download',
  );
}

/// Write a file-less history record as soon as a batch starts, so the post is
/// already visible in the history (with a downloading placeholder) while its
/// files are fetched. [HistoryDb.upsert] merges by file key, so an existing
/// record keeps its files; the terminal [writeBatchHistory] fills in the rest.
Future<void> writePlaceholderHistory(HistoryDb db, DownloadBatch batch) async {
  if (batch.cancelledByDeletion) return;
  await db.upsert(
    HistoryRecord(
      platform: batch.platform,
      postId: batch.postId,
      authorName: batch.authorName,
      title: batch.title,
      caption: batch.caption,
      aiLabel: batch.aiLabel,
      aiLabelSource: batch.aiLabelSource,
      thumbnailUrl: _thumbnailFor(batch),
      postUrl: batch.postUrl,
      fileCount: 0,
      createdAt: DateTime.now(),
      // itemsJson is deliberately omitted: HistoryRecord.fromMap infers
      // `unknown` files from it when files_json is empty, which would make the
      // placeholder look like a fully downloaded post. The terminal
      // writeBatchHistory supplies it; an existing record keeps its own.
      itemsJson: null,
      files: const [],
    ),
    // A user-initiated download brings a deleted record back.
    restoreDeleted: true,
    userSave: true,
    downloadStartedAt: batch.startedAt,
    source: 'download-placeholder',
  );
}

/// Remove the placeholder of a batch that produced nothing. A record that
/// already has files (an earlier download of the same post) is left alone.
Future<void> discardEmptyPlaceholder(HistoryDb db, DownloadBatch batch) async {
  final existing = await db.getByPostId(batch.postId);
  if (existing == null || existing.id == null) return;
  // fileCount, not files: HistoryRecord.fromMap infers `unknown` files from
  // itemsJson, so `files` is non-empty even when nothing was saved.
  if (existing.fileCount > 0) return;
  await db.permanentlyDelete(existing.id!);
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

  static int _batchSequence = 0;
  final Map<String, DownloadBatch> _batches = {};
  final Map<String, SessionMediaDownload> _sessionTransfers = {};
  StreamSubscription<TaskUpdate>? _updatesSub;
  Timer? _heartbeat;
  bool _ready = false;

  /// Notifier triggered whenever a batch completes with at least one succeeded item.
  final ValueNotifier<DownloadBatch?> onBatchSuccess =
      ValueNotifier<DownloadBatch?>(null);

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

  /// Whether any download batch is genuinely running. Batches that showed no
  /// sign of life for [kStalledBatchAgeMs] are ignored: they are stuck, and
  /// must not block other work such as restoring a backup.
  bool get hasActiveDownloads {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _batches.values.any((b) => !b.isTerminal && !b.isStalledAt(now));
  }

  /// Batches that are not terminal, stalled ones included (queue page).
  List<DownloadBatch> get unfinishedBatches => [
    for (final b in _batches.values)
      if (!b.isTerminal) b,
  ];

  /// Every batch this engine knows about merged with the snapshots of the
  /// other engine (SharedPreferences are shared), newest first. A batch that
  /// the other engine is running only exists as a snapshot here.
  Future<List<DownloadBatch>> liveBatches() async {
    final snapshots = <DownloadBatch>[];
    final dismissed = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      dismissed.addAll(
        prefs
            .getKeys()
            .where((key) => key.startsWith(_dismissedPrefix))
            .map((key) => key.substring(_dismissedPrefix.length)),
      );
      _batches.removeWhere(
        (id, batch) => dismissed.contains(id) && batch.isTerminal,
      );
      for (final id in prefs.getStringList(_batchIndexKey) ?? const []) {
        if (dismissed.contains(id)) continue;
        final raw = prefs.getString(_batchKey(id));
        if (raw == null) continue;
        try {
          snapshots.add(
            DownloadBatch.fromJson(
              (jsonDecode(raw) as Map).cast<String, Object?>(),
            ),
          );
        } catch (_) {
          // Skip a corrupt snapshot.
        }
      }
    } catch (_) {
      // Fall back to the in-memory batches below.
    }
    final merged = mergeBatchViews(_batches.values, snapshots);
    final saved = <String, DownloadJob>{
      for (final b in merged)
        for (final j in b.jobs)
          if (j.state == JobState.done && j.saved)
            downloadIdentity(b.platform, b.postId, j.itemIndex, j.isImage): j,
    };
    for (final b in merged) {
      var changed = false;
      for (final j in b.jobs.where((j) => j.state == JobState.failed)) {
        final success = saved[downloadIdentity(b.platform, b.postId, j.itemIndex, j.isImage)];
        final local = HistoryDb.knownSavedFiles(b.platform, b.postId).where((f) =>
            f.itemIndex == j.itemIndex && f.isImage == j.isImage &&
            f.status == FileStatus.found && f.mediaId?.isNotEmpty == true).firstOrNull;
        if (success == null && local == null) continue;
        j..state = JobState.done..saved = true..mediaId = success?.mediaId ?? local?.mediaId..error = null;
        changed = true;
      }
      if (changed) unawaited(_persist(b));
    }
    return merged;
  }

  /// Batch of [postId] that is still unfinished, from [liveBatches].
  Future<DownloadBatch?> activeBatchForPost(String postId) async {
    for (final b in await liveBatches()) {
      if (b.postId == postId && !b.isTerminal) return b;
    }
    return null;
  }

  @visibleForTesting
  void setBatchForTesting(DownloadBatch batch) {
    _batches[batch.batchId] = batch;
    notifyListeners();
  }

  @visibleForTesting
  void clearBatchesForTesting() {
    _batches.clear();
    notifyListeners();
  }

  static String _batchKey(String batchId) => 'easysave_batch_$batchId';
  static const _batchIndexKey = 'easysave_batches';
  static const _dismissedPrefix = 'easysave_dismissed_batch_';

  /// History deletion dismisses only terminal work, without adopting/canceling
  /// a batch owned by the other engine. Tombstones prevent stale engine memory
  /// from recreating its snapshot or failure strip after deletion.
  Future<void> clearTerminalBatchesForPost(String postId) async {
    for (final batch in await liveBatches()) {
      if (batch.postId != postId || !batch.isTerminal) continue;
      final local = _batches[batch.batchId];
      if (local != null && !local.isTerminal) continue;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_dismissedPrefix${batch.batchId}', true);
      _batches.remove(batch.batchId);
      _lastShownPercent.remove(batch.batchId);
      if (onBatchSuccess.value?.batchId == batch.batchId) {
        onBatchSuccess.value = null;
      }
      await _removeSnapshot(batch.batchId);
      await _cancelNotification(batch);
    }
    notifyListeners();
  }

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
      // Only batches this engine owns are driven here; a foreign batch is
      // left to its owner until it is adopted or force-adopted.
      if (batch.source == DownloadManager.owner) {
        try {
          await _watchdog(batch);
        } catch (e) {
          _log('watchdog error ${batch.batchId}: $e');
        }
      }
      if (batch.isTerminal) continue;
      await _persist(batch);
    }
  }

  final Set<String> _watchdogBusy = <String>{};

  /// Unstick jobs that were silent for [kStalledBatchAgeMs]: ask the native
  /// task database what really happened and import, retry or fail the job so
  /// the batch can reach a terminal state.
  Future<void> _watchdog(DownloadBatch batch) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final job in batch.jobs.toList()) {
      if (job.isTerminal || job.state == JobState.paused) continue;
      if (needsSessionDownload(batch, job)) {
        if (!_sessionTransfers.containsKey(job.key)) {
          recoverSessionJob(batch, job);
        }
        continue;
      }
      if (job.lastProgressAt <= 0) {
        // Snapshot from an older build: start the clock now.
        job.lastProgressAt = now;
        continue;
      }
      if (now - job.lastProgressAt < kStalledBatchAgeMs) continue;
      if (!_watchdogBusy.add(job.key)) continue;
      try {
        TaskRecord? record;
        final taskId = job.currentTaskId;
        if (taskId != null) {
          try {
            record = await FileDownloader().database.recordForId(taskId);
          } catch (_) {
            record = null;
          }
        }
        final action = decideStalledAction(
          nativeStatus: record?.status,
          attempts: job.attempts,
          maxAttempts: maxAttemptsFor(batch, job),
        );
        _log('watchdog ${job.key} native=${record?.status} -> $action');
        switch (action) {
          case StalledAction.keepWaiting:
            // Native side still works on it: give it another window.
            job.lastProgressAt = now;
          case StalledAction.finishFile:
            job.lastProgressAt = now;
            await _finishFile(batch, job, record!.task);
          case StalledAction.retry:
            if (taskId != null) {
              try {
                await FileDownloader().cancelTaskWithId(taskId);
              } catch (_) {}
            }
            try {
              await _enqueueAttempt(batch, job);
            } catch (e) {
              job.state = JobState.failed;
              job.error = '加入下载队列失败';
            }
          case StalledAction.fail:
            job.state = JobState.failed;
            job.error ??= '下载超时，请重试';
        }
      } finally {
        _watchdogBusy.remove(job.key);
      }
    }
    if (batch.isTerminal) {
      await _persist(batch);
      notifyListeners();
      await _afterTerminal(batch, recovered: false);
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
      await historyStep(
        'cancel-notification',
        () => _notifications.cancel(id: _notificationId(batch)),
        timeout: const Duration(seconds: 1),
      );
    } catch (_) {
      // Best effort.
    }
  }

  @visibleForTesting
  Future<void> Function()? prepareStartForTesting;
  @visibleForTesting
  Future<void> Function(DownloadBatch, DownloadJob)? enqueueForTesting;
  @visibleForTesting
  Future<ParseOutcome> Function(String)? reparseForTesting;

  /// Content-Length of a job URL (production: HEAD request).
  @visibleForTesting
  Future<int?> Function(DownloadJob job, String url)? contentLengthProbeForTesting;

  /// Album save of a finished file (production: provenance + native save).
  @visibleForTesting
  Future<({String? mediaId, String? title, String? relativePath})> Function(
    String path,
    DownloadJob job,
  )? gallerySaveForTesting;

  /// Terminal history write (production: [writeBatchHistory]).
  @visibleForTesting
  Future<void> Function(HistoryDb db, DownloadBatch batch, bool recovered)?
      historyWriterForTesting;

  /// Provenance of an album file and its MediaStore size.
  @visibleForTesting
  Future<XmpProvenance?> Function(AssetEntity asset)? albumProvenanceForTesting;
  @visibleForTesting
  Future<int?> Function(String mediaId, bool video)? mediaSizeForTesting;

  @visibleForTesting
  Duration? finishTimeoutForTesting;

  /// Header pixel size of a downloaded image (production: [readImageSize]).
  @visibleForTesting
  Future<ImageSize?> Function(String path)? imageSizeForTesting;

  @visibleForTesting
  Future<({bool retry, String path})> checkResolutionForTesting(
    DownloadBatch batch,
    DownloadJob job,
    String path,
  ) => _checkResolution(batch, job, path);
  @visibleForTesting
  Duration historyRetryDelay = const Duration(seconds: 30);
  @visibleForTesting
  Future<Directory> Function()? tempRootForTesting;

  @visibleForTesting
  Future<void> importFileForTesting(
    DownloadBatch batch,
    DownloadJob job,
    String path,
  ) => _importFile(batch, job, path, isImage: job.isImage);

  @visibleForTesting
  Future<void> afterTerminalForTesting(DownloadBatch batch) =>
      _afterTerminal(batch, recovered: false);

  @visibleForTesting
  Future<void> lateImportForTesting(String key) =>
      _lateImports[key] ?? Future<void>.value();

  Future<List<String>> _reserve(
    DownloadBatch batch,
    List<DownloadJob> jobs,
  ) async {
    final existing = <String, String>{};
    for (final other in await liveBatches()) {
      for (final job in other.jobs.where((job) => !job.isTerminal)) {
        existing[downloadIdentity(
              other.platform,
              other.postId,
              job.itemIndex,
              job.isImage,
            )] =
            other.batchId;
      }
    }
    return DownloadClaims.reserve(batch.batchId, [
      for (final j in jobs)
        downloadIdentity(batch.platform, batch.postId, j.itemIndex, j.isImage),
    ], existing);
  }

  Future<DownloadBatch> startBatch(
    ParsedPost post,
    List<int> selected, {
    required String album,
    required String Function(String label, int seq, String ext) nameFor,
    bool requestGalleryAccess = true,
    void Function(DownloadBatch)? onBatchReady,
  }) async {
    // The batch id carries the owner so ownership is visible in the shared
    // snapshot store (SharedPreferences) and in the plugin's task groups.
    final batchId =
        '${DownloadManager.owner}-${DateTime.now().microsecondsSinceEpoch}-${_batchSequence++}';
    final planned = planFiles(post, selected, nameFor);
    final site = SiteRegistry.current.byId(post.platform);
    if (site == null) {
      throw const MediaPolicyException('REQUEST_SITE_REJECTED', '');
    }
    final policy = MediaRequestPolicy(site);
    final resourcesByIndex = <int, List<MediaRequestResource>>{
      for (final index in selected)
        index + 1: policy.resourcesFor(post.items[index]),
    };
    final plannedResources = <List<MediaRequestResource>>[
      for (final file in planned)
        [
          for (final url in file.urls)
            resourcesByIndex[file.itemIndex]!.firstWhere(
              (resource) => resource.url == url,
              orElse: () => policy.rejectResource(url),
            ),
        ],
    ];
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
      aiLabel: post.aiLabel?.text,
      aiLabelSource: post.aiLabel?.source,
      publishedAt: post.publishedAt != null
          ? DateTime.tryParse(post.publishedAt!)
          : null,
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
            resources: plannedResources[i],
            isImage: planned[i].isImage,
            itemIndex: planned[i].itemIndex,
            isLivePhoto: planned[i].isLivePhoto,
          )
            ..expectedWidth = planned[i].expectedWidth
            ..expectedHeight = planned[i].expectedHeight,
      ],
    );
    final accepted = (await _reserve(batch, batch.jobs)).toSet();
    batch.jobs.removeWhere(
      (j) => !accepted.contains(
        downloadIdentity(batch.platform, batch.postId, j.itemIndex, j.isImage),
      ),
    );
    if (batch.jobs.isEmpty) throw AlreadyDownloading();
    try {
      if (prepareStartForTesting != null) {
        await prepareStartForTesting!();
      } else {
        await init();
        // Best effort: without the permission downloads still run, only the
        // notification progress is missing.
        try {
          await FileDownloader().permissions.request(
            PermissionType.notifications,
          );
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
      }
    } catch (_) {
      await DownloadClaims.release(batchId);
      rethrow;
    }
    _batches[batchId] = batch;
    notifyListeners();
    onBatchReady?.call(batch);
    _log('batch start id=$batchId source=${batch.source} post=${batch.postId}');
    unawaited(_refreshNotification(batch));
    await _persist(batch);
    // The placeholder is a convenience; the download must still start. The
    // terminal history write creates the record if this one cannot.
    await _writeHistoryWithRetry(
      batch,
      (db) => writePlaceholderHistory(db, batch),
      stage: 'placeholder',
    );
    for (final job in batch.jobs) {
      // One failing enqueue must not strand the remaining jobs in `queued`
      // (that kept the batch non-terminal forever, e.g. stuck at ~50%).
      try {
        await _enqueueAttempt(batch, job);
      } catch (e) {
        _log('enqueue failed ${job.key}: $e');
        job.state = JobState.failed;
        job.error = '加入下载队列失败';
      }
    }
    await _persist(batch);
    notifyListeners();
    if (batch.isTerminal) await _afterTerminal(batch, recovered: false);
    return batch;
  }

  MediaRequestResource _jobResource(
    DownloadJob job,
    int index,
    MediaRequestPolicy policy,
  ) {
    if (job.resources.isNotEmpty) return job.resources[index];
    final legacy = MediaItem(
      type: job.isImage ? 'image' : 'video',
      url: job.urls.first,
      fallbacks: job.urls.skip(1).toList(),
    );
    return policy.resourcesFor(legacy)[index];
  }

  MediaRequestPolicy _policyFor(String platform) {
    final site = SiteRegistry.current.byId(platform);
    if (site == null) {
      throw const MediaPolicyException('REQUEST_SITE_REJECTED', '');
    }
    return MediaRequestPolicy(site);
  }

  final _enqueuePending = <String>{};
  Future<void> _enqueueAttempt(DownloadBatch batch, DownloadJob job) async {
    if (!_enqueuePending.add(job.key)) return;
    try {
      await _enqueueAttemptOnce(batch, job);
    } finally {
      _enqueuePending.remove(job.key);
    }
  }

  Future<void> _enqueueAttemptOnce(DownloadBatch batch, DownloadJob job) async {
    if (batch.cancelledByDeletion ||
        await DownloadClaims.isCancelled(batch.batchId)) {
      batch.cancelledByDeletion = true;
      job.state = JobState.canceled;
      return;
    }
    if ((await _reserve(batch, [job])).isEmpty) throw AlreadyDownloading();
    if (await _storageBlocked(batch, job)) return;
    if (enqueueForTesting != null) {
      await enqueueForTesting!(batch, job);
      return;
    }
    if (needsSessionDownload(batch, job)) {
      await _startSessionDownload(batch, job);
      return;
    }
    final index = job.attempts % job.urls.length;
    final policy = _policyFor(batch.platform);
    final authorized = await policy.authorize(_jobResource(job, index, policy));
    if (authorized.cookie != null && authorized.cookie!.isNotEmpty) {
      // Cookie-bearing transfers stay in Dart so every redirect is authorised
      // again. Native background tasks receive no credential material.
      await _startSessionDownload(batch, job);
      return;
    }
    job.attempts++;
    final url = authorized.uri.toString();
    final taskId = '${job.key}-try${job.attempts}';
    job.currentTaskId = taskId;
    job.state = job.attempts == 1 ? JobState.queued : JobState.active;
    job.error = null;
    job.lastProgressAt = DateTime.now().millisecondsSinceEpoch;

    // Look up existing assetId for this file (for re-download reuse)
    String? existingAssetId;
    try {
      final db = await HistoryDb.instance();
      final existing = await db.getByPostId(batch.postId);
      if (existing != null) {
        final existingFile = existing.files
            .where(
              (f) => f.itemIndex == job.itemIndex && f.isImage == job.isImage,
            )
            .firstOrNull;
        existingAssetId = existingFile?.assetId;
      }
    } catch (_) {
      // Best effort - continue without assetId
    }

    final task = DownloadTask(
      taskId: taskId,
      url: url,
      filename: job.filename,
      headers: authorized.headers,
      directory: downloadTempDirectory(batch.batchId, taskId),
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
        'mediaPolicyHosts': (policy.site.data['download'] as Map)['mediaHosts'],
      }),
    );
    await _persist(batch);
    notifyListeners();
    final accepted = await FileDownloader().enqueue(task);
    if (!accepted) {
      throw StateError('enqueue rejected for ${job.key}');
    }
  }

  /// Low-resolution guard for images with a declared size. A file whose long
  /// side is below 80 % of the declared one is set aside (only the largest
  /// such copy is kept) and the next candidate is downloaded. When no
  /// candidate is left the largest copy is imported and marked "非原图".
  /// Returns `retry: true` when another candidate was enqueued, otherwise the
  /// path to import.
  Future<({bool retry, String path})> _checkResolution(
    DownloadBatch batch,
    DownloadJob job,
    String path,
  ) async {
    final expectedWidth = job.expectedWidth;
    final expectedHeight = job.expectedHeight;
    if (!job.isImage ||
        expectedWidth == null ||
        expectedHeight == null ||
        expectedWidth <= 0 ||
        expectedHeight <= 0) {
      return (retry: false, path: path);
    }
    final actual = await (imageSizeForTesting ?? readImageSize)(path);
    if (actual == null ||
        !isLowResolution(expectedWidth, expectedHeight, actual.width, actual.height)) {
      // A full-size file: a smaller copy kept earlier is no longer needed.
      final kept = job.lowResPath;
      if (kept != null) {
        job.lowResPath = null;
        try {
          await File(kept).delete();
        } catch (_) {}
      }
      return (retry: false, path: path);
    }
    unawaited(DevLog.write(
      'V16DL', // i18n:ignore 日志
      'event=retry reason=low_resolution index=${job.itemIndex} '
          'expected=${expectedWidth}x$expectedHeight '
          'actual=${actual.width}x${actual.height} '
          'candidate=${job.attempts}/${job.urls.length}',
    ));
    final pixels = actual.width * actual.height;
    final previous = job.lowResPath;
    if (previous == null || pixels > (job.lowResPixels ?? 0) || !await File(previous).exists()) {
      final root = await (tempRootForTesting?.call() ?? getTemporaryDirectory());
      final keep = File(
        '${root.path}/easysave_lowres/${Uri.encodeComponent(job.key)}/'
        'try${job.attempts}_${File(path).uri.pathSegments.last}',
      );
      await keep.parent.create(recursive: true);
      try {
        await File(path).rename(keep.path);
      } on FileSystemException {
        await File(path).copy(keep.path);
        await File(path).delete();
      }
      if (previous != null) {
        try {
          await File(previous).delete();
        } catch (_) {}
      }
      job
        ..lowResPath = keep.path
        ..lowResPixels = pixels;
    } else {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    if (job.attempts < job.urls.length) {
      await _persist(batch);
      await _enqueueAttempt(batch, job);
      return (retry: true, path: '');
    }
    final kept = job.lowResPath!;
    job
      ..lowResPath = null
      ..notOriginal = true;
    _log('low resolution: no larger candidate, keeping the largest index=${job.itemIndex}');
    return (retry: false, path: kept);
  }

  /// Fail [job] before it downloads when its known size does not fit.
  Future<bool> _storageBlocked(DownloadBatch batch, DownloadJob job) async {
    if (job.urls.isEmpty) return false;
    final index = job.attempts % job.urls.length;
    var size = job.expectedBytes;
    if (size == null) {
      try {
        final probe = contentLengthProbeForTesting;
        size = probe != null
            ? await probe(job, job.urls[index])
            : await _probeContentLength(batch, job, index);
      } catch (_) {
        size = null;
      }
      if (size != null && size > 0) job.expectedBytes = size;
    }
    final required = await StorageGuard.shortfall(size);
    _log('preflight index=${job.itemIndex} size=${size ?? -1} '
        'result=${required == null ? 'ok' : storageFullCode}');
    if (required == null) return false;
    await _failForStorage(batch, job, required);
    return true;
  }

  /// HEAD for the Content-Length of a cookie-free background download. No
  /// redirect is followed (each hop would need its own authorization).
  Future<int?> _probeContentLength(
    DownloadBatch batch,
    DownloadJob job,
    int index,
  ) async {
    if (needsSessionDownload(batch, job)) return null;
    final policy = _policyFor(batch.platform);
    final authorized = await policy.authorize(_jobResource(job, index, policy));
    if (authorized.cookie != null && authorized.cookie!.isNotEmpty) return null;
    final client = http.Client();
    try {
      final request = http.Request('HEAD', authorized.uri)
        ..followRedirects = false
        ..headers.addAll(authorized.headers);
      final response =
          await client.send(request).timeout(const Duration(seconds: 8));
      return response.statusCode == 200 ? response.contentLength : null;
    } finally {
      client.close();
    }
  }

  Future<void> _failForStorage(
    DownloadBatch batch,
    DownloadJob job,
    int? required,
  ) async {
    job.state = JobState.failed;
    job.errorCode = storageFullCode;
    job.error = storageFullMessage(required ??
        (job.expectedBytes == null
            ? null
            : requiredBytesForDownload(job.expectedBytes!)));
    await _cleanupJobTemp(batch, job);
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch, recovered: false);
  }

  /// Delete every temp file of [job]'s attempts (and [path] when given).
  Future<int> _cleanupJobTemp(
    DownloadBatch batch,
    DownloadJob job, {
    String? path,
  }) async {
    var bytes = 0;
    Future<void> remove(FileSystemEntity entity) async {
      try {
        if (entity is File) {
          if (!await entity.exists()) return;
          bytes += await entity.length();
          await entity.delete();
        } else if (entity is Directory) {
          if (!await entity.exists()) return;
          await for (final child in entity.list(recursive: true)) {
            if (child is File) bytes += await child.length();
          }
          await entity.delete(recursive: true);
        }
      } catch (_) {
        // Best effort; the next cleanup sees what is left.
      }
    }

    if (path != null) {
      await remove(File(path));
      await remove(File('$path.xmp'));
    }
    final kept = job.lowResPath;
    if (kept != null) {
      await remove(File(kept));
      job.lowResPath = null;
    }
    try {
      final root = await (tempRootForTesting?.call() ?? getTemporaryDirectory());
      final batchDir = Directory(
        '${root.path}/${downloadTempDirectory(batch.batchId, '')}',
      );
      if (await batchDir.exists()) {
        await for (final entry in batchDir.list()) {
          final name = Uri.decodeComponent(entry.uri.pathSegments
              .where((segment) => segment.isNotEmpty)
              .last);
          if (name.startsWith('${job.key}-try')) await remove(entry);
        }
      }
      if (tempRootForTesting == null) await remove(await _sessionFile(job));
    } catch (_) {
      // Temp roots are unavailable in some engines/tests.
    }
    _log('cleanup bytes=$bytes index=${job.itemIndex}');
    return bytes;
  }

  Future<File> _sessionFile(DownloadJob job) async {
    final root = await getTemporaryDirectory();
    return File(
      '${root.path}/easysave_session/${Uri.encodeComponent(job.key)}/${job.filename}',
    );
  }

  Future<void> _startSessionDownload(
    DownloadBatch batch,
    DownloadJob job,
  ) async {
    if (_sessionTransfers.containsKey(job.key)) return;
    final file = await _sessionFile(job);
    final transfer = SessionMediaDownload();
    _sessionTransfers[job.key] = transfer;
    job.attempts++;
    job.currentTaskId = null;
    job.state = JobState.active;
    job.error = null;
    job.progress = 0;
    job.lastProgressAt = DateTime.now().millisecondsSinceEpoch;
    await _persist(batch);
    notifyListeners();
    unawaited(_runSessionDownload(batch, job, transfer, file));
  }

  Future<void> _runSessionDownload(
    DownloadBatch batch,
    DownloadJob job,
    SessionMediaDownload transfer,
    File file,
  ) async {
    var checkingControl = false;
    final control = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (checkingControl) return;
      checkingControl = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        if (prefs.getBool('session_cancel_${job.key}') == true) {
          job.state = JobState.canceled;
          await transfer.cancel();
          await prefs.remove('session_cancel_${job.key}');
        }
      } finally {
        checkingControl = false;
      }
    });
    try {
      await transfer.download(
        url: job.urls[(job.attempts - 1) % job.urls.length],
        destination: file,
        policy: _policyFor(batch.platform),
        resource: _jobResource(job, (job.attempts - 1) % job.urls.length, _policyFor(batch.platform)),
        onProgress: (progress) {
          job.progress = progress;
          job.lastProgressAt = DateTime.now().millisecondsSinceEpoch;
          notifyListeners();
          unawaited(_refreshNotification(batch));
        },
      );
      if (job.state != JobState.active) return;
      await _importFile(
        batch,
        job,
        file.path,
        isImage: job.isImage,
        itemIndex: job.itemIndex,
      );
    } on SessionDownloadCanceled {
      if (job.state == JobState.active) job.state = JobState.canceled;
    } on MediaPolicyException catch (e) {
      job.state = JobState.failed;
      job.error = e.code == 'REQUEST_EXPIRED'
          ? expiredMediaMessage
          : '该资源地址不在允许范围内';
    } on SessionDownloadException catch (e) {
      job.state = JobState.failed;
      job.error = e.message;
      job.lastStatusCode = e.statusCode;
      if (isStorageFullError(e.message)) _markStorageFull(job);
    } catch (e) {
      job.state = JobState.failed;
      job.error = '下载失败，请重新解析';
      if (isStorageFullError(e)) _markStorageFull(job);
    } finally {
      control.cancel();
      _sessionTransfers.remove(job.key);
      if (await file.exists()) await file.delete();
      await _persist(batch);
      notifyListeners();
      await _afterTerminal(batch, recovered: false);
    }
  }

  void _markStorageFull(DownloadJob job) {
    job.errorCode = storageFullCode;
    job.error = storageFullMessage(job.expectedBytes == null
        ? null
        : requiredBytesForDownload(job.expectedBytes!));
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
    // A paused job has no live task; a late update of the cancelled one must
    // not flip it back to active/canceled/failed.
    if (job.state == JobState.paused ||
        batch.cancelledByDeletion ||
        job.state == JobState.canceled) {
      return;
    }
    job.lastProgressAt = DateTime.now().millisecondsSinceEpoch;
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
        // A storage failure cancels its task; keep the failure visible.
        if (job.state != JobState.done && job.errorCode != storageFullCode) {
          job.state = JobState.canceled;
        }
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
    DownloadJob job, {
    bool refresh = false,
  }) async {
    final locator = GalleryLocatorService.instance;
    final first = _albumIndexed.add(batch.batchId);
    try {
      // photo_manager in the foreground, native MediaStore in the overlay
      // engine (which cannot read photo_manager's permission).
      if (!await locator.ensureIndexed(force: first || refresh)) return null;
    } catch (_) {
      return null;
    }
    final name = cleanMediaFilename(
      batch.postId,
      job.itemIndex,
      job.isImage ? 'jpg' : 'mp4',
    );
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final asset = locator.assetByBaseName(base);
    final matchesType =
        asset != null &&
        (job.isImage
            ? asset.type == AssetType.image
            : asset.type == AssetType.video);
    return matchesType && await locator.isPresent(asset.id) ? asset : null;
  }

  /// Gallery import for a finished file, then temp cleanup.
  final _finishing = <String, Future<void>>{};
  Future<void> _trackFinish(String key, Future<void> Function() action) async {
    final running = _finishing[key];
    if (running != null) {
      await running;
      return;
    }
    final work = action();
    _finishing[key] = work;
    try {
      await work;
    } finally {
      _finishing.remove(key);
    }
  }

  @visibleForTesting
  Future<void> trackFinishForTesting(
    String key,
    Future<void> Function() action,
  ) => _trackFinish(key, action);

  Future<void> _finishFile(
    DownloadBatch batch,
    DownloadJob job,
    Task task,
  ) async {
    if (job.isTerminal) return;
    await _trackFinish(job.key, () => _finishFileOnce(batch, job, task));
  }

  Future<void> _finishFileOnce(
    DownloadBatch batch,
    DownloadJob job,
    Task task,
  ) async {
    if (batch.cancelledByDeletion ||
        await DownloadClaims.isCancelled(batch.batchId)) {
      return;
    }
    String path;
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

    final resolution = await _checkResolution(batch, job, path);
    if (resolution.retry) return;
    path = resolution.path;

    if (await shouldRetryForMissingAudio(job, path)) {
      unawaited(DevLog.write(
        'V16DL', // i18n:ignore 日志
        'event=retry reason=no_audio_track index=${job.itemIndex} '
            'candidate=${job.attempts}/${job.urls.length}',
      ));
      try {
        await File(path).delete();
      } catch (_) {}
      await _enqueueAttempt(batch, job);
      return;
    }

    await _importFile(
      batch,
      job,
      path,
      existingAssetId: existingAssetId,
      itemIndex: itemIndex,
      isImage: isImage,
    );
  }

  Future<void> _importFile(
    DownloadBatch batch,
    DownloadJob job,
    String path, {
    String? existingAssetId,
    int? itemIndex,
    required bool isImage,
  }) async {
    int? sourceBytes;
    try {
      sourceBytes = await File(path).length();
    } catch (_) {}
    // A hung album scan / metadata write / gallery copy must not leave the
    // job `active` forever (the batch would never finish).
    final work = (() async {
        final file = File(path);
        if (!await file.exists()) {
          job.error = '文件丢失，请重试';
          job.state = JobState.failed;
        } else {
          // Idempotency guard: if a file with the same name is already in the
          // album, the import already happened (e.g. the process died between
          // the copy and the snapshot write) — reuse it instead of saving a
          // second copy.
          var existing = await _findExistingAlbumAsset(batch, job);
          XmpProvenance? reusedProvenance;
          if (existing != null) {
            // A same-name file may be the result of an older skipped write.
            // Reuse only after checking its credentials against this save.
            // Header bytes only: originFile would copy a large video again.
            final read = await _albumProvenance(existing);
            final expected = provenanceForBatchItem(
              batch,
              itemIndex: itemIndex ?? job.itemIndex,
            );
            if (read == null ||
                read.platform != expected.platform ||
                read.sourceId != expected.sourceId ||
                read.itemIndex != expected.itemIndex) {
              existing = null;
            } else {
              reusedProvenance = read;
            }
          }
          if (existing != null) {
            _log('gallery import skipped, already saved: ${job.filename}');
            job.mediaId = existing.id;
            job.savedTitle = existing.title;
            try {
              job.relativePath = existing.relativePath;
            } catch (_) {
              job.relativePath = null;
            }
            // The reused file already carries its own provenance: keep those
            // values instead of writing a new guess into the record.
            job.provenanceItemCount = reusedProvenance?.itemCount;
            job.provenanceCapturedBy = reusedProvenance?.capturedBy;
            job.state = JobState.done;
            job.progress = 1;
            job.saved = true;
            try {
              await file.delete();
            } catch (_) {
              // Temp file cleanup is best effort.
            }
          } else {
            // Embed provenance metadata before saving to gallery (images and videos)
            final saveForTesting = gallerySaveForTesting;
            if (saveForTesting != null) {
              job.fileBytes = await File(path).length();
              final saved = await saveForTesting(path, job);
              job.mediaId = saved.mediaId;
              job.savedTitle = saved.title;
              job.relativePath = saved.relativePath;
              job.state = JobState.done;
              job.progress = 1;
              job.saved = true;
              return;
            }
            final writtenAssetId = await _embedProvenance(
              filePath: path,
              batch: batch,
              job: job,
              existingAssetId: existingAssetId,
              itemIndex: itemIndex ?? job.itemIndex,
            );
            try {
              job.fileBytes = await File(path).length();
            } catch (_) {}
            final finalName = await exportNameFor(
              path,
              batch.postId,
              itemIndex ?? job.itemIndex,
            );

            final outcome = await saveWithConflictHandling(
              filename: finalName,
              tempPath: path,
              album: batch.album,
              pair: job.metadataNotice != null,
              expected: provenanceForBatchItem(
                batch,
                itemIndex: itemIndex ?? job.itemIndex,
              ),
              save: (name) => job.metadataNotice != null
                  ? saveProvenancePair(
                      path,
                      expectedAssetId: writtenAssetId,
                      finalName: name,
                    )
                  : saveToGallery(path, isImage, batch.album, finalName: name),
            );
            final saved = outcome.saved;
            _log('gallery import done: ${job.filename} -> ${saved.mediaId}');
            job.mediaId = saved.mediaId;
            job.savedTitle = saved.title;
            job.relativePath = saved.relativePath;
            job.state = JobState.done;
            job.progress = 1;
            job.saved = true;

            // Store assetId for reuse
            job.assetId = outcome.reusedAssetId ?? writtenAssetId;
          }
        }
      })();
    try {
      await work.timeout(finishTimeoutForTesting ?? finishTimeoutFor(sourceBytes));
    } on TimeoutException {
      _log('gallery import timed out: ${job.filename} bytes=${sourceBytes ?? -1}');
      job.error = '保存超时，请重试';
      job.state = JobState.failed;
      // The album copy keeps running; record its real outcome when it ends
      // instead of leaving an album file without a history row.
      _lateImports[job.key] = work.then(
        (_) => _settleLateImport(batch, job, path),
        onError: (Object e) => _settleLateImport(batch, job, path, error: e),
      ).whenComplete(() {
        // A block body: returning the removed future would await itself.
        _lateImports.remove(job.key);
      });
    } catch (e) {
      job.state = JobState.failed;
      if (isStorageFullError(e)) {
        _markStorageFull(job);
      } else {
        job.error = '$e';
      }
      await _cleanupJobTemp(batch, job, path: path);
    }
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch, recovered: false);
  }

  /// Imports that outlived their timeout, by job key.
  final _lateImports = <String, Future<void>>{};

  Future<void> _settleLateImport(
    DownloadBatch batch,
    DownloadJob job,
    String path, {
    Object? error,
  }) async {
    if (error == null && job.saved && job.mediaId != null) {
      _log('late import done index=${job.itemIndex} media=${job.mediaId}');
      job
        ..state = JobState.done
        ..error = null
        ..errorCode = null
        ..progress = 1;
      batch.historyWritten = false;
      await _persist(batch);
      notifyListeners();
      await _afterTerminal(batch, recovered: false);
      return;
    }
    _log('late import failed index=${job.itemIndex} '
        'reason=${isStorageFullError(error) ? storageFullCode : error?.runtimeType ?? 'unsaved'}');
    if (isStorageFullError(error) && job.state == JobState.failed) {
      _markStorageFull(job);
      await _persist(batch);
      notifyListeners();
    }
    await _cleanupJobTemp(batch, job, path: path);
  }

  Future<XmpProvenance?> _albumProvenance(AssetEntity asset) =>
      (albumProvenanceForTesting ??
              GalleryLocatorService.instance.readAlbumProvenance)(asset);

  /// A complete album copy of [job] (provenance of this post item and, when
  /// the imported size is known, the same MediaStore size), or null.
  Future<AssetEntity?> _completeAlbumCopy(
    DownloadBatch batch,
    DownloadJob job,
  ) async {
    final asset = await _findExistingAlbumAsset(batch, job, refresh: true);
    if (asset == null) return null;
    final read = await _albumProvenance(asset);
    final expected = provenanceForBatchItem(batch, itemIndex: job.itemIndex);
    if (read == null ||
        read.platform != expected.platform ||
        read.sourceId != expected.sourceId ||
        read.itemIndex != expected.itemIndex) {
      _log('retry album copy rejected index=${job.itemIndex} reason=provenance');
      return null;
    }
    final size = await (mediaSizeForTesting ?? _mediaSize)(asset.id, !job.isImage);
    if (job.fileBytes != null && size != job.fileBytes) {
      _log('retry album copy rejected index=${job.itemIndex} reason=size '
          'album=${size ?? -1} expected=${job.fileBytes}');
      return null;
    }
    job.provenanceItemCount = read.itemCount;
    job.provenanceCapturedBy = read.capturedBy;
    return asset;
  }

  static Future<int?> _mediaSize(String mediaId, bool video) async {
    try {
      final size = await const MethodChannel('easysave/media')
          .invokeMethod<num>('mediaSize', {'id': mediaId, 'video': video});
      return size?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// Embed provenance metadata into an image or video file.
  /// Returns the assetId if written, null only when disabled by the user.
  Future<String?> _embedProvenance({
    required String filePath,
    required DownloadBatch batch,
    required DownloadJob job,
    String? existingAssetId,
    required int itemIndex,
  }) async {
    job.metadataNotice = null;
    // Check setting
    final settings = await AppSettings.load();
    if (!settings.saveProvenanceInImages) {
      _log('provenance skipped (setting disabled): ${job.filename}');
      return null;
    }

    // Live Photos write identical pairId (<sourceId>#<itemIndex>) for image and video
    final pairId = job.isLivePhoto ? '${batch.postId}#$itemIndex' : null;

    // Build provenance metadata
    final provenance = provenanceForBatchItem(
      batch,
      itemIndex: itemIndex,
      existingAssetId: existingAssetId,
      pairId: pairId,
    );

    // Embed into file (videos use Mp4WriteMode.rewrite in private cache)
    final sidecar = await prepareDownloadProvenance(filePath, provenance);
    job.provenanceItemCount = provenance.itemCount;
    job.provenanceCapturedBy = provenance.capturedBy;
    if (sidecar) {
      job.metadataNotice = c2paSavedNotice;
      _log('provenance sidecar prepared: ${job.filename}');
    } else {
      _log('provenance embedded and verified: ${job.filename}');
    }
    return provenance.assetId;
  }

  Future<void> _failAttempt(
    DownloadBatch batch,
    DownloadJob job,
    TaskStatusUpdate update,
  ) async {
    final diagnostic = update.exception?.description ?? '';
    if (RegExp(
      r'^REQUEST_(?:URL_REJECTED|HOST_REJECTED|HEADER_REJECTED|COOKIE_DOMAIN_REJECTED|REDIRECT_REJECTED|POLICY_MISSING|EXPIRED) host=[a-z0-9.:-]*$',
    ).hasMatch(diagnostic)) {
      unawaited(DevLog.write('RequestPolicy', diagnostic));
      job.state = JobState.failed;
      job.error = diagnostic.startsWith('REQUEST_EXPIRED ')
          ? expiredMediaMessage
          : '该资源地址不在允许范围内';
      await _persist(batch);
      notifyListeners();
      await _afterTerminal(batch, recovered: false);
      return;
    }
    if (isStorageFullError(diagnostic) || isStorageFullError(update.exception)) {
      _log('download write failed index=${job.itemIndex} reason=$storageFullCode');
      await _failForStorage(batch, job, null);
      return;
    }
    if (job.attempts < maxAttemptsFor(batch, job)) {
      await _enqueueAttempt(batch, job);
      return;
    }
    // A too-small copy kept from an earlier candidate beats no file at all.
    final kept = job.lowResPath;
    if (kept != null && await File(kept).exists()) {
      _log('low resolution copy kept after failure index=${job.itemIndex}');
      job
        ..lowResPath = null
        ..notOriginal = true;
      await _importFile(batch, job, kept, isImage: job.isImage, itemIndex: job.itemIndex);
      return;
    }
    job.state = JobState.failed;
    job.error = update.responseStatusCode != null
        ? '下载失败（HTTP ${update.responseStatusCode}）'
        : (update.exception?.toString() ?? '下载失败');
    await _cleanupJobTemp(batch, job);
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch, recovered: false);
  }

  /// Write history with up to three attempts; a full disk (SQLITE_FULL) is
  /// logged as such. Returns false when every attempt failed.
  Future<bool> _writeHistoryWithRetry(
    DownloadBatch batch,
    Future<void> Function(HistoryDb db) write, {
    required String stage,
  }) async {
    const delays = [Duration(milliseconds: 300), Duration(seconds: 1)];
    for (var attempt = 1; ; attempt++) {
      try {
        await write(await HistoryDb.instance());
        if (attempt > 1) {
          unawaited(DevLog.write('HistoryDb', 'event=write_recovered '
              'stage=$stage post=${batch.postId} attempt=$attempt'));
        }
        return true;
      } catch (e) {
        final reason = isStorageFullError(e) ? storageFullCode : '${e.runtimeType}';
        unawaited(DevLog.write('HistoryDb', 'event=write_retry stage=$stage '
            'post=${batch.postId} attempt=$attempt reason=$reason'));
        if (attempt > delays.length) {
          unawaited(DevLog.write('HistoryDb', 'event=write_failed stage=$stage '
              'post=${batch.postId} reason=$reason'));
          return false;
        }
        await Future<void>.delayed(delays[attempt - 1]);
      }
    }
  }

  final _historyRetries = <String, Timer>{};

  void _scheduleHistoryRetry(DownloadBatch batch) {
    _historyRetries[batch.batchId]?.cancel();
    _historyRetries[batch.batchId] = Timer(historyRetryDelay, () {
      _historyRetries.remove(batch.batchId);
      unawaited(_afterTerminal(batch, recovered: false));
    });
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
    await DownloadClaims.release(batch.batchId);
    if (batch.cancelledByDeletion ||
        await DownloadClaims.isCancelled(batch.batchId)) {
      return;
    }
    if (!batch.historyWritten) {
      batch.historyWritten = true;
      final written = await _writeHistoryWithRetry(
        batch,
        (db) => (historyWriterForTesting ??
            (db, batch, recovered) =>
                writeBatchHistory(db, batch, recovered: recovered))(
          db,
          batch,
          recovered,
        ),
        stage: 'terminal',
      );
      if (!written) {
        // Keep the batch owing its history row; try again later.
        batch.historyWritten = false;
        await _persist(batch);
        _scheduleHistoryRetry(batch);
        return;
      }
      if (batch.succeeded == 0 && batch.failedCount == 0) {
        // Nothing was saved and nothing failed (everything was canceled): do
        // not leave an empty placeholder behind. A failed post stays visible
        // in history with its failure and a retry.
        try {
          await discardEmptyPlaceholder(await HistoryDb.instance(), batch);
        } catch (e) {
          _log('placeholder cleanup failed post=${batch.postId}: $e');
        }
      }
      final db = await HistoryDb.instance();
      final locator = GalleryLocatorService.instance;
      if (locator.hasAccess) {
        unawaited(locator.scanAlbum(force: true));
      }
      unawaited(LocalAutoBackup.performAutoBackup(db: db));
      unawaited(SafService.performAutoBackupToDirectory(db: db));
      if (batch.succeeded > 0) {
        onBatchSuccess.value = batch;
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
    await _finishing[job.key];
    // A timed-out import may still finish its album copy: its outcome decides.
    await _lateImports[job.key];
    if (job.state != JobState.failed && job.state != JobState.canceled) return;
    // Claim the retry synchronously, before parsing or any plugin await.
    job.state = JobState.queued;
    notifyListeners();
    // The batch becomes active again: let its terminal handler write the
    // history record once more when it finishes.
    batch.historyWritten = false;
    // Idempotent retry: an earlier attempt may have completed the album copy
    // and failed afterwards (timeout, history write). Link it, do not fetch.
    try {
      final existing = await _completeAlbumCopy(batch, job);
      if (existing != null) {
        _log('retry reused album copy index=${job.itemIndex} media=${existing.id}');
        job
          ..mediaId = existing.id
          ..savedTitle = existing.title
          ..relativePath = existing.relativePath
          ..state = JobState.done
          ..progress = 1
          ..saved = true
          ..error = null
          ..errorCode = null;
        await _persist(batch);
        notifyListeners();
        await _afterTerminal(batch, recovered: false);
        return;
      }
    } catch (e) {
      _log('retry album lookup failed index=${job.itemIndex}: ${e.runtimeType}');
    }
    job.errorCode = null;
    job.expectedBytes = null;
    job.notOriginal = false;
    try {
      final outcome = await (reparseForTesting?.call(batch.postUrl) ??
          parsePostOutcome(batch.postUrl,
              source: 'download_retry', forceRefresh: true));
      final postIdx = job.itemIndex > 0 ? job.itemIndex - 1 : job.itemIndex;
      final planned = planFiles(outcome.data, [postIdx], (_, _, _) => job.filename)
          .where((file) => file.isImage == job.isImage &&
              file.isLivePhoto == job.isLivePhoto)
          .firstOrNull;
      if (planned != null && planned.urls.isNotEmpty) {
        final policy = _policyFor(batch.platform);
        final declarations = policy.resourcesFor(outcome.data.items[postIdx]);
        final freshResources = [
          for (final url in planned.urls)
            declarations.firstWhere((resource) => resource.url == url,
                orElse: () => policy.rejectResource(url)),
        ];
        // URL, role and authorization are one refreshed resource set. Keeping
        // old declarations would revive old cookie scopes and expired URLs.
        job.urls = planned.urls;
        job.resources = freshResources;
      } else if (needsSessionDownload(batch, job)) {
        throw const SessionDownloadException(interruptedMediaMessage);
      }
    } catch (_) {
      if (needsSessionDownload(batch, job)) {
        job.state = JobState.failed;
        job.error = interruptedMediaMessage;
        await _persist(batch);
        notifyListeners();
        return;
      }
      // Keep the stored URLs and try once more below for non-session media.
    }
    job.attempts = 0;
    job.lastStatusCode = null;
    try {
      await _enqueueAttempt(batch, job);
    } catch (_) {
      job.state = JobState.failed;
      job.error = '加入下载队列失败，请重试';
    }
    await _persist(batch);
    notifyListeners();
  }

  /// Retry every failed job in the batch (manual "重试" from the preview page).
  Future<void> retryBatch(DownloadBatch batch) async {
    final failed = batch.jobs.where((j) => j.state == JobState.failed).toList();
    for (final job in failed) {
      await retryJob(batch, job);
    }
  }

  Future<void> cancelBatch(DownloadBatch batch) async {
    if (batch.source != owner &&
        batch.jobs.any((j) => needsSessionDownload(batch, j))) {
      for (final job in batch.jobs.where((j) => !j.isTerminal)) {
        await cancelJob(batch, job);
      }
      return;
    }
    for (final job in batch.jobs) {
      if (needsSessionDownload(batch, job) && !job.isTerminal) {
        job.state = JobState.canceled;
        await _sessionTransfers[job.key]?.cancel();
      }
    }
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
      if (job.state == JobState.queued ||
          job.state == JobState.active ||
          job.state == JobState.paused) {
        job.state = JobState.canceled;
      }
    }
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch, recovered: false);
  }

  /// User-confirmed history deletion also cancels foreign engine work. Native
  /// controls stop pending starts; the database barrier rejects late writes.
  Future<void> cancelPostDownloads(String platform, String postId) async {
    await DownloadClaims.cancelPost(platform, postId);
    final ids = <String>[];
    for (final batch in await liveBatches()) {
      if (batch.platform != platform ||
          batch.postId != postId ||
          batch.isTerminal) {
        continue;
      }
      batch.cancelledByDeletion = true;
      batch.historyWritten = true;
      for (final job in batch.jobs.where((job) => !job.isTerminal)) {
        job.state = JobState.canceled;
        if (job.currentTaskId != null) ids.add(job.currentTaskId!);
        final transfer = _sessionTransfers[job.key];
        if (transfer != null) await transfer.cancel();
        if (needsSessionDownload(batch, job)) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('session_cancel_${job.key}', true);
        }
      }
      _batches[batch.batchId] = batch;
      await _persist(batch);
      await DownloadClaims.release(batch.batchId);
    }
    notifyListeners();
    if (ids.isNotEmpty) {
      await FileDownloader()
          .cancelTasksWithIds(ids)
          .timeout(const Duration(seconds: 2));
    }
  }

  /// Synchronous cancellation intent: no plugin or other engine can delay it.
  void markPostDeletion(String platform, String postId) {
    for (final batch in _batches.values) {
      if (SiteRegistry.current.sameSite(batch.platform, platform) &&
          batch.postId == postId &&
          !batch.isTerminal) {
        batch.cancelledByDeletion = true;
      }
    }
  }

  /// Pause a batch: running files are stopped (they restart from zero on
  /// resume, the CDNs do not reliably support ranges) and the watchdog leaves
  /// them alone until [resumeBatch].
  Future<void> pauseBatch(DownloadBatch batch) async {
    if (batch.jobs.any((j) => needsSessionDownload(batch, j))) {
      await cancelBatch(batch);
      return;
    }
    batch = await _ownedOrAdopt(batch);
    final ids = <String>[];
    for (final job in batch.jobs) {
      if (job.state != JobState.queued && job.state != JobState.active) {
        continue;
      }
      final id = job.currentTaskId;
      if (id != null) ids.add(id);
      // State first, so the late `canceled` update of the task is ignored.
      job.state = JobState.paused;
      job.progress = 0;
      if (needsSessionDownload(batch, job)) {
        await _sessionTransfers[job.key]?.cancel();
      }
    }
    await _persist(batch);
    notifyListeners();
    if (ids.isNotEmpty) {
      try {
        await FileDownloader().cancelTasksWithIds(ids);
      } catch (_) {
        // Best effort; the paused state already shields the job.
      }
    }
    unawaited(_refreshNotification(batch));
  }

  /// Re-enqueue every paused file of a batch.
  Future<void> resumeBatch(DownloadBatch batch) async {
    batch = await _ownedOrAdopt(batch);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final job in batch.jobs.where((j) => j.state == JobState.paused)) {
      job.attempts = 0;
      job.progress = 0;
      job.lastProgressAt = now;
      try {
        await _enqueueAttempt(batch, job);
      } catch (e) {
        _log('resume enqueue failed ${job.key}: $e');
        job.state = JobState.failed;
        job.error = '加入下载队列失败';
      }
    }
    await _persist(batch);
    notifyListeners();
    if (batch.isTerminal) await _afterTerminal(batch, recovered: false);
  }

  /// Retry everything that is not finished: failed files (re-parsed for fresh
  /// links) and files that are stuck, queued or paused (plain re-enqueue).
  Future<void> restartBatch(DownloadBatch batch) async {
    if (batch.source != owner &&
        !batch.isStalledAt(DateTime.now().millisecondsSinceEpoch) &&
        batch.jobs.any(
          (j) => needsSessionDownload(batch, j) && !j.isTerminal,
        )) {
      return;
    }
    batch = await _ownedOrAdopt(batch);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final job in batch.jobs.toList()) {
      if (needsSessionDownload(batch, job) && !job.saved) {
        if (job.state == JobState.active || job.state == JobState.queued) {
          await cancelJob(batch, job);
        }
        await retryJob(batch, job);
        continue;
      }
      switch (job.state) {
        case JobState.failed:
          await retryJob(batch, job);
        case JobState.queued:
        case JobState.active:
        case JobState.paused:
          final id = job.currentTaskId;
          if (id != null && job.state != JobState.paused) {
            try {
              await FileDownloader().cancelTaskWithId(id);
            } catch (_) {}
          }
          job.attempts = 0;
          job.progress = 0;
          job.lastProgressAt = now;
          try {
            await _enqueueAttempt(batch, job);
          } catch (e) {
            _log('restart enqueue failed ${job.key}: $e');
            job.state = JobState.failed;
            job.error = '加入下载队列失败';
          }
        case JobState.done:
        case JobState.canceled:
          break;
      }
    }
    await _persist(batch);
    notifyListeners();
    if (batch.isTerminal) await _afterTerminal(batch, recovered: false);
  }

  /// Cancel one file of a batch (queue page / preview page).
  Future<void> cancelJob(DownloadBatch batch, DownloadJob job) async {
    await _finishing[job.key];
    if (batch.source != owner &&
        needsSessionDownload(batch, job) &&
        !batch.isStalledAt(DateTime.now().millisecondsSinceEpoch)) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('session_cancel_${job.key}', true);
      return;
    }
    batch = await _ownedOrAdopt(batch);
    job = batch.jobs.firstWhere((j) => j.key == job.key, orElse: () => job);
    if (job.saved) return; // The album write won the race; keep it completed.
    if (job.isTerminal) return;
    if (needsSessionDownload(batch, job)) {
      job.state = JobState.canceled;
      await _sessionTransfers[job.key]?.cancel();
    }
    final id = job.currentTaskId;
    if (id != null) {
      try {
        await FileDownloader().cancelTaskWithId(id);
      } catch (_) {
        // Best effort; the state change below is what matters.
      }
    }
    job.state = JobState.canceled;
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch, recovered: false);
  }

  /// Cancel a batch and drop it from the queue, including its snapshot. An
  /// empty placeholder history record is removed by [_afterTerminal]; a post
  /// that already has saved files stays in the history.
  Future<void> removeBatch(DownloadBatch batch) async {
    final owned = await _ownedOrAdopt(batch);
    if (!owned.isTerminal) await cancelBatch(owned);
    _batches.remove(owned.batchId);
    _lastShownPercent.remove(owned.batchId);
    await _removeSnapshot(owned.batchId);
    unawaited(_cancelNotification(owned));
    notifyListeners();
  }

  /// Cancel every unfinished batch, then drop them (restore-anyway path).
  Future<void> cancelAll() async {
    for (final b in await liveBatches()) {
      if (b.isTerminal) continue;
      await removeBatch(b);
    }
  }

  /// Take over a batch whose owner engine is gone or stuck, so this engine's
  /// task updates, watchdog and cancel logic apply to it.
  Future<DownloadBatch> forceAdopt(DownloadBatch batch) async {
    if (batch.source != owner &&
        !batch.isStalledAt(DateTime.now().millisecondsSinceEpoch) &&
        batch.jobs.any(
          (j) => needsSessionDownload(batch, j) && !j.isTerminal,
        )) {
      return batch;
    }
    if (batch.source == DownloadManager.owner) {
      _batches[batch.batchId] ??= batch;
      return _batches[batch.batchId]!;
    }
    final mine = batch.copyOwnedBy(DownloadManager.owner);
    // Give the watchdog a fresh window instead of judging old timestamps.
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final j in mine.jobs) {
      if (!j.isTerminal) j.lastProgressAt = now;
    }
    _batches[mine.batchId] = mine;
    _log('force adopt batch ${mine.batchId} (was ${batch.source})');
    await _persist(mine);
    notifyListeners();
    return mine;
  }

  Future<DownloadBatch> _ownedOrAdopt(DownloadBatch batch) async {
    final known = _batches[batch.batchId];
    if (known != null && known.source == DownloadManager.owner) return known;
    if (batch.source == DownloadManager.owner) {
      _batches[batch.batchId] = batch;
      return batch;
    }
    return forceAdopt(batch);
  }

  Future<void> _removeSnapshot(String batchId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_batchKey(batchId));
      final index = prefs.getStringList(_batchIndexKey) ?? [];
      if (index.remove(batchId)) {
        await prefs.setStringList(_batchIndexKey, index);
      }
    } catch (_) {
      // Best effort.
    }
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
      await prefs.reload();
      final index = prefs.getStringList(_batchIndexKey) ?? [];
      var changed = false;
      var adopted = 0;
      for (final batchId in index) {
        if (prefs.getBool('$_dismissedPrefix$batchId') == true) continue;
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
        // Foreground resume must not replace objects still owned by live Dart
        // transfers with older persisted copies.
        if (_batches[batchId]?.jobs.any(
              (j) => _sessionTransfers.containsKey(j.key),
            ) ??
            false) {
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
    if (batch.jobs.every(
      (j) => j.isTerminal || needsSessionDownload(batch, j),
    )) {
      return true;
    }
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
    for (final job in batch.jobs) {
      if (recoverSessionJob(batch, job)) {
        final file = await _sessionFile(job);
        if (await file.exists()) await file.delete();
        changed = true;
      }
    }
    if (changed) await _persist(batch);
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
        if (job.attempts < maxAttemptsFor(batch, job)) {
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
    for (final job in batch.jobs.where((j) => j.state == JobState.failed)) {
      final error = job.error ?? '';
      final reason = job.errorCode == storageFullCode ? storageFullCode
          : error.contains('403') ? 'HTTP_403' : error.contains('404') ? 'HTTP_404'
          : error.contains('超时') || error.contains('Timeout') ? 'TIMEOUT'
          : error.contains('REQUEST_') ? 'POLICY'
          : error.contains('保存') || error.contains('import') ? 'IMPORT'
          : 'TRANSFER';
      unawaited(DevLog.write('V16DL', 'item failed index=${job.itemIndex} reason=$reason'));
    }
    try {
      batch.updatedAt = DateTime.now().millisecondsSinceEpoch;
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (prefs.getBool('$_dismissedPrefix${batch.batchId}') == true) return;
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
  final imageUrls = orderedMediaUrls(post, item);
  if (item.type == 'live' && item.videoUrl != null) {
    return [imageUrls.first, item.videoUrl!];
  }
  if (item.type == 'video') {
    final url = item.videoUrl ?? item.url;
    return item.videoUrl != null ? [url] : imageUrls;
  }
  return imageUrls;
}
