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
import 'dev_download_failure.dart';
import 'download_failure_snapshots.dart';
import 'download_status_display.dart';
import 'gallery_locator_service.dart';
import 'history_db.dart';
import 'history_io.dart';
import 'host_bridge.dart';
import 'image_format_preference.dart';
import 'image_dimensions.dart';
import 'live_pairs.dart';
import 'network_status.dart';
import 'image_decode_probe.dart';
import 'media_content_type.dart';
import 'mp4_audio_probe.dart';
import 'transfer_headers.dart';
import 'storage_guard.dart';
import 'parse_service.dart';
import 'saver.dart';
import 'download_provenance.dart';
import 'export_names.dart';
import 'download_claims.dart';
import 'provenance_pair.dart';
import 'save_collision.dart';
import 'session_media_download.dart';
import 'resumable_download_store.dart';
import 'media_request_policy.dart';
import 'site_registry.dart';
import 'settings.dart';
import 'transfer_client.dart';

/// Max download attempts per file, first try included. The plugin's native
/// retries stay at 0 so this counter is the single source of truth.
const int kMaxAttempts = 3;

/// Absolute ceiling on attempts per file, whatever the site rule or the number
/// of stored candidates says: no item may keep retrying forever.
const int kMaxAttemptsHardCap = 6;

/// Ceiling on the attempts of a still: every stored candidate once plus the
/// backoff retries each of them may use on a connection reset or a timeout.
const int kMaxStillAttemptsHardCap = 24;

/// Absolute ceiling on the attempts of one file, whatever its candidates:
/// [kMaxAttemptsHardCap] candidates times one transfer each plus the
/// [kCandidateRetryLimit] backoff retries every transfer may use.
const int kAttemptHardCap = 24;

/// Backoff before each retry of the *same* candidate after a connection reset
/// or a timeout: 0.6s, 1.2s, 2.4s, then the item switches to its next
/// candidate. The CDN drops a connection on its own edge often enough that a
/// single retry was not worth the switch it cost.
const List<Duration> kCandidateRetryBackoffs = [
  Duration(milliseconds: 600),
  Duration(milliseconds: 1200),
  Duration(milliseconds: 2400),
];

/// How many times one candidate may be retried on reset/timeout.
const int kCandidateRetryLimit = 3;

/// First backoff, kept as the documented short wait of a reset retry.
const Duration kResetRetryBackoff = Duration(milliseconds: 600);

/// Machine-readable mark of a file the request policy refused. Such a job is
/// final: the reader that produced it is re-checked on every hop, so another
/// attempt asks the same CDN the same forbidden question.
const String policyRejectedCode = 'REQUEST_POLICY_REJECTED';

/// Diagnostic shapes a native consumer may report for a policy rejection. Only
/// a fixed code and a hostname may be matched, never a URL or a header value.
final RegExp _diagnosticPolicyCode = RegExp(
  r'^REQUEST_(?:URL_REJECTED|HOST_REJECTED|HEADER_REJECTED|COOKIE_DOMAIN_REJECTED|REDIRECT_REJECTED|POLICY_MISSING|EXPIRED) host=[a-z0-9.:-]*$',
);

/// Whether [job] must never be enqueued again in this batch.
bool isPolicyRejected(DownloadJob job) => job.errorCode == policyRejectedCode;

/// Machine-readable mark of a connectivity failure (v1.11 batch 3): no network,
/// DNS failure, refused or reset connection, timeout, TLS handshake. It is a
/// statement about the network, never about the media, so it must never be
/// reported as a content failure.
const String networkFailureCode = 'NETWORK';

/// Machine-readable mark of the developer "下一次下载模拟失败" switch. Final by
/// design: the point is to exercise the failure path, so nothing may re-download
/// the file behind the user's back (a manual retry clears it and downloads).
const String simulatedFailureCode = 'SIMULATED';

/// Transport failure causes that mean the network could not be reached. They
/// are the same tokens [DownloadManager._failureCause] logs.
const Set<String> kNetworkFailureCauses = {
  'network',
  'dns',
  'refused',
  'reset',
  'timeout',
  'tls',
  'unreachable',
};

/// Whether the transport failure [cause] is a connectivity failure.
bool isNetworkCause(String cause) => kNetworkFailureCauses.contains(cause);

/// Fixed cause token of a caught connection error: `dns`, `refused`, `reset`,
/// `timeout`, `tls`, `unreachable` or `network`. The error message itself is
/// never returned — on Android it embeds the host name and the request URL.
String? networkCauseOf(Object error) {
  final text = error is SocketException
      ? '${error.message} ${error.osError?.message ?? ''}'
      : error.toString();
  bool has(String pattern) =>
      RegExp(pattern, caseSensitive: false).hasMatch(text);
  if (error is TimeoutException || has(r'timeout|timed out|超时')) {
    return 'timeout';
  }
  if (has(r'unknownhost|unresolved|gaierror|nodename|failed host lookup')) {
    return 'dns';
  }
  if (has(r'ssl|certificate|handshake|certpath|\btls\b')) return 'tls';
  if (has(r'connection refused|econnrefused')) return 'refused';
  if (has(r'noroutetohost|enetunreach|ehostunreach|unreachable')) {
    return 'unreachable';
  }
  if (has(r'econnreset|connection reset|epipe|broken pipe|connection closed')) {
    return 'reset';
  }
  if (error is SocketException ||
      error is HttpException ||
      error is TlsException) {
    return 'network';
  }
  return null;
}

/// Whether a retry of the same file cannot change anything: the request policy
/// refused the URL, or the developer switch failed it on purpose.
bool isFinalFailure(DownloadJob job) =>
    isPolicyRejected(job) || job.errorCode == simulatedFailureCode;

/// How often a file waiting for the network is looked at again while the system
/// still reports a connection (a connection that breaks while the system thinks
/// it is up produces no connectivity event, so the wait needs its own clock).
const Duration kNetworkRetryInterval = Duration(seconds: 5);

/// Consecutive waits of one file while the system claimed to be online. Past
/// this the file fails with [networkFailureCode] instead of waiting forever.
const int kNetworkWaitLimit = 12;

/// Overrides the backoff ladder in unit tests.
@visibleForTesting
List<Duration> candidateRetryBackoffsForTesting = kCandidateRetryBackoffs;

/// Wait before retry number [retry] (1-based) of the same candidate. Past the
/// list the last value is reused, so a raised [kCandidateRetryLimit] still has
/// a bounded wait.
Duration candidateBackoffFor(int retry) {
  final ladder = candidateRetryBackoffsForTesting;
  if (ladder.isEmpty) return kResetRetryBackoff;
  final index = retry <= 1 ? 0 : (retry - 1).clamp(0, ladder.length - 1);
  return ladder[index];
}

int maxAttemptsFor(DownloadBatch batch, DownloadJob job) =>
    (SiteRegistry.current.byId(batch.platform)?.data['download']
            as Map?)?['transport'] ==
        'session'
    ? job.urls.length
    : kMaxAttempts;

/// Bound of the transfer attempts of [job]: the site rule, never above
/// [kMaxAttemptsHardCap].
int attemptCapFor(DownloadBatch batch, DownloadJob job) {
  final base = maxAttemptsFor(batch, job);
  return base > kMaxAttemptsHardCap ? kMaxAttemptsHardCap : base;
}

/// Bound of the candidate switches of [job]: one attempt per stored URL, never
/// above [kMaxAttemptsHardCap].
int candidateCapFor(DownloadJob job) {
  final count = job.urls.isEmpty ? 1 : job.urls.length;
  return count > kMaxAttemptsHardCap ? kMaxAttemptsHardCap : count;
}

/// Bound of the transfer attempts of [job]: a still tries every stored
/// candidate once (original-resolution candidates first, preview-size ones
/// last) so a dead first candidate cannot cost the item its original, plus the
/// [kCandidateRetryLimit] backoff retries each candidate may use on a
/// connection reset or a timeout. A video keeps the site rule of
/// [attemptCapFor] with the same retry allowance.
int retryCapFor(DownloadBatch batch, DownloadJob job) {
  final base = job.isImage ? candidateCapFor(job) : attemptCapFor(batch, job);
  final cap = base * (1 + kCandidateRetryLimit);
  return cap > kAttemptHardCap ? kAttemptHardCap : cap;
}

/// Whether the candidate [job] just downloaded is a preview-size derivative,
/// i.e. its file is only kept because every original-resolution candidate of
/// the item failed. Such a still is saved with the existing "非原图" mark.
bool importsPreviewOnly(DownloadJob job) =>
    job.isImage &&
    isPreviewStillCandidate(DownloadManager.candidateUrlOf(job) ?? '');

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
  // A file that was parked waiting for the connection is still meaningfully
  // waiting after a restart: it never had a transfer that could be interrupted
  // (v1.11 batch 3). It resumes with the connection, not with a re-parse.
  if (job.isWaitingForNetwork) return false;
  job.state = JobState.failed;
  job.progress = 0;
  job.currentTaskId = null;
  job.error = interruptedMediaMessage;
  return true;
}

/// Extracts the round number from a taskId formatted as `...-r<N>...`.
/// Returns null if no round marker is found.
int? parseTaskRound(String taskId) {
  final match = RegExp(r'-r(\d+)').firstMatch(taskId);
  if (match != null) {
    return int.tryParse(match.group(1)!);
  }
  return null;
}

/// Whether a downloaded video at [path] lacks a sound track while a later
/// candidate URL of [job] is still untried. Images, Live Photo motion clips,
/// the last candidate and files that cannot be read as MP4 are kept.
Future<bool> shouldRetryForMissingAudio(
  DownloadJob job,
  String path, {
  Future<bool?> Function(String path)? probe,
}) async {
  if (job.isImage ||
      job.isLivePhoto ||
      DownloadManager.candidateIndexOf(job) + 1 >= job.urls.length) {
    return false;
  }
  final hasAudio = await (probe ?? (path) => mp4HasAudioTrack(File(path)))(
    path,
  );
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

/// The declared resource of [url], or one cloned from the declared resource of
/// the same host and path when [url] is a candidate this build derived from it
/// (the CDN's JPEG original). Nothing else may invent a resource: an unknown
/// URL is still rejected by the policy.
MediaRequestResource resourceForCandidate(
  MediaRequestPolicy policy,
  List<MediaRequestResource> declared,
  String url,
) {
  for (final resource in declared) {
    if (resource.url == url) return resource;
  }
  final target = Uri.tryParse(url);
  if (target != null && target.hasAuthority) {
    for (final base in declared) {
      final baseUri = Uri.tryParse(base.url);
      if (baseUri == null) continue;
      if (baseUri.host == target.host && baseUri.path == target.path) {
        return MediaRequestResource(
          role: base.role,
          url: url,
          fallbackFor: base.fallbackFor,
          request: base.request,
        );
      }
    }
  }
  policy.rejectResource(url);
}

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
  bool historyWritten = false,
  bool isTerminal = false,
  int succeeded = 0,
}) {
  if (batchSource == owner) return false;
  if (settledBy != null) return false;
  if (historyWritten) return false;
  if (isTerminal && succeeded > 0) return false;
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

/// Own live batches win over their (older) snapshot copies; foreign batches
/// prefer the newest snapshot from the owning engine; newest first.
List<DownloadBatch> mergeBatchViews(
  Iterable<DownloadBatch> own,
  Iterable<DownloadBatch> snapshots,
) {
  final byId = <String, DownloadBatch>{};
  for (final b in snapshots) {
    byId[b.batchId] = b;
  }
  for (final b in own) {
    if (b.usesNewTransferPipeline) {
      final existing = byId[b.batchId];
      if (existing == null || b.updatedAt >= existing.updatedAt) {
        byId[b.batchId] = b;
      }
      continue;
    }
    if (b.source == DownloadManager.owner || !byId.containsKey(b.batchId)) {
      byId[b.batchId] = b;
    }
  }
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
  if (job.state != JobState.failed && job.state != JobState.paused) return null;
  final error = job.error ?? '';
  if (job.errorCode == storageFullCode || isStorageFullError(error)) {
    return '存储空间不足';
  }
  if (job.state != JobState.failed) return null;
  if (job.errorCode == simulatedFailureCode) return '模拟失败';
  if (job.errorCode == networkFailureCode) return '网络不可用';
  final status =
      job.lastStatusCode ??
      int.tryParse(RegExp(r'HTTP (\d{3})').firstMatch(error)?.group(1) ?? '');
  if (status != null) return 'HTTP $status';
  if (error.contains('超时')) return '保存超时';
  if (error.contains('过期')) return '链接已过期';
  if (error.contains('允许范围')) return '地址不被允许';
  if (error.contains('网络')) return '网络不可用';
  if (error.contains('文件丢失')) return '文件丢失';
  if (error.contains('来源信息')) return '来源信息写入失败';
  return '下载出错';
}

/// Notification text for one failed file: the per-item sentence with the short
/// reason appended ("第3项实况的静态图保存失败（来源信息写入失败）"). Never a raw
/// exception such as `Bad state: …`.
String userFacingFailureReason(DownloadJob job) {
  // The simulated failure already reads exactly like the sentence the user
  // should see; appending the reason again would stutter.
  if (job.errorCode == simulatedFailureCode) {
    return job.error ?? '下载失败（模拟失败）';
  }
  final detail = shortFailureReason(job);
  final text = DownloadManager.failureTextFor(
    job,
    saving: detail == '来源信息写入失败' || detail == '保存超时',
  );
  if (detail == null || detail == '下载出错') return text;
  return '$text（$detail）';
}

/// `paused` and `waitingNetwork` are appended last: job states are persisted by
/// index.
enum JobState { queued, active, done, failed, canceled, paused, waitingNetwork }

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

  /// Index into [urls] of the candidate being tried. Unlike [attempts], this
  /// advances only to a *different* candidate: a backoff retry of the same
  /// candidate keeps it, so connection reset/timeout does not spend a switch.
  int candidateIndex = 0;

  /// How many backoff retries [candidateIndex] already used on a connection
  /// reset or a timeout (0..[kCandidateRetryLimit]). Cleared whenever
  /// [candidateIndex] advances.
  int candidateRetryCount = 0;
  int round = 0;
  String? currentTaskId;
  bool saved = false;
  String? error;
  int? lastStatusCode;

  /// Machine-readable failure code ([storageFullCode]) next to [error].
  String? errorCode;

  /// Content-Length of the media when known (storage preflight).
  int? expectedBytes;

  /// Bytes downloaded so far for byte-weighted batch progress.
  int bytesRead = 0;

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

  /// The saved file carries no provenance because its container cannot hold it
  /// (HEIC / AVIF / GIF). History still writes the pairId, so a Live photo
  /// still pairs with its clip.
  bool provenanceSkipped = false;

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
  String? md5;
  bool usesNewTransferPipeline = false;
  String? transferJobId;
  String? transferState;
  int transferRequiredBytes = 0;
  int transferAvailableBytes = 0;

  /// Resume state persisted across failures, network waiting, and app restarts
  int? resumeStartByte;
  String? resumeTempPath;
  String? resumeEtag;

  /// Track consecutive failure reason to prevent infinite loops (Build 76 B5).
  String? lastFailReason;
  int consecutiveFailCount = 0;

  /// prov:itemCount and prov:capturedBy of the provenance actually written into
  /// the file (or read back from the reused file). History stores these so the
  /// backup export can report what the file says instead of guessing.
  int? provenanceItemCount;
  String? provenanceCapturedBy;

  /// Last time this job showed life (enqueued, progress or status update), in
  /// epoch ms. The watchdog and the stale-batch check use it; 0 = unknown
  /// (snapshots written before this field existed).
  int lastProgressAt = 0;

  /// Epoch ms when download reached 100% or complete status was received.
  int? downloadCompleteAt;
  int? waitCompleteMs;
  int? provenanceMs;
  int? provenanceBytesWritten;
  int? importCopyMs;
  int? importBytes;
  String? importThread;

  /// 3a: True when the bytes are fully downloaded and the job is in the finishing
  /// stage (embedding provenance, gallery import, history writing). During this
  /// stage, cancellation or late network drops cannot abort the job.
  bool isFinishing = false;

  /// Current saving sub-phase during finishing: '写入来源信息' or '复制到相册'.
  String? savingPhase;

  /// Whether user explicitly requested cancellation (v1.12 build 73).
  /// Internal cancellation (native reset, watchdog, duplicate enqueue) leaves
  /// this false so temporary files and resume data are never deleted.
  bool userCancelRequested = false;

  /// Whether user manually paused the download (v1.12 build 73).
  bool userPaused = false;

  /// Number of auto-resume retries attempted so far (0..5).
  int autoResumeRetry = 0;

  /// Task IDs of previous rounds for this job (v1.12 build 74).
  /// Used to ensure only one native task is active at any time.
  List<String> previousTaskIds = <String>[];

  bool get isTerminal =>
      state == JobState.done ||
      state == JobState.failed ||
      state == JobState.canceled;

  /// The file cannot be transferred until the connection is back (v1.11 batch
  /// 3). A wait is not a failure: it spends no attempt and writes no error.
  bool get isWaitingForNetwork => state == JobState.waitingNetwork;

  Map<String, Object?> toJson() => {
    'lastProgressAt': lastProgressAt,
    'progress': progress,
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
    if (round > 0) 'round': round,
    if (candidateIndex > 0) 'candidateIndex': candidateIndex,
    if (candidateRetryCount > 0) 'candidateRetryCount': candidateRetryCount,
    'currentTaskId': currentTaskId,
    'saved': saved,
    'error': error,
    'lastStatusCode': lastStatusCode,
    if (errorCode != null) 'errorCode': errorCode,
    if (expectedBytes != null) 'expectedBytes': expectedBytes,
    if (bytesRead > 0) 'bytesRead': bytesRead,
    if (fileBytes != null) 'fileBytes': fileBytes,
    if (expectedWidth != null) 'expectedWidth': expectedWidth,
    if (expectedHeight != null) 'expectedHeight': expectedHeight,
    if (lowResPath != null) 'lowResPath': lowResPath,
    if (lowResPixels != null) 'lowResPixels': lowResPixels,
    if (provenanceSkipped) 'provenanceSkipped': true,
    if (notOriginal) 'notOriginal': true,
    'assetId': assetId,
    'mediaId': mediaId,
    'savedTitle': savedTitle,
    'metadataNotice': metadataNotice,
    'relativePath': relativePath,
    if (md5 != null) 'md5': md5,
    if (usesNewTransferPipeline) 'usesNewTransferPipeline': true,
    if (transferJobId != null) 'transferJobId': transferJobId,
    if (transferState != null) 'transferState': transferState,
    if (transferRequiredBytes > 0)
      'transferRequiredBytes': transferRequiredBytes,
    if (transferAvailableBytes > 0)
      'transferAvailableBytes': transferAvailableBytes,
    if (resumeStartByte != null) 'resumeStartByte': resumeStartByte,
    if (resumeTempPath != null) 'resumeTempPath': resumeTempPath,
    if (resumeEtag != null) 'resumeEtag': resumeEtag,
    if (lastFailReason != null) 'lastFailReason': lastFailReason,
    if (consecutiveFailCount > 0) 'consecutiveFailCount': consecutiveFailCount,
    if (isFinishing) 'isFinishing': true,
    if (savingPhase != null) 'savingPhase': savingPhase,
    if (userCancelRequested) 'userCancelRequested': true,
    if (userPaused) 'userPaused': true,
    if (autoResumeRetry > 0) 'autoResumeRetry': autoResumeRetry,
    if (previousTaskIds.isNotEmpty) 'previousTaskIds': previousTaskIds,
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
    job.progress = (map['progress'] as num?)?.toDouble() ?? 0.0;
    job.attempts = (map['attempts'] as num).toInt();
    job.round = (map['round'] as num?)?.toInt() ?? 0;
    final storedCandidate = (map['candidateIndex'] as num?)?.toInt() ?? 0;
    final lastCandidate = job.urls.isEmpty ? 0 : job.urls.length - 1;
    job.candidateIndex = storedCandidate < 0
        ? 0
        : (storedCandidate > lastCandidate ? lastCandidate : storedCandidate);
    // Snapshots written before v1.10.3 stored a single retry as a boolean.
    job.candidateRetryCount =
        (map['candidateRetryCount'] as num?)?.toInt() ??
        (map['candidateRetryUsed'] == true ? 1 : 0);
    job.currentTaskId = map['currentTaskId'] as String?;
    job.saved = map['saved'] as bool? ?? false;
    job.error = map['error'] as String?;
    job.lastStatusCode = (map['lastStatusCode'] as num?)?.toInt();
    job.errorCode = map['errorCode'] as String?;
    job.expectedBytes = (map['expectedBytes'] as num?)?.toInt();
    job.bytesRead = (map['bytesRead'] as num?)?.toInt() ?? 0;
    job.fileBytes = (map['fileBytes'] as num?)?.toInt();
    job.expectedWidth = (map['expectedWidth'] as num?)?.toInt();
    job.expectedHeight = (map['expectedHeight'] as num?)?.toInt();
    job.lowResPath = map['lowResPath'] as String?;
    job.lowResPixels = (map['lowResPixels'] as num?)?.toInt();
    // Snapshots written by build 40 may carry `pendingStillPath`; the pipeline
    // no longer parks an unwritable still aside, so the key is simply ignored.
    job.provenanceSkipped = map['provenanceSkipped'] as bool? ?? false;
    job.notOriginal = map['notOriginal'] as bool? ?? false;
    job.assetId = map['assetId'] as String?;
    job.mediaId = map['mediaId'] as String?;
    job.savedTitle = map['savedTitle'] as String?;
    job.metadataNotice = map['metadataNotice'] as String?;
    job.relativePath = map['relativePath'] as String?;
    job.md5 = map['md5'] as String?;
    job.usesNewTransferPipeline =
        map['usesNewTransferPipeline'] as bool? ?? false;
    job.transferJobId = map['transferJobId'] as String?;
    job.transferState = map['transferState'] as String?;
    job.transferRequiredBytes =
        (map['transferRequiredBytes'] as num?)?.toInt() ?? 0;
    job.transferAvailableBytes =
        (map['transferAvailableBytes'] as num?)?.toInt() ?? 0;
    job.resumeStartByte = (map['resumeStartByte'] as num?)?.toInt();
    job.resumeTempPath = map['resumeTempPath'] as String?;
    job.resumeEtag = map['resumeEtag'] as String?;
    job.lastFailReason = map['lastFailReason'] as String?;
    job.consecutiveFailCount =
        (map['consecutiveFailCount'] as num?)?.toInt() ?? 0;
    job.provenanceItemCount = (map['provenanceItemCount'] as num?)?.toInt();
    job.provenanceCapturedBy = map['provenanceCapturedBy'] as String?;
    job.isFinishing = map['isFinishing'] as bool? ?? false;
    job.savingPhase = map['savingPhase'] as String?;
    job.userCancelRequested = map['userCancelRequested'] as bool? ?? false;
    job.userPaused = map['userPaused'] as bool? ?? false;
    job.autoResumeRetry = (map['autoResumeRetry'] as num?)?.toInt() ?? 0;
    job.previousTaskIds =
        (map['previousTaskIds'] as List?)?.cast<String>().toList() ??
        <String>[];
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
    this.formatPref = ImageFormatPreference.compat,
    this.jpegFallbackPlanned = false,
    String? pipeline,
    bool usesNewTransferPipeline = false,
  }) : startedAt = startedAt ?? DateTime.now().microsecondsSinceEpoch,
       pipeline =
           pipeline ??
           (usesNewTransferPipeline ? pipelineTransfer : pipelineLegacy);

  static const String pipelineLegacy = 'legacy';
  static const String pipelineTransfer = 'transfer';

  String pipeline;
  bool get usesNewTransferPipeline => pipeline == pipelineTransfer;

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

  /// The 「图片格式」in force when this batch was planned (v1.11 batch 3). Kept
  /// with the batch so the completion note and a resumed download describe the
  /// same setting, and so a snapshot from before the setting existed reads as
  /// [ImageFormatPreference.compat].
  ImageFormatPreference formatPref;

  /// At least one still of this batch had no jpeg candidate although JPEG only
  /// was asked for, so the compat ladder was used for it.
  bool jpegFallbackPlanned;

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
  String source;
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

  /// High-water mark for transfer pipeline overall progress so it never
  /// decreases during sequential enqueue, concurrent completion, or retries.
  double _maxTransferProgress = 0.0;

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
    if (usesNewTransferPipeline) {
      final raw = computeTransferBatchOverallProgress(live);
      if (raw > _maxTransferProgress) {
        _maxTransferProgress = raw;
      }
      return _maxTransferProgress;
    }
    var sum = 0.0;
    for (final j in live) {
      sum += j.state == JobState.done ? 1.0 : j.progress.clamp(0.0, 1.0);
    }
    return sum / live.length;
  }

  /// Unified overall progress formula for the new transfer pipeline:
  /// `(doneCount + sum(inProgressRatio)) / N`.
  /// Done jobs count as 1.0; not-started or unknown-total jobs count as 0.0.
  static double computeTransferBatchOverallProgress(
    List<DownloadJob> liveJobs, {
    int? totalCount,
  }) {
    final n = (totalCount != null && totalCount > liveJobs.length)
        ? totalCount
        : liveJobs.length;
    if (n <= 0) return 0.0;
    var sum = 0.0;
    for (final j in liveJobs) {
      if (j.state == JobState.done) {
        sum += 1.0;
        continue;
      }
      final transferring =
          j.state == JobState.active ||
          j.isFinishing ||
          j.transferState == 'running' ||
          j.transferState == 'finishing' ||
          j.transferState == 'waiting_pair';
      if (!transferring) continue;
      final total = j.expectedBytes ?? 0;
      if (total > 0) {
        sum += (j.bytesRead / total).clamp(0.0, 1.0);
      }
    }
    return (sum / n).clamp(0.0, 1.0);
  }

  /// Unfinished and every unfinished job is paused by the user.
  /// Session-only TikTok videos cannot resume a paused transfer.
  bool get supportsPause => !jobs.any((job) => needsSessionDownload(this, job));

  bool get isPaused {
    final open = jobs.where((j) => !j.isTerminal);
    return open.isNotEmpty && open.every((j) => j.state == JobState.paused);
  }

  /// Whether the batch is paused by user action (vs internal network interrupt).
  bool get isUserPaused {
    final open = jobs.where((j) => !j.isTerminal);
    return open.isNotEmpty && open.every((j) => j.userPaused);
  }

  /// Readable status text for interrupted/auto-retrying/storage-full batches.
  String? get statusText {
    final open = jobs.where((j) => !j.isTerminal).toList();
    if (open.isEmpty) return null;
    for (final j in open) {
      if (j.errorCode == storageFullCode ||
          (j.error != null && j.error!.contains('空间不足'))) {
        return j.error;
      }
    }
    for (final j in open) {
      if (j.userPaused) return '已暂停';
      if (j.error != null && j.error!.isNotEmpty) return j.error;
    }
    return null;
  }

  int get doneCount => jobs.where((j) => j.state == JobState.done).length;
  int get failedCount => jobs.where((j) => j.state == JobState.failed).length;

  // Every number the user reads is per item, never per file (v1.11 build 58).
  //
  // A Live photo's still and motion clip are two files but one item, so an
  // 8-item selection that holds three Live photos is 8 items — not 11 files,
  // which is what made the bubble read x/11 for eight selected items. An item
  // only counts as done when *all* of its files reached the album, and one
  // failed half fails the item.
  //
  // The item set is the post's own 1-based positions ([DownloadJob.itemIndex])
  // among the files that were not canceled, so canceling every file of an item
  // drops that item from the total. The per-file counts ([succeeded],
  // [failedCount], [doneCount]) stay for logs and the per-file rows.

  /// Items this batch covers (the user's own selection, by item).
  int get itemTotal => {
    for (final job in jobs)
      if (job.state != JobState.canceled) job.itemIndex,
  }.length;

  /// Items whose every file is in the album.
  int get itemDone {
    final complete = <int>{};
    final incomplete = <int>{};
    for (final job in jobs) {
      if (job.state == JobState.done) {
        complete.add(job.itemIndex);
      } else {
        // A canceled or still-running file also keeps its item unfinished.
        incomplete.add(job.itemIndex);
      }
    }
    return complete.difference(incomplete).length;
  }

  /// Items with at least one failed file: a failed Live half fails the item.
  int get itemFailed => {
    for (final job in jobs)
      if (job.state == JobState.failed) job.itemIndex,
  }.length;

  /// At least one file is parked until the connection is back (v1.11 batch 3).
  bool get waitingForNetwork => jobs.any((j) => j.isWaitingForNetwork);

  /// Short reason of the first failed job, for the history card.
  String? get failureReason =>
      jobs.map(shortFailureReason).whereType<String>().firstOrNull;

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
    // Neither is a batch that waits for the connection (v1.11 batch 3).
    if (waitingForNetwork) return false;
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
    'formatPref': formatPref.name,
    'jpegFallback': jpegFallbackPlanned,
    'pipeline': pipeline,
    if (usesNewTransferPipeline) 'usesNewTransferPipeline': true,
  };

  static DownloadBatch fromJson(Map<String, Object?> map) {
    final rawPipeline = map['pipeline'] as String?;
    final resolvedPipeline =
        (rawPipeline == pipelineTransfer || rawPipeline == pipelineLegacy)
        ? rawPipeline
        : ((map['usesNewTransferPipeline'] as bool? ?? false)
              ? pipelineTransfer
              : pipelineLegacy);
    return DownloadBatch(
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
        formatPref: ImageFormatPreference.fromName(
          map['formatPref'] as String?,
        ),
        jpegFallbackPlanned: map['jpegFallback'] as bool? ?? false,
        pipeline: resolvedPipeline,
      )
      ..historyWritten = map['historyWritten'] as bool? ?? false
      ..cancelledByDeletion = map['cancelledByDeletion'] as bool? ?? false
      ..settledBy = map['settledBy'] as String?;
  }
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
    this.jpegFallback = false,
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

  /// 「图片格式」asked for JPEG only and this item had no jpeg candidate, so
  /// the compat ladder is used for it (v1.11 batch 3).
  final bool jpegFallback;
}

List<PlannedFile> planFiles(
  ParsedPost post,
  List<int> selected,
  String Function(String label, int seq, String ext) nameFor, {
  ImageFormatPreference formatPref = ImageFormatPreference.compat,
}) {
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
    // Each file only carries URLs of its own kind: a still-image URL must
    // never be fetched as a motion clip (it is saved as an unplayable .mp4).
    // Both ordinary images and a Live photo's still use the same jpeg-first
    // ranking, so the still of a Live item is never the only file in a batch
    // that starts with a container provenance cannot be written to.
    final imageSource = orderedMediaUrls(post, item);
    final imageUrls = stillCandidatesFor(imageSource, formatPref: formatPref);
    final jpegFallback = stillFormatFellBack(
      imageSource,
      formatPref: formatPref,
    );
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
          jpegFallback: jpegFallback,
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
          // One final URL is tried once, whichever list it came from.
          urls: item.videoUrl != null
              ? [url]
              : dedupeFinalCandidates(
                  filterMediaCandidates([
                    item.url,
                    ...item.fallbacks,
                  ], isImage: false),
                ),
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
          jpegFallback: jpegFallback,
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
  final files = <HistoryFile>[];
  for (final job in batch.jobs) {
    if (job.saved && job.state == JobState.done) {
      if (batch.usesNewTransferPipeline &&
          (job.mediaId == null || job.mediaId!.trim().isEmpty)) {
        unawaited(
          DevLog.write(
            'V16DL',
            'history_write_rejected_no_media batch=${batch.batchId} '
                'job=${job.transferJobId ?? job.key}',
          ),
        );
        continue;
      }
      files.add(
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
          // A Live photo's still and motion clip are one entry from the moment
          // they are written, not after a later album scan.
          pairId: job.isLivePhoto ? '${batch.postId}#${job.itemIndex}' : null,
          md5: job.md5,
          rowVer: recovered ? 'settle_repair' : 'download',
        ),
      );
    }
  }

  // 3c: Fallback album check before finalizing history record:
  // If no files are registered as saved, check whether the gallery already accepted them.
  if (files.isEmpty) {
    for (final job in batch.jobs) {
      try {
        final existing = await DownloadManager.instance._findExistingAlbumAsset(
          batch,
          job,
        );
        if (existing != null) {
          if (batch.usesNewTransferPipeline && existing.id.trim().isEmpty) {
            unawaited(
              DevLog.write(
                'V16DL',
                'history_write_rejected_no_media batch=${batch.batchId} '
                    'job=${job.transferJobId ?? job.key}',
              ),
            );
            continue;
          }
          job.mediaId = existing.id;
          job.savedTitle = existing.title;
          job.relativePath = existing.relativePath;
          job.saved = true;
          job.state = JobState.done;
          files.add(
            HistoryFile(
              filename: (existing.title?.isNotEmpty == true)
                  ? existing.title!
                  : job.filename,
              savedAt: DateTime.now().millisecondsSinceEpoch,
              mediaId: existing.id,
              itemIndex: job.itemIndex,
              isImage: job.isImage,
              assetId: job.assetId,
              relativePath: existing.relativePath,
              itemCount: job.provenanceItemCount,
              capturedBy: job.provenanceCapturedBy,
              status: FileStatus.found,
              size: job.fileBytes,
              notOriginal: job.notOriginal,
              pairId: job.isLivePhoto
                  ? '${batch.postId}#${job.itemIndex}'
                  : null,
              md5: job.md5,
              rowVer: recovered ? 'settle_repair' : 'download',
            ),
          );
        }
      } catch (_) {}
    }
    final filesWithPairs = ensureLivePairIds(batch.postId, files);
    files.clear();
    files.addAll(filesWithPairs);
  }

  // 1c: Settlement rule: batches producing 0 saved files can only be failed or canceled.
  // downloadError MUST NEVER BE NULL when files.isEmpty!
  final String? downloadError;
  if (files.isEmpty) {
    if (batch.cancelledByDeletion ||
        batch.jobs.any((j) => j.state == JobState.canceled)) {
      downloadError = '已取消';
    } else {
      downloadError = batch.failureReason ?? '下载失败';
    }
  } else if (batch.failedCount > 0) {
    downloadError = batch.failureReason ?? '部分下载失败';
  } else {
    downloadError = null;
  }

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
      fileCount: files.length,
      createdAt: DateTime.now(),
      itemsJson: batch.itemsJson,
      files: files,
      downloadError: downloadError,
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
  final Map<String, SessionTransfer> _sessionTransfers = {};
  StreamSubscription<TaskUpdate>? _updatesSub;
  Timer? _heartbeat;
  bool _ready = false;
  Future<void>? _reconcileFuture;

  @visibleForTesting
  Future<void>? get reconcileFutureForTesting => _reconcileFuture;

  @visibleForTesting
  void resetInitForTesting() {
    _ready = false;
    _reconcileFuture = null;
    _inFlightResumes.clear();
  }

  /// Notifier triggered whenever a batch completes with at least one succeeded item.
  final ValueNotifier<DownloadBatch?> onBatchSuccess =
      ValueNotifier<DownloadBatch?>(null);

  final _notifications = FlutterLocalNotificationsPlugin();
  static const _channelId = 'easysave_downloads';
  final Map<String, int> _lastShownPercent = {};
  final Map<String, bool> _lastShownWaiting = {};

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
        final success =
            saved[downloadIdentity(
              b.platform,
              b.postId,
              j.itemIndex,
              j.isImage,
            )];
        final local = HistoryDb.knownSavedFiles(b.platform, b.postId)
            .where(
              (f) =>
                  f.itemIndex == j.itemIndex &&
                  f.isImage == j.isImage &&
                  f.status == FileStatus.found &&
                  f.mediaId?.isNotEmpty == true,
            )
            .firstOrNull;
        if (success == null && local == null) continue;
        j
          ..state = JobState.done
          ..saved = true
          ..mediaId = success?.mediaId ?? local?.mediaId
          ..error = null;
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
  DownloadBatch? getBatchForTesting(String batchId) => _batches[batchId];

  @visibleForTesting
  void clearBatchesForTesting() {
    for (final timer in _networkRetryTimers.values) {
      timer.cancel();
    }
    _networkRetryTimers.clear();
    for (final timer in _autoResumeTimers.values) {
      timer.cancel();
    }
    _autoResumeTimers.clear();
    _autoResumeRetries.clear();
    for (final timer in _activeQueryRetries.values) {
      timer.cancel();
    }
    _activeQueryRetries.clear();
    _activeQueryTimeouts.clear();
    _networkStabilityTimer?.cancel();
    _networkStabilityTimer = null;
    _lastNetworkType = NetworkStatus.instance.online
        ? NetworkStatus.instance.networkType
        : 'none';
    _networkWaits.clear();
    _inFlightResumes.clear();
    _batches.clear();
    notifyListeners();
  }

  static String _batchKey(String batchId) => 'easysave_batch_$batchId';
  static String _ownerKey(String batchId) => 'batch_owner_$batchId';

  Future<void> _setBatchOwner(
    String batchId,
    String newOwner, {
    required String reason,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final oldOwner = prefs.getString(_ownerKey(batchId)) ?? 'none';
      if (oldOwner != newOwner) {
        await prefs.setString(_ownerKey(batchId), newOwner);
        unawaited(
          DevLog.write(
            'V16DL',
            'owner_change batch=$batchId from=$oldOwner to=$newOwner reason=$reason',
          ),
        );
      }
    } catch (_) {}
  }

  Future<String?> _getBatchOwner(String batchId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_ownerKey(batchId));
    } catch (_) {
      return null;
    }
  }

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

  @visibleForTesting
  void resetReadyForTesting() {
    _ready = false;
  }

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    // P0-5b: Migrate unsettled legacy batches BEFORE FileDownloader().start()
    // so background_downloader/WorkManager cannot restart old tasks from 0.
    await _migrateAllLegacyBatchesEarly();
    if (downloaderStartForTesting != null) {
      await downloaderStartForTesting!();
    } else {
      await FileDownloader().start();
    }
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
    _updatesSub ??= FileDownloader().updates.listen(_onUpdate);
    // Connectivity is display only (progress text, notification body). The
    // downloader's queueing/retry/resume logic never reads it.
    unawaited(NetworkStatus.instance.start());
    NetworkStatus.instance.addListener(_onNetworkChanged);
    // Heartbeat: refresh the snapshot of running batches so the other engine
    // can tell "the owner is alive" from "the owner died mid-batch".
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _heartbeatTick(),
    );
    unawaited(ResumableDownloadStore.instance.purgeExpired());
    unawaited(tempSweep());
    // Reconcile runs in the background so cold engine startup and new batch
    // enqueuing are not blocked by historical snapshot recovery.
    _reconcileFuture = _loadAndReconcile().then((_) {
      // A file parked waiting for the connection in an earlier run continues as
      // soon as there is one (v1.11 batch 3).
      unawaited(_resumeWaitingJobs());
      if (owner == DownloadBatch.sourceMain) {
        _subscribeTransferEvents();
        unawaited(reconcileTransferHistoryPending());
        unawaited(_cleanOrphanTransferParts());
      }
    });
  }

  static const List<Duration> kAutoResumeBackoff = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
  ];

  final Map<String, int> _autoResumeRetries = {};
  final Map<String, Timer> _autoResumeTimers = {};
  String _lastNetworkType = 'unknown';
  String _networkStabilityFromType = 'none';
  Timer? _networkStabilityTimer;

  @visibleForTesting
  Map<String, int> get autoResumeRetriesForTesting => _autoResumeRetries;

  @visibleForTesting
  Map<String, Timer> get autoResumeTimersForTesting => _autoResumeTimers;

  @visibleForTesting
  Timer? get networkStabilityTimerForTesting => _networkStabilityTimer;

  @visibleForTesting
  void fireNetworkStabilityTimerForTesting() {
    if (_networkStabilityTimer != null) {
      _networkStabilityTimer?.cancel();
      _networkStabilityTimer = null;
      final stableType = NetworkStatus.instance.networkType;
      unawaited(
        DevLog.write(
          'V16DL',
          'network_change from=$_networkStabilityFromType to=$stableType action=resume',
        ),
      );
      _triggerNetworkRecoveryResume();
    }
  }

  /// The system connection came back (or went away): the notification body
  /// follows it. A connection that comes back also restarts every file parked
  /// in [JobState.waitingNetwork] (v1.11 batch 3) or interrupted with partial bytes.
  void _onNetworkChanged() {
    for (final batch in _batches.values.toList()) {
      if (batch.isTerminal) continue;
      unawaited(_refreshNotification(batch));
    }
    notifyListeners();

    final isOnline = NetworkStatus.instance.online;
    final newType = isOnline ? NetworkStatus.instance.networkType : 'none';
    final oldType = _lastNetworkType;
    if (oldType == newType) return;
    _lastNetworkType = newType;

    unawaited(
      DevLog.write(
        'V16DL',
        'network_change from=$oldType to=$newType action=observe',
      ),
    );

    // A1: Running tasks must NOT be interrupted when network changes.
    // Tasks will fail naturally if connection is broken.
    if (!isOnline || newType == 'none') {
      _networkStabilityTimer?.cancel();
      _networkStabilityTimer = null;
      for (final batch in _batches.values) {
        if (batch.source != DownloadManager.owner) continue;
        if (batch.usesNewTransferPipeline) continue;
        for (final job in batch.jobs) {
          if (!job.isTerminal && !job.userPaused) {
            if (job.state == JobState.queued) {
              job.error = '下载中断 · 等待网络';
              job.state = JobState.paused;
            }
          }
        }
      }
      notifyListeners();
      return;
    }

    // 2h: When network recovers from offline, wait ~3s for stability then resume paused jobs
    if (oldType == 'none') {
      unawaited(_resumeWaitingJobs());
      _networkStabilityFromType = oldType;
      _networkStabilityTimer?.cancel();
      _networkStabilityTimer = Timer(const Duration(seconds: 3), () {
        _networkStabilityTimer = null;
        if (!NetworkStatus.instance.online) return;
        _triggerNetworkRecoveryResume();
      });
      return;
    }
  }

  void _triggerNetworkRecoveryResume() async {
    final settings = await AppSettings.load();
    if (settings.manualResumeOnlyOnDisconnect) return;
    for (final batch in _batches.values.toList()) {
      if (batch.source != DownloadManager.owner) continue;
      if (batch.usesNewTransferPipeline) continue;
      for (final job in batch.jobs.toList()) {
        if (job.state == JobState.paused && (job.resumeStartByte ?? 0) > 0) {
          if (job.userPaused) continue;
          if (_isResumeInFlight(job)) {
            unawaited(
              DevLog.write(
                'V16DL',
                'resume_skipped reason=in_flight source=network_recovery',
              ),
            );
            continue;
          }
          final retries = _autoResumeRetries[job.key] ?? 0;
          if (retries < 5) {
            _autoResumeTimers[job.key]?.cancel();
            _autoResumeTimers.remove(job.key);
            final nextRetry = retries + 1;
            _autoResumeRetries[job.key] = nextRetry;
            job.autoResumeRetry = nextRetry;
            int actualStartByte = await _calculateResumeStartByte(
              job,
              batchId: batch.batchId,
            );
            if (actualStartByte <= 0 &&
                (job.resumeStartByte == null || job.resumeStartByte == 0)) {
              continue;
            }
            if (actualStartByte == 0) {
              await _clearResumeState(job);
            }
            job.resumeStartByte = actualStartByte;
            unawaited(
              DevLog.write(
                'V16DL',
                'auto_resume n=$nextRetry/5 from_bytes=$actualStartByte reason=network_recovered',
              ),
            );
            job.state = JobState.queued;
            job.error = '自动重试 $nextRetry/5';
            unawaited(_enqueueAttempt(batch, job, source: 'network_recovered'));
          } else {
            job.error = '已中断，点继续';
          }
        }
      }
    }
  }

  /// Attaches the system-connection listener exactly as [init] does, so a test
  /// can observe the automatic resume without starting the plugin.
  @visibleForTesting
  void attachNetworkListenerForTesting() {
    NetworkStatus.instance.removeListener(_onNetworkChanged);
    NetworkStatus.instance.addListener(_onNetworkChanged);
  }

  /// Re-enqueue every file parked until the connection returns. Called when the
  /// system reports a connection again and once at startup, so a file parked in
  /// a previous run continues too.
  Future<void> _resumeWaitingJobs() async {
    for (final batch in _batches.values.toList()) {
      if (batch.source != owner) continue;
      if (batch.usesNewTransferPipeline) continue;
      var changed = false;
      for (final job in batch.jobs.toList()) {
        if (!job.isWaitingForNetwork) continue;
        _networkWaits.remove(job.key);
        job.state = JobState.queued;
        changed = true;
        try {
          await _enqueueAttempt(batch, job, source: 'network_restored');
        } catch (e) {
          _log('resume after network failure failed ${job.key}: $e');
          job.state = JobState.failed;
          job.error = '加入下载队列失败';
        }
      }
      if (!changed) continue;
      await _persist(batch);
      notifyListeners();
      if (batch.isTerminal) await _afterTerminal(batch, recovered: false);
    }
  }

  /// Consecutive waits of one file while the system claimed to be online.
  final _networkWaits = <String, int>{};

  /// Park [job] until the connection is back instead of failing it.
  ///
  /// A network failure says nothing about the media: no attempt is spent
  /// ([refundAttempt]), no failure is recorded, the history keeps waiting and no
  /// failure snapshot is taken. [cause] is a fixed token — never a URL, a host
  /// name or a raw exception.
  Future<void> _waitForNetwork(
    DownloadBatch batch,
    DownloadJob job, {
    required String cause,
    bool refundAttempt = false,
  }) async {
    if (refundAttempt && job.attempts > 0) job.attempts--;
    job
      ..state = JobState.waitingNetwork
      ..progress = (job.progress > 0) ? job.progress : 0
      ..error = null
      ..errorCode = null
      ..lastProgressAt = DateTime.now().millisecondsSinceEpoch;
    _log(
      'waiting for network index=${job.itemIndex} role=${roleOf(job)} '
      'cause=$cause attempts=${job.attempts}/${retryCapFor(batch, job)}',
    );
    _scheduleNetworkRetry(batch, job);
    await _persist(batch);
    notifyListeners();
    unawaited(_refreshNotification(batch));
  }

  /// While the system claims a connection there is no connectivity event to
  /// wait for, so the parked file is looked at again on its own clock. Offline
  /// the system event is the trigger and no timer runs.
  void _scheduleNetworkRetry(DownloadBatch batch, DownloadJob job) {
    _networkRetryTimers.remove(job.key)?.cancel();
    if (!NetworkStatus.instance.online) return;
    final waits = (_networkWaits[job.key] ?? 0) + 1;
    _networkWaits[job.key] = waits;
    if (waits > kNetworkWaitLimit) {
      // The system keeps claiming a connection that never carries a transfer:
      // stop waiting and report it as the network failure it is, so the file
      // does not sit in the queue forever.
      _networkWaits.remove(job.key);
      unawaited(
        _failReadable(
          batch,
          job,
          error: networkUnavailableMessage,
          code: networkFailureCode,
        ),
      );
      return;
    }
    _networkRetryTimers[job.key] = Timer(kNetworkRetryInterval, () {
      _networkRetryTimers.remove(job.key);
      if (!job.isWaitingForNetwork) return;
      if (!NetworkStatus.instance.online) return;
      job.state = JobState.queued;
      unawaited(_enqueueAttempt(batch, job, source: 'network_retry'));
    });
  }

  final _networkRetryTimers = <String, Timer>{};

  @visibleForTesting
  Future<void> heartbeatTickForTesting() => _heartbeatTick();

  /// Persist the running batches so their `updatedAt` stays fresh while the
  /// owning engine is alive.
  Future<void> _heartbeatTick() async {
    for (final batch in _batches.values.toList()) {
      if (batch.isTerminal) continue;
      final currentOwner = await _getBatchOwner(batch.batchId);
      if (currentOwner != null && currentOwner != DownloadManager.owner) {
        batch.source = currentOwner;
        continue;
      }
      // Only batches this engine owns are driven here; a foreign batch is
      // left to its owner until it is adopted or force-adopted.
      if (batch.source == DownloadManager.owner) {
        if (batch.usesNewTransferPipeline) continue;
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
    if (batch.usesNewTransferPipeline) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final job in batch.jobs.toList()) {
      if (await _isAlreadySaved(batch, job)) {
        job.saved = true;
        job.state = JobState.done;
        job.error = null;
        unawaited(
          DevLog.write(
            'V16DL',
            'finish_skipped taskId=${job.currentTaskId ?? job.key} index=${job.itemIndex} reason=already_saved',
          ),
        );
        continue;
      }
      if (job.isTerminal || job.state == JobState.paused) continue;
      // A parked file is waiting on the connection, not stuck: the network
      // listener (or its own timer) owns it.
      if (job.isWaitingForNetwork) continue;
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
            int? nativeFinishedAt = job.downloadCompleteAt;
            if (nativeFinishedAt == null && record != null) {
              try {
                final path = await record.task.filePath();
                final file = File(path);
                if (file.existsSync()) {
                  nativeFinishedAt = file
                      .lastModifiedSync()
                      .millisecondsSinceEpoch;
                }
              } catch (_) {}
            }
            final delayMs = nativeFinishedAt != null
                ? (now - nativeFinishedAt)
                : (job.lastProgressAt > 0
                      ? (now - job.lastProgressAt)
                      : kStalledBatchAgeMs);
            job.lastProgressAt = now;
            DevLog.write(
              'V16DL',
              'watchdog native=TaskStatus.complete -> StalledAction.finishFile watchdog_delay_ms=$delayMs',
            );
            await _finishFile(batch, job, record!.task);
          case StalledAction.retry:
            if (_isResumeInFlight(job)) {
              unawaited(
                DevLog.write(
                  'V16DL',
                  'resume_skipped reason=in_flight source=watchdog',
                ),
              );
              break;
            }
            if (taskId != null) {
              await _cancelTaskWithId(taskId, source: 'watchdog');
            }
            try {
              await _enqueueAttempt(batch, job, source: 'watchdog');
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
  Future<void> _refreshNotification(
    DownloadBatch batch, {
    bool forceCancel = false,
  }) async {
    final active = [
      for (final j in batch.jobs)
        if (j.state != JobState.canceled) j,
    ];
    if (active.isEmpty) {
      await _cancelNotification(batch, force: forceCancel);
      return;
    }
    final done = batch.itemDone;
    final percent =
        (active.map((j) => j.progress).fold<double>(0, (a, b) => a + b) /
                active.length *
                100)
            .round()
            .clamp(0, 100);
    final terminal = batch.isTerminal;
    final waitingForNetwork = !NetworkStatus.instance.online;
    if (!terminal &&
        _lastShownPercent[batch.batchId] == percent &&
        _lastShownWaiting[batch.batchId] == waitingForNetwork) {
      return;
    }
    _lastShownPercent[batch.batchId] = percent;
    _lastShownWaiting[batch.batchId] = waitingForNetwork;
    try {
      if (terminal) {
        await _cancelNotification(batch, force: forceCancel);
        return;
      }
      await _notifications.show(
        id: _notificationId(batch),
        title: downloadNotificationTitle(
          batch: batch,
          done: done,
          total: batch.itemTotal,
          waitingForNetwork: waitingForNetwork,
        ),
        body: downloadNotificationBody(
          batch: batch,
          percent: percent,
          waitingForNetwork: waitingForNetwork,
        ),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            '下载进度',
            showProgress: !waitingForNetwork,
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

  /// Cancels notifications for [batches]. Only notifications that were shown
  /// in the current session (or when [force] is true, e.g. for recovered batches
  /// from a dead process) trigger a platform call.
  Future<void> cancelNotifications(
    Iterable<DownloadBatch> batches, {
    bool force = false,
  }) async {
    final toCancel = <int>[];
    for (final batch in batches) {
      final had =
          _lastShownPercent.containsKey(batch.batchId) ||
          _lastShownWaiting.containsKey(batch.batchId);
      _lastShownPercent.remove(batch.batchId);
      _lastShownWaiting.remove(batch.batchId);
      if (had || force) {
        toCancel.add(_notificationId(batch));
      }
    }
    if (toCancel.isEmpty) return;
    try {
      await historyStep('cancel-notification', () async {
        for (final id in toCancel) {
          await _notifications.cancel(id: id);
        }
      }, timeout: const Duration(milliseconds: 300));
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _cancelNotification(
    DownloadBatch batch, {
    bool force = false,
  }) async {
    await cancelNotifications([batch], force: force);
  }

  @visibleForTesting
  Future<void> Function()? downloaderStartForTesting;
  @visibleForTesting
  Future<List<TaskRecord>> Function(String group)? allRecordsForTesting;
  @visibleForTesting
  Future<TaskRecord?> Function(String taskId)? recordForIdForTesting;
  @visibleForTesting
  Future<void> Function()? prepareStartForTesting;
  @visibleForTesting
  Future<void> Function(DownloadBatch, DownloadJob)? enqueueForTesting;
  @visibleForTesting
  Future<ParseOutcome> Function(String)? reparseForTesting;
  @visibleForTesting
  Future<bool> Function(DownloadTask task)? resumeForTesting;
  @visibleForTesting
  Future<ResumeData?> Function(String taskId)? getResumeDataForTesting;
  @visibleForTesting
  Future<void> Function(String taskId)? removeResumeDataForTesting;
  @visibleForTesting
  Future<void> Function(ResumeData resumeData)? setResumeDataForTesting;
  @visibleForTesting
  Future<({bool acceptsRange, int? contentLength})> Function(
    DownloadJob job,
    String url,
  )?
  candidateRangeProbeForTesting;

  Future<ResumeData?> _getResumeData(String taskId) async {
    final hook = getResumeDataForTesting;
    if (hook != null) return await hook(taskId);
    try {
      return await FileDownloader()
          .getResumeData(taskId)
          .timeout(const Duration(milliseconds: 300), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  Future<void> _setResumeData(ResumeData resumeData) async {
    final hook = setResumeDataForTesting;
    if (hook != null) {
      await hook(resumeData);
      return;
    }
    try {
      await FileDownloader()
          .setResumeData(resumeData)
          .timeout(const Duration(milliseconds: 500), onTimeout: () {});
    } catch (_) {}
  }

  Future<void> _removeResumeData(String taskId) async {
    final hook = removeResumeDataForTesting;
    if (hook != null) {
      await hook(taskId);
      return;
    }
    try {
      await FileDownloader()
          .removeResumeData(taskId)
          .timeout(const Duration(milliseconds: 500), onTimeout: () {});
    } catch (_) {}
  }

  DownloadBatch? _findBatchForTaskId(String? taskId) {
    if (taskId == null || taskId.isEmpty) return null;
    for (final b in _batches.values) {
      for (final j in b.jobs) {
        if (j.currentTaskId == taskId ||
            j.previousTaskIds.contains(taskId) ||
            taskId.startsWith('${j.key}-r') ||
            taskId.startsWith('${j.key}-try') ||
            taskId == j.key) {
          return b;
        }
      }
    }
    return null;
  }

  /// Single gate for every legacy `background_downloader` mutation
  /// (enqueue, resume, pause, cancel, retry). Any batch owned by the new
  /// `transfer` pipeline is rejected and logged.
  bool _guardLegacyPluginCall(
    DownloadBatch? batch, {
    String? taskId,
    String? groupId,
    required String action,
    required String source,
  }) {
    if (source == 'legacy_migration' && action == 'cancel') {
      return true;
    }
    final resolved =
        batch ??
        (groupId != null ? _batches[groupId] : null) ??
        _findBatchForTaskId(taskId);
    if (resolved != null && resolved.usesNewTransferPipeline) {
      unawaited(
        DevLog.write(
          'V16DL',
          'legacy_call_blocked batch=${resolved.batchId} action=$action source=$source',
        ),
      );
      return false;
    }
    return true;
  }

  Future<bool> _enqueueLegacyTask(
    DownloadBatch batch,
    DownloadTask task, {
    required String source,
  }) async {
    if (!_guardLegacyPluginCall(
      batch,
      taskId: task.taskId,
      groupId: task.group,
      action: 'enqueue',
      source: source,
    )) {
      return false;
    }
    return await FileDownloader().enqueue(task);
  }

  Future<bool> _resumeTask(
    DownloadTask task, {
    DownloadBatch? batch,
    String source = 'resume',
  }) async {
    if (!_guardLegacyPluginCall(
      batch,
      taskId: task.taskId,
      groupId: task.group,
      action: 'resume',
      source: source,
    )) {
      return false;
    }
    final hook = resumeForTesting;
    if (hook != null) return await hook(task);
    return await FileDownloader().resume(task);
  }

  @visibleForTesting
  Future<Task?> Function(String taskId)? taskForIdForTesting;
  @visibleForTesting
  Future<bool> Function(DownloadTask task)? pauseForTesting;
  @visibleForTesting
  Future<void> Function(String taskId)? cancelTaskForTesting;

  Future<Task?> _taskForId(String taskId) async {
    final hook = taskForIdForTesting;
    if (hook != null) return await hook(taskId);
    try {
      return await FileDownloader()
          .taskForId(taskId)
          .timeout(const Duration(milliseconds: 300), onTimeout: () => null);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _pauseTask(
    DownloadTask task, {
    DownloadBatch? batch,
    String source = 'pause',
  }) async {
    if (!_guardLegacyPluginCall(
      batch,
      taskId: task.taskId,
      groupId: task.group,
      action: 'pause',
      source: source,
    )) {
      return false;
    }
    unawaited(
      DevLog.write('V16DL', 'cancel_call taskId=${task.taskId} source=$source'),
    );
    final hook = pauseForTesting;
    if (hook != null) return await hook(task);
    try {
      return await FileDownloader()
          .pause(task)
          .timeout(const Duration(milliseconds: 300), onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }

  Future<void> _cancelTaskWithId(
    String taskId, {
    DownloadBatch? batch,
    required String source,
  }) async {
    if (!_guardLegacyPluginCall(
      batch,
      taskId: taskId,
      action: 'cancel',
      source: source,
    )) {
      return;
    }
    unawaited(
      DevLog.write('V16DL', 'cancel_call taskId=$taskId source=$source'),
    );
    final hook = cancelTaskForTesting;
    if (hook != null) {
      await hook(taskId);
      return;
    }
    try {
      await FileDownloader().cancelTaskWithId(taskId);
    } catch (_) {}
  }

  Future<void> _cancelTasksWithIds(
    List<String> taskIds, {
    DownloadBatch? batch,
    required String source,
  }) async {
    final filtered = <String>[];
    for (final id in taskIds) {
      if (_guardLegacyPluginCall(
        batch,
        taskId: id,
        action: 'cancel',
        source: source,
      )) {
        filtered.add(id);
      }
    }
    if (filtered.isEmpty) return;
    for (final id in filtered) {
      unawaited(DevLog.write('V16DL', 'cancel_call taskId=$id source=$source'));
    }
    final hook = cancelTaskForTesting;
    if (hook != null) {
      for (final id in filtered) {
        await hook(id);
      }
      return;
    }
    try {
      await FileDownloader().cancelTasksWithIds(filtered);
    } catch (_) {}
  }

  /// Active resume/download requests currently in-flight by job key (v1.12 build 73).
  final Set<String> _inFlightResumes = <String>{};

  bool _isResumeInFlight(DownloadJob job) {
    return _inFlightResumes.contains(job.key);
  }

  /// Content-Length of a job URL (production: HEAD request).
  @visibleForTesting
  Future<int?> Function(DownloadJob job, String url)?
  contentLengthProbeForTesting;

  /// Album save of a finished file (production: provenance + native save).
  @visibleForTesting
  Future<({String? mediaId, String? title, String? relativePath})> Function(
    String path,
    DownloadJob job,
  )?
  gallerySaveForTesting;

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
    String path, {
    MediaContentType? content,
  }) => _importFile(batch, job, path, isImage: job.isImage, content: content);

  /// Provenance step of a finished still (production: called by the import).
  @visibleForTesting
  Future<String?> embedProvenanceForTesting(
    DownloadBatch batch,
    DownloadJob job,
    String path,
  ) => _embedProvenance(
    filePath: path,
    batch: batch,
    job: job,
    itemIndex: job.itemIndex,
  );

  /// Candidate switch after a finished file whose bytes contradict the job.
  @visibleForTesting
  Future<void> contentVerdictForTesting(
    DownloadBatch batch,
    DownloadJob job,
    String path, {
    MediaContentType? content,
  }) async {
    final verdict = contentVerdictFor(
      isImage: job.isImage,
      attempts: job.attempts,
      candidateCount: job.urls.length,
      content: content,
    );
    await _logCandidate(batch, job, path, content, verdict);
    if (verdict == ContentVerdict.accept) return;
    await _handleContentVerdict(batch, job, path);
  }

  /// The accept path of [_finishFileOnce]: log the candidate and apply the
  /// quality-ladder mark, without touching the album.
  @visibleForTesting
  Future<void> finishFileForTesting(
    DownloadBatch batch,
    DownloadJob job,
    String path, {
    MediaContentType? content,
  }) async {
    final verdict = contentVerdictFor(
      isImage: job.isImage,
      attempts: job.attempts,
      candidateCount: job.urls.length,
      content: content,
    );
    await _logCandidate(batch, job, path, content, verdict);
    if (verdict != ContentVerdict.accept) {
      await _handleContentVerdict(batch, job, path);
      return;
    }
    _markPreviewOnly(job);
  }

  @visibleForTesting
  Future<void> afterTerminalForTesting(
    DownloadBatch batch, {
    bool recovered = false,
    String? reason,
    bool fromTransferPipeline = false,
  }) => _afterTerminal(
    batch,
    recovered: recovered,
    reason: reason,
    fromTransferPipeline: fromTransferPipeline,
  );

  /// The drop step [_afterTerminal] performs once a batch finished without a
  /// failure. Exposed so the failure-state rule can be tested without the
  /// fire-and-forget backup/notification work that follows it.
  @visibleForTesting
  Future<void> forgetSupersededFailuresForTesting(DownloadBatch batch) =>
      _forgetSupersededFailureBatches(batch);

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
    // The "下一次下载模拟失败" switch lives in SharedPreferences, so the engine
    // that starts a batch (main UI, bubble, share) reads the state the other
    // engine left behind instead of its own stale copy (v1.11 batch 4).
    await DevDownloadFailure.refresh();
    // 图片格式 (v1.11 batch 3): read the setting the UI saved, so every engine
    // (main UI, bubble, share) plans the same ladder.
    final formatPref = (await AppSettings.load()).imageFormat;
    // The batch id carries the owner so ownership is visible in the shared
    // snapshot store (SharedPreferences) and in the plugin's task groups.
    final batchId =
        '${DownloadManager.owner}-${DateTime.now().microsecondsSinceEpoch}-${_batchSequence++}';
    final planned = planFiles(post, selected, nameFor, formatPref: formatPref);
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
            resourceForCandidate(
              policy,
              resourcesByIndex[file.itemIndex]!,
              url,
            ),
        ],
    ];
    final settingsForPipeline = await AppSettings.load();
    final useNewPipeline =
        useNewTransferPipelineForTesting ??
        ((enqueueForTesting != null && transferClientForTesting == null)
            ? false
            : settingsForPipeline.useNewTransferPipeline);

    final batch = DownloadBatch(
      batchId: batchId,
      album: album,
      postUrl: post.url,
      platform: post.platform,
      formatPref: formatPref,
      jpegFallbackPlanned: planned.any((file) => file.jpegFallback),
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
      usesNewTransferPipeline: useNewPipeline,
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
            ..expectedHeight = planned[i].expectedHeight
            ..usesNewTransferPipeline = useNewPipeline,
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
        if (!batch.usesNewTransferPipeline) {
          try {
            await FileDownloader().permissions.request(
              PermissionType.notifications,
            );
          } catch (_) {
            // Ignore: proceed without notifications.
          }
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
    if (batch.usesNewTransferPipeline) {
      _enqueuingTransferJobs.addAll(batch.jobs.map((j) => j.key));
    }
    _batches[batchId] = batch;
    notifyListeners();
    onBatchReady?.call(batch);
    // Remember where this batch starts in the log so a failed batch can save
    // the lines around it (v1.11 batch 1).
    _batchLogStarts[batchId] = DevLog.totalLines;
    await _setBatchOwner(batchId, DownloadManager.owner, reason: 'start');
    _log('batch start id=$batchId source=${batch.source} post=${batch.postId}');
    if (_batchLogStarts.length > 64) {
      _batchLogStarts.remove(_batchLogStarts.keys.first);
    }
    if (!batch.usesNewTransferPipeline) {
      unawaited(_refreshNotification(batch));
    }
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
        if (batch.usesNewTransferPipeline) {
          await _enqueueViaTransferService(batch, job);
        } else {
          await _enqueueAttempt(batch, job, source: 'start');
        }
      } catch (e) {
        _log('enqueue failed ${job.key}: $e');
        job.state = JobState.failed;
        if (batch.usesNewTransferPipeline) {
          job.transferState = 'failed';
          job.error = '启动失败，点重试';
        } else {
          job.error = '加入下载队列失败';
        }
      } finally {
        _enqueuingTransferJobs.remove(job.key);
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

  @visibleForTesting
  static Duration roundWaitTimeout = const Duration(seconds: 10);
  @visibleForTesting
  static Duration roundWaitPollInterval = const Duration(milliseconds: 100);

  bool _isTerminalStatus(TaskStatus status) {
    return status == TaskStatus.complete ||
        status == TaskStatus.failed ||
        status == TaskStatus.canceled ||
        status == TaskStatus.notFound;
  }

  Future<TaskStatus> _queryTaskStatus(String taskId) async {
    try {
      if (recordForIdForTesting != null) {
        final r = await recordForIdForTesting!(taskId);
        return r?.status ?? TaskStatus.notFound;
      }
      final record = await FileDownloader().database
          .recordForId(taskId)
          .timeout(const Duration(milliseconds: 500), onTimeout: () => null);
      return record?.status ?? TaskStatus.notFound;
    } catch (_) {
      return TaskStatus.notFound;
    }
  }

  /// B1: 续传起点只能等于临时文件的实际长度：
  /// - 记录大于文件长度：按文件长度续传，写日志 resume_data_ahead record=… file=…；
  /// - 记录小于文件长度：同样按文件长度续传；
  /// - 文件不存在或长度为 0：从 0 下载，并清空续传记录。
  Future<int> _calculateResumeStartByte(
    DownloadJob job, {
    ResumeData? resumeData,
    String? tempPathOverride,
    String? taskId,
    String? filename,
    String? batchId,
  }) async {
    final isResumable =
        !job.isImage &&
        (job.expectedBytes == null || job.expectedBytes! >= kResumableMinBytes);
    if (!isResumable) return 0;

    final tId = taskId ?? job.currentTaskId ?? job.key;
    ResumeData? rData = resumeData;
    if (rData == null &&
        (job.resumeTempPath == null || job.resumeTempPath!.isEmpty)) {
      if (tId.isNotEmpty) {
        try {
          rData = await _getResumeData(tId);
        } catch (_) {}
      }
      if (rData == null && tId != job.key && job.key.isNotEmpty) {
        try {
          rData = await _getResumeData(job.key);
        } catch (_) {}
      }
    }

    String? tempPath = tempPathOverride ?? rData?.data ?? job.resumeTempPath;
    if (tempPath == null || tempPath.isEmpty) {
      final fName = filename ?? job.filename;
      final bId = batchId ?? '';
      try {
        final root =
            await (tempRootForTesting?.call() ?? getTemporaryDirectory());
        final subDir = downloadTempDirectory(bId, job.key);
        final cand = File('${root.path}/$subDir/$fName');
        if (cand.existsSync()) {
          tempPath = cand.path;
        } else {
          final cand2 = File(
            '${root.path}/${downloadTempDirectory(bId, tId)}/$fName',
          );
          if (cand2.existsSync()) tempPath = cand2.path;
        }
      } catch (_) {}
    }

    int fileSize = 0;
    if (tempPath != null && tempPath.isNotEmpty) {
      try {
        final f = File(tempPath);
        if (f.existsSync()) {
          fileSize = f.lengthSync();
        }
      } catch (_) {}
    }

    if (fileSize == 0) {
      await _clearResumeState(job, taskId: taskId);
      return 0;
    }

    final recorded = rData?.requiredStartByte ?? job.resumeStartByte ?? 0;
    if (recorded > fileSize) {
      unawaited(
        DevLog.write(
          'V16DL',
          'resume_data_ahead record=$recorded file=$fileSize',
        ),
      );
    }

    job.resumeStartByte = fileSize;
    job.resumeTempPath = tempPath;
    if (rData?.eTag != null && rData!.eTag!.isNotEmpty) {
      job.resumeEtag = rData.eTag;
    }
    return fileSize;
  }

  /// B3: 任何从 0 重新下载（无论原因）都必须同时清空 App 保存的续传记录和插件 ResumeData。
  Future<void> _clearResumeState(DownloadJob job, {String? taskId}) async {
    job.resumeStartByte = null;
    job.resumeTempPath = null;
    job.resumeEtag = null;
    job.progress = 0;
    final id = taskId ?? job.currentTaskId;
    if (id != null) {
      await _removeResumeData(id);
    }
    await _removeResumeData(job.key);
    await ResumableDownloadStore.instance.cleanForJob(job.key);
  }

  void _trackFailureReason(DownloadJob job, String reason) {
    if (job.lastFailReason == reason) {
      job.consecutiveFailCount++;
    } else {
      job.lastFailReason = reason;
      job.consecutiveFailCount = 1;
    }
  }

  Future<void> _safeCancelPreservingTemp(String taskId, DownloadJob job) async {
    File? preserved;
    var tempPath = job.resumeTempPath;
    final isResumable =
        !job.isImage &&
        (job.expectedBytes == null || job.expectedBytes! >= kResumableMinBytes);
    if ((tempPath == null || tempPath.isEmpty) && isResumable) {
      try {
        final rd = await _getResumeData(taskId);
        if (rd != null && rd.data.isNotEmpty) {
          tempPath = rd.data;
          job.resumeTempPath = rd.data;
        }
      } catch (_) {}
    }
    if (tempPath != null && tempPath.isNotEmpty) {
      try {
        final f = File(tempPath);
        if (f.existsSync() && f.lengthSync() > 0) {
          final backup = File(
            '$tempPath.preserved_${DateTime.now().microsecondsSinceEpoch}',
          );
          f.copySync(backup.path);
          preserved = backup;
        }
      } catch (_) {}
    }
    await _cancelTaskWithId(taskId, source: 'round_preempt');
    if (preserved != null && tempPath != null) {
      try {
        final orig = File(tempPath);
        if (!orig.existsSync() || orig.lengthSync() == 0) {
          preserved.copySync(tempPath);
        }
        if (preserved.existsSync()) preserved.deleteSync();
      } catch (_) {}
    }
  }

  Future<bool> _ensureOldRoundsTerminal(
    DownloadBatch batch,
    DownloadJob job,
  ) async {
    final oldTaskIds = <String>{...job.previousTaskIds};
    if (job.currentTaskId != null) {
      oldTaskIds.add(job.currentTaskId!);
    }
    if (oldTaskIds.isEmpty) return true;

    for (final oldId in oldTaskIds) {
      final status = await _queryTaskStatus(oldId);
      if (!_isTerminalStatus(status)) {
        // A2: 「只能有一个原生任务」的检查中，paused 视为不在运行：不取消、不发起新一轮。
        if (status == TaskStatus.paused) {
          continue;
        }
        unawaited(
          DevLog.write('V16DL', 'round_wait old=$oldId state=${status.name}'),
        );
        await _safeCancelPreservingTemp(oldId, job);

        final stopwatch = Stopwatch()..start();
        bool reachedTerminal = false;
        while (stopwatch.elapsed < roundWaitTimeout) {
          if (job.saved || job.state == JobState.done) {
            return false;
          }
          await Future<void>.delayed(roundWaitPollInterval);
          final s = await _queryTaskStatus(oldId);
          if (_isTerminalStatus(s)) {
            reachedTerminal = true;
            break;
          }
        }
        if (!reachedTerminal) {
          unawaited(DevLog.write('V16DL', 'round_blocked old=$oldId'));
          job.state = JobState.paused;
          job.userPaused = false;
          job.error = '已中断，点继续';
          await _persist(batch);
          notifyListeners();
          return false;
        }
      }
    }
    return true;
  }

  final _enqueuePending = <String>{};
  Future<void> _enqueueAttempt(
    DownloadBatch batch,
    DownloadJob job, {
    String source = 'unknown',
  }) async {
    if (!_guardLegacyPluginCall(
      batch,
      taskId: job.currentTaskId ?? job.key,
      groupId: batch.batchId,
      action: 'enqueue',
      source: source,
    )) {
      return;
    }
    if (job.isFinishing || _finishing.containsKey(job.key)) {
      unawaited(
        DevLog.write(
          'V16DL',
          'enqueue_blocked taskId=${job.currentTaskId ?? job.key} index=${job.itemIndex} role=${roleOf(job)} reason=finishing source=$source',
        ),
      );
      return;
    }
    if (job.saved ||
        job.state == JobState.done ||
        await _isAlreadySaved(batch, job)) {
      job.saved = true;
      job.state = JobState.done;
      job.error = null;
      unawaited(
        DevLog.write(
          'V16DL',
          'enqueue_blocked taskId=${job.currentTaskId ?? job.key} index=${job.itemIndex} role=${roleOf(job)} reason=completed source=$source',
        ),
      );
      return;
    }
    if (_isResumeInFlight(job)) {
      unawaited(
        DevLog.write('V16DL', 'resume_skipped reason=in_flight source=$source'),
      );
      return;
    }
    _inFlightResumes.add(job.key);
    try {
      if (!_enqueuePending.add(job.key)) {
        return;
      }
      try {
        await _enqueueAttemptOnce(batch, job, source: source);
      } finally {
        _enqueuePending.remove(job.key);
      }
    } finally {
      _inFlightResumes.remove(job.key);
    }
  }

  Future<void> _enqueueAttemptOnce(
    DownloadBatch batch,
    DownloadJob job, {
    String source = 'unknown',
  }) async {
    if (job.isFinishing || _finishing.containsKey(job.key)) {
      unawaited(
        DevLog.write(
          'V16DL',
          'enqueue_blocked taskId=${job.currentTaskId ?? job.key} index=${job.itemIndex} role=${roleOf(job)} reason=finishing source=$source',
        ),
      );
      return;
    }
    if (job.saved ||
        job.state == JobState.done ||
        await _isAlreadySaved(batch, job)) {
      job.saved = true;
      job.state = JobState.done;
      job.error = null;
      unawaited(
        DevLog.write(
          'V16DL',
          'enqueue_blocked taskId=${job.currentTaskId ?? job.key} index=${job.itemIndex} role=${roleOf(job)} reason=completed source=$source',
        ),
      );
      return;
    }
    if (isFinalFailure(job)) {
      // A refused URL or a simulated failure is decided: nothing may put the
      // file back in the queue behind the user's back. A manual retry clears
      // the code first (see [retryJob]).
      if (!job.isTerminal) job.state = JobState.failed;
      return;
    }
    if (batch.cancelledByDeletion ||
        await DownloadClaims.isCancelled(batch.batchId)) {
      batch.cancelledByDeletion = true;
      job.state = JobState.canceled;
      return;
    }
    if ((await _reserve(batch, [job])).isEmpty) throw AlreadyDownloading();
    if (await _storageBlocked(batch, job)) return;
    if (!await _ensureOldRoundsTerminal(batch, job)) return;
    final oldTaskId = job.currentTaskId;
    if (oldTaskId != null && !job.previousTaskIds.contains(oldTaskId)) {
      job.previousTaskIds.add(oldTaskId);
    }
    if (enqueueForTesting != null) {
      await enqueueForTesting!(batch, job);
      return;
    }
    if (needsSessionDownload(batch, job)) {
      await _startSessionDownload(batch, job);
      return;
    }
    final index = candidateIndexOf(job);
    final policy = _policyFor(batch.platform);
    final authorized = await policy.authorize(_jobResource(job, index, policy));
    if (authorized.cookie != null && authorized.cookie!.isNotEmpty) {
      // Cookie-bearing transfers stay in Dart so every redirect is authorised
      // again. Native background tasks receive no credential material.
      await _startSessionDownload(batch, job);
      return;
    }
    final isResumable =
        !job.isImage &&
        (job.expectedBytes == null || job.expectedBytes! >= kResumableMinBytes);
    job.attempts++;
    job.round++;
    final url = authorized.uri.toString();
    final taskId = isResumable
        ? '${job.key}-r${job.round}'
        : '${job.key}-r${job.round}-try${job.attempts}';
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
      headers: unifiedTransferHeaders(authorized.headers),
      directory: downloadTempDirectory(batch.batchId, job.key),
      baseDirectory: BaseDirectory.temporary,
      group: batch.batchId,
      updates: Updates.statusAndProgress,
      retries: 0,
      allowPause: isResumable,
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
        'expectedBytes': job.expectedBytes,
        'mediaPolicyHosts': (policy.site.data['download'] as Map)['mediaHosts'],
      }),
    );
    await _persist(batch);
    notifyListeners();
    bool accepted = false;
    if (isResumable) {
      ResumeData? resumeData;
      try {
        resumeData = await _getResumeData(
          taskId,
        ).timeout(const Duration(milliseconds: 300), onTimeout: () => null);
      } catch (_) {}
      if (resumeData == null && oldTaskId != null) {
        try {
          resumeData = await _getResumeData(
            oldTaskId,
          ).timeout(const Duration(milliseconds: 300), onTimeout: () => null);
        } catch (_) {}
      }
      if (resumeData == null && taskId != job.key && oldTaskId != job.key) {
        try {
          resumeData = await _getResumeData(
            job.key,
          ).timeout(const Duration(milliseconds: 300), onTimeout: () => null);
        } catch (_) {}
      }
      if (resumeData == null &&
          job.resumeStartByte != null &&
          job.resumeTempPath != null) {
        final path = job.resumeTempPath!;
        final f = File(path);
        if (f.existsSync() &&
            (f.lengthSync() >= job.resumeStartByte! || f.lengthSync() > 0)) {
          resumeData = ResumeData(
            task,
            path,
            job.resumeStartByte!,
            job.resumeEtag,
          );
        }
      }
      final total = job.expectedBytes ?? -1;
      bool loggedRestart = false;
      if (resumeData != null) {
        final origTaskId = resumeData.task.taskId;
        final taskIdMatch =
            origTaskId == taskId ||
            origTaskId == oldTaskId ||
            origTaskId == job.key ||
            origTaskId.startsWith('${job.key}-r');
        if (!taskIdMatch) {
          loggedRestart = true;
          unawaited(
            DevLog.write(
              'V16DL',
              'resume taskId=$taskId index=${job.itemIndex} role=${roleOf(job)} '
                  'method=enqueue has_resume_data=true from_bytes=0 '
                  'total=$total result=restart reason=taskid_mismatch',
            ),
          );
          await _clearResumeState(job, taskId: taskId);
          resumeData = null;
        } else {
          // B1 & B4: 续传起点只能等于临时文件的实际长度
          final startByte = await _calculateResumeStartByte(
            job,
            resumeData: resumeData,
            taskId: taskId,
            filename: job.filename,
            batchId: batch.batchId,
          );
          if (startByte == 0) {
            unawaited(
              DevLog.write(
                'V16DL',
                'resume taskId=$taskId index=${job.itemIndex} role=${roleOf(job)} '
                    'method=enqueue has_resume_data=true from_bytes=0 '
                    'total=$total result=restart reason=tempfile_missing',
              ),
            );
            await _clearResumeState(job, taskId: taskId);
            resumeData = null;
          } else {
            resumeData = ResumeData(
              task,
              job.resumeTempPath!,
              startByte,
              resumeData.eTag,
            );
            await _setResumeData(resumeData);
          }
        }
      }
      final hasResumeData = resumeData != null;
      if (hasResumeData) {
        final fromBytes = resumeData.requiredStartByte;
        unawaited(
          DevLog.write(
            'V16DL',
            'resume taskId=$taskId index=${job.itemIndex} role=${roleOf(job)} '
                'method=resume has_resume_data=true from_bytes=$fromBytes '
                'total=$total result=requested reason=range_requested',
          ),
        );
        if (total > 0 && fromBytes < total) {
          job.progress = (fromBytes / total).clamp(0.0, 1.0);
        }
        accepted = await _resumeTask(task, batch: batch, source: source);
        if (!accepted) {
          unawaited(
            DevLog.write(
              'V16DL',
              'resume taskId=$taskId index=${job.itemIndex} role=${roleOf(job)} '
                  'method=enqueue has_resume_data=true from_bytes=$fromBytes '
                  'total=$total result=restart reason=resume_failed',
            ),
          );
          _trackFailureReason(job, 'resume_failed');
        } else {
          job.consecutiveFailCount = 0;
          job.lastFailReason = null;
        }
      } else if (!loggedRestart && (job.attempts > 1 || job.progress > 0)) {
        await _clearResumeState(job, taskId: taskId);
        unawaited(
          DevLog.write(
            'V16DL',
            'resume taskId=$taskId index=${job.itemIndex} role=${roleOf(job)} '
                'method=enqueue has_resume_data=false from_bytes=0 '
                'total=$total result=restart reason=no_resume_data',
          ),
        );
      }
    }
    if (!accepted) {
      accepted = await _enqueueLegacyTask(batch, task, source: source);
    }
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
        !isLowResolution(
          expectedWidth,
          expectedHeight,
          actual.width,
          actual.height,
        )) {
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
    unawaited(
      DevLog.write(
        'V16DL', // i18n:ignore 日志
        'event=retry reason=low_resolution index=${job.itemIndex} '
            'expected=${expectedWidth}x$expectedHeight '
            'actual=${actual.width}x${actual.height} '
            'candidate=${candidateProgressLabel(job)}',
      ),
    );
    final pixels = actual.width * actual.height;
    final previous = job.lowResPath;
    if (previous == null ||
        pixels > (job.lowResPixels ?? 0) ||
        !await File(previous).exists()) {
      final root =
          await (tempRootForTesting?.call() ?? getTemporaryDirectory());
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
      await _enqueueAttempt(batch, job, source: 'low_resolution');
      return (retry: true, path: '');
    }
    final kept = job.lowResPath!;
    job
      ..lowResPath = null
      ..notOriginal = true;
    _log(
      'low resolution: no larger candidate, keeping the largest index=${job.itemIndex}',
    );
    return (retry: false, path: kept);
  }

  /// Fail [job] before it downloads when its known size does not fit.
  ///
  /// The log line states the outcome it really reached (v1.11 batch 3): a probe
  /// that could not run or did not answer is `result=unknown` with a fixed
  /// `reason=`, never `result=ok` next to `size=-1`, which claimed a check that
  /// never happened.
  Future<bool> _storageBlocked(DownloadBatch batch, DownloadJob job) async {
    if (job.urls.isEmpty) return false;
    final index = candidateIndexOf(job);
    var size = job.expectedBytes;
    String? reason;
    if (size == null) {
      try {
        final probe = contentLengthProbeForTesting;
        if (probe != null) {
          final offline = !NetworkStatus.instance.online;
          if (offline) {
            reason = 'offline';
          } else {
            size = await probe(job, job.urls[index]);
            if (size == null || size <= 0) reason = 'probe_failed';
          }
        } else {
          final probed = await _probeContentLength(batch, job, index);
          size = probed.bytes;
          reason = probed.reason;
        }
      } catch (e) {
        size = null;
        reason = networkCauseOf(e) ?? 'probe_failed';
      }
      if (size != null && size > 0) job.expectedBytes = size;
    }
    int partialBytes = 0;
    if (job.resumeStartByte != null && job.resumeStartByte! > 0) {
      partialBytes = job.resumeStartByte!;
    }
    final isResumable =
        !job.isImage &&
        (job.expectedBytes == null || job.expectedBytes! >= kResumableMinBytes);
    if (partialBytes == 0 &&
        isResumable &&
        (job.currentTaskId != null || job.key.isNotEmpty)) {
      try {
        final tId = job.currentTaskId ?? job.key;
        var rd = await _getResumeData(
          tId,
        ).timeout(const Duration(milliseconds: 300), onTimeout: () => null);
        if (rd == null && tId != job.key) {
          rd = await _getResumeData(
            job.key,
          ).timeout(const Duration(milliseconds: 300), onTimeout: () => null);
        }
        if (rd != null && rd.data.isNotEmpty) {
          final f = File(rd.data);
          if (f.existsSync()) {
            final len = f.lengthSync();
            if (len > 0) {
              partialBytes = len;
              job.resumeStartByte = len;
              job.resumeTempPath = rd.data;
              job.resumeEtag = rd.eTag;
            }
          } else if (rd.requiredStartByte > 0) {
            partialBytes = rd.requiredStartByte;
            job.resumeStartByte = rd.requiredStartByte;
            job.resumeTempPath = rd.data;
            job.resumeEtag = rd.eTag;
          }
        }
      } catch (_) {}
    }
    if (partialBytes == 0 &&
        job.resumeStartByte != null &&
        job.resumeStartByte! > 0) {
      partialBytes = job.resumeStartByte!;
    }
    if (partialBytes == 0) {
      final candidates = <String>[];
      if (job.resumeTempPath != null) candidates.add(job.resumeTempPath!);
      try {
        final tempDir =
            await (tempRootForTesting?.call() ?? getTemporaryDirectory());
        final taskDir = downloadTempDirectory(batch.batchId, job.key);
        candidates.add('${tempDir.path}/$taskDir/${job.filename}');
        if (job.currentTaskId != null) {
          candidates.add(
            '${tempDir.path}/${downloadTempDirectory(batch.batchId, job.currentTaskId!)}/${job.filename}',
          );
        }
      } catch (_) {}
      for (final p in candidates) {
        try {
          final f = File(p);
          if (f.existsSync()) {
            final len = f.lengthSync();
            if (len > partialBytes) {
              partialBytes = len;
              job.resumeTempPath = p;
              job.resumeStartByte = len;
            }
          }
        } catch (_) {}
      }
    }
    if (partialBytes == 0 && job.progress > 0 && size != null && size > 0) {
      partialBytes = (job.progress * size).floor();
    }
    final known = size != null && size > 0;
    final free = await StorageGuard.freeBytes();
    final need = known ? requiredBytesForDownload(size, partialBytes) : null;
    final required = (known && free != null && free < need!) ? need : null;
    _log(
      'preflight index=${job.itemIndex} role=${roleOf(job)} '
      'label=${candidateLabelOf(job.urls[index])} '
      'candidate_seq=${index + 1}/${job.urls.length} '
      'size=${known ? size : -1} '
      'free_bytes=${free ?? -1} need_bytes=${need ?? -1} partial_bytes=$partialBytes '
      'result=${required != null
          ? storageFullCode
          : known
          ? 'ok'
          : 'unknown'}'
      '${required != null || known ? '' : ' reason=${reason ?? 'probe_failed'}'}',
    );
    if (required == null) return false;
    await _failForStorage(batch, job, required, free: free);
    return true;
  }

  /// Size probe of a cookie-free background download, using the same method
  /// and the same headers as the transfer itself: a ranged `GET` (a `HEAD` is
  /// answered by a different path on the CDN and its result never described
  /// the bytes the transfer would receive), `Accept-Encoding: identity` and a
  /// browser User-Agent. No redirect is followed (each hop would need its own
  /// authorization).
  Future<({int? bytes, String? reason})> _probeContentLength(
    DownloadBatch batch,
    DownloadJob job,
    int index,
  ) async {
    // Every path states why it has no size, so `size=-1` is never a mystery.
    if (needsSessionDownload(batch, job)) {
      return (bytes: null, reason: 'session');
    }
    if (!NetworkStatus.instance.online) return (bytes: null, reason: 'offline');
    final policy = _policyFor(batch.platform);
    final authorized = await policy.authorize(_jobResource(job, index, policy));
    if (authorized.cookie != null && authorized.cookie!.isNotEmpty) {
      return (bytes: null, reason: 'cookie');
    }
    final client = http.Client();
    try {
      final request = http.Request('GET', authorized.uri)
        ..followRedirects = false
        ..headers.addAll(
          unifiedTransferHeaders({...authorized.headers, 'Range': 'bytes=0-0'}),
        );
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 8));
      final acceptRanges = response.headers['accept-ranges'];
      final hasEtag = response.headers.containsKey('etag');
      final hasLastModified = response.headers.containsKey('last-modified');
      unawaited(
        DevLog.write(
          'V16DL',
          'response taskId=${job.currentTaskId ?? job.key} status=${response.statusCode} '
              'accept_ranges=${acceptRanges ?? "none"} has_etag=$hasEtag '
              'has_last_modified=$hasLastModified is_resume=false',
        ),
      );
      try {
        if (response.statusCode == 200) {
          final length = response.contentLength;
          return length == null || length <= 0
              ? (bytes: null, reason: 'no_length')
              : (bytes: length, reason: null);
        }
        if (response.statusCode != 206) {
          return (bytes: null, reason: 'status_${response.statusCode}');
        }
        // `Content-Range: bytes 0-0/12345` carries the full size.
        final range = response.headers['content-range'];
        final total = range == null
            ? null
            : int.tryParse(range.split('/').last.trim());
        return total != null && total > 0
            ? (bytes: total, reason: null)
            : (bytes: null, reason: 'no_range');
      } finally {
        await response.stream.drain<void>().catchError((_) {});
      }
    } catch (e) {
      return (bytes: null, reason: networkCauseOf(e) ?? 'probe_failed');
    } finally {
      client.close();
    }
  }

  Future<void> _failForStorage(
    DownloadBatch batch,
    DownloadJob job,
    int? required, {
    int? free,
  }) async {
    // 2d: Storage shortage enters paused state; do NOT delete partial resume data or call terminal
    job.state = JobState.paused;
    job.userPaused = false;
    job.errorCode = storageFullCode;
    final freeBytes = free ?? await StorageGuard.freeBytes();
    final needBytes =
        required ??
        (job.expectedBytes != null
            ? requiredBytesForDownload(
                job.expectedBytes!,
                job.resumeStartByte ?? 0,
              )
            : null);
    if (needBytes != null && freeBytes != null) {
      final reqStr = (needBytes / (1024 * 1024 * 1024)).toStringAsFixed(2);
      final freeStr = (freeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2);
      job.error = '空间不足 · 需 ${reqStr}GB，可用 ${freeStr}GB';
    } else {
      job.error = '空间不足';
    }
    await _persist(batch);
    notifyListeners();
  }

  /// Delete every temp file of [job]'s attempts (and [path] when given).
  Future<int> _cleanupJobTemp(
    DownloadBatch batch,
    DownloadJob job, {
    String? path,
    String reason = 'cleanup',
  }) async {
    final isAllowedDiscard =
        ((reason == 'cancel' || reason == 'delete') &&
            job.userCancelRequested) ||
        reason == 'size_mismatch' ||
        reason == 'status_200' ||
        reason == 'import_done';
    if ((job.resumeStartByte ?? 0) > 0 &&
        !isAllowedDiscard &&
        job.state != JobState.done) {
      return 0;
    }
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
    if (job.resumeTempPath != null) {
      await remove(File(job.resumeTempPath!));
      job.resumeTempPath = null;
    }
    final kept = job.lowResPath;
    if (kept != null) {
      await remove(File(kept));
      job.lowResPath = null;
    }
    // Clean ResumableDownloadStore
    try {
      final part = await ResumableDownloadStore.instance.partialFileFor(
        job.key,
      );
      await remove(part);
      final meta = await ResumableDownloadStore.instance.metaFileFor(job.key);
      await remove(meta);
    } catch (_) {}

    // Clean background_downloader plugin resumeData
    if (!needsSessionDownload(batch, job)) {
      try {
        await _removeResumeData(job.currentTaskId ?? job.key);
        await _removeResumeData(job.key);
      } catch (_) {}
    }

    try {
      final root =
          await (tempRootForTesting?.call() ?? getTemporaryDirectory());
      final batchDir = Directory(
        '${root.path}/${downloadTempDirectory(batch.batchId, '')}',
      );
      if (await batchDir.exists()) {
        await for (final entry in batchDir.list()) {
          final name = Uri.decodeComponent(
            entry.uri.pathSegments.where((segment) => segment.isNotEmpty).last,
          );
          if (name.startsWith(job.key) ||
              (job.currentTaskId != null &&
                  name.startsWith(job.currentTaskId!)) ||
              name.startsWith('${job.key}-try')) {
            await remove(entry);
          }
        }
      }
      try {
        final sessionF = await _sessionFile(job);
        await remove(sessionF);
        if (await sessionF.parent.exists()) {
          await remove(sessionF.parent);
        }
      } catch (_) {}
    } catch (_) {
      // Temp roots are unavailable in some engines/tests.
    }
    job.resumeStartByte = null;
    job.resumeEtag = null;
    if (bytes > 0 &&
        (reason == 'cancel' ||
            reason == 'delete' ||
            reason == 'size_mismatch' ||
            reason == 'status_200')) {
      unawaited(DevLog.write('V16DL', 'temp_discard reason=$reason'));
    }
    unawaited(
      DevLog.write(
        'V16DL',
        'temp_cleanup reason=$reason bytes=$bytes index=${job.itemIndex}',
      ),
    );
    _log('cleanup bytes=$bytes index=${job.itemIndex}');
    return bytes;
  }

  /// Sweeps orphaned temporary files that have no active batch (2b).
  Future<({int files, int bytes})> tempSweep() async {
    var files = 0;
    var bytes = 0;
    try {
      final activeBatchIds = <String>{};
      final activeJobKeys = <String>{};
      final activeTempPaths = <String>{};
      final activeJobSubdirs = <String>{};
      for (final batch in _batches.values) {
        if (!batch.isTerminal && !batch.usesNewTransferPipeline) {
          activeBatchIds.add(batch.batchId);
          activeBatchIds.add(Uri.encodeComponent(batch.batchId));
          for (final job in batch.jobs) {
            activeJobKeys.add(job.key);
            activeJobSubdirs.add(job.key);
            activeJobSubdirs.add(Uri.encodeComponent(job.key));
            if (job.currentTaskId != null) {
              activeJobSubdirs.add(job.currentTaskId!);
              activeJobSubdirs.add(Uri.encodeComponent(job.currentTaskId!));
            }
            if (job.resumeTempPath != null) {
              activeTempPaths.add(job.resumeTempPath!);
            }
          }
        }
      }

      final root =
          await (tempRootForTesting?.call() ?? getTemporaryDirectory());
      final now = DateTime.now();

      // 1. Sweep com.bbflight.background_downloader files in temp root
      try {
        await for (final entity in root.list()) {
          if (entity is File) {
            final name = entity.uri.pathSegments.lastWhere(
              (s) => s.isNotEmpty,
              orElse: () => '',
            );
            if (name.startsWith('com.bbflight.background_downloader')) {
              if (!activeTempPaths.contains(entity.path)) {
                final stat = await entity.stat();
                if (now.difference(stat.modified) > const Duration(hours: 1)) {
                  bytes += stat.size;
                  files++;
                  try {
                    await entity.delete();
                  } catch (_) {}
                }
              }
            }
          }
        }
      } catch (_) {}

      // 2. Sweep easysave/<batchId>/<jobKey> unclaimed directories and files
      try {
        final easysaveDir = Directory('${root.path}/easysave');
        if (await easysaveDir.exists()) {
          await for (final batchEntity in easysaveDir.list()) {
            if (batchEntity is Directory) {
              final encBatchId = batchEntity.uri.pathSegments.lastWhere(
                (s) => s.isNotEmpty,
                orElse: () => '',
              );
              final batchId = Uri.decodeComponent(encBatchId);
              if (!activeBatchIds.contains(encBatchId) &&
                  !activeBatchIds.contains(batchId)) {
                await for (final child in batchEntity.list(recursive: true)) {
                  if (child is File) {
                    bytes += await child.length();
                    files++;
                  }
                }
                try {
                  await batchEntity.delete(recursive: true);
                } catch (_) {}
              } else {
                await for (final jobEntity in batchEntity.list()) {
                  if (jobEntity is Directory) {
                    final encJobKey = jobEntity.uri.pathSegments.lastWhere(
                      (s) => s.isNotEmpty,
                      orElse: () => '',
                    );
                    final jobKey = Uri.decodeComponent(encJobKey);
                    if (!activeJobSubdirs.contains(encJobKey) &&
                        !activeJobSubdirs.contains(jobKey)) {
                      await for (final child in jobEntity.list(
                        recursive: true,
                      )) {
                        if (child is File) {
                          bytes += await child.length();
                          files++;
                        }
                      }
                      try {
                        await jobEntity.delete(recursive: true);
                      } catch (_) {}
                    }
                  }
                }
              }
            }
          }
        }
      } catch (_) {}

      // 3. Sweep orphaned easysave_dl_* directories
      try {
        await for (final entity in root.list()) {
          if (entity is Directory) {
            final dirName = entity.uri.pathSegments.lastWhere(
              (s) => s.isNotEmpty,
              orElse: () => '',
            );
            if (dirName.startsWith('easysave_dl_')) {
              await for (final child in entity.list(recursive: true)) {
                if (child is File) {
                  bytes += await child.length();
                  files++;
                }
              }
              try {
                await entity.delete(recursive: true);
              } catch (_) {}
            }
          }
        }
      } catch (_) {}

      // 2. Sweep easysave_session orphaned folders
      try {
        final sessionRoot = Directory('${root.path}/easysave_session');
        if (await sessionRoot.exists()) {
          await for (final dir in sessionRoot.list()) {
            if (dir is Directory) {
              final encKey = dir.uri.pathSegments.lastWhere(
                (s) => s.isNotEmpty,
                orElse: () => '',
              );
              final jobKey = Uri.decodeComponent(encKey);
              if (!activeJobKeys.contains(jobKey)) {
                await for (final child in dir.list(recursive: true)) {
                  if (child is File) {
                    bytes += await child.length();
                    files++;
                  }
                }
                try {
                  await dir.delete(recursive: true);
                } catch (_) {}
              }
            }
          }
        }
      } catch (_) {}

      // 3. Sweep easysave_resumes store files older than max age
      try {
        final purged = await ResumableDownloadStore.instance.purgeExpired();
        files += purged;
      } catch (_) {}
    } catch (_) {}

    unawaited(DevLog.write('V16DL', 'temp_sweep files=$files bytes=$bytes'));
    _log('temp_sweep files=$files bytes=$bytes');
    return (files: files, bytes: bytes);
  }

  Future<File> _sessionFile(DownloadJob job) async {
    final root = await (tempRootForTesting?.call() ?? getTemporaryDirectory());
    return File(
      '${root.path}/easysave_session/${Uri.encodeComponent(job.key)}/${job.filename}',
    );
  }

  Future<void> _startSessionDownload(
    DownloadBatch batch,
    DownloadJob job,
  ) async {
    if (_sessionTransfers.containsKey(job.key)) return;
    // Everything below this line needs a connection: an in-process transfer has
    // no native queue to wait in, so it parks here instead of failing (v1.11
    // batch 3). Nothing is spent and nothing is recorded as a failure.
    if (!NetworkStatus.instance.online) {
      await _waitForNetwork(batch, job, cause: 'offline');
      return;
    }
    final file = await _sessionFile(job);
    final transfer =
        sessionTransferForTesting?.call() ?? SessionMediaDownload();
    _sessionTransfers[job.key] = transfer;
    _networkWaits.remove(job.key);
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

  /// Test seam: replaces the in-process HTTP transfer so a connection that
  /// drops, or a network that is down, can be scripted.
  @visibleForTesting
  SessionTransfer Function()? sessionTransferForTesting;

  Future<void> _runSessionDownload(
    DownloadBatch batch,
    DownloadJob job,
    SessionTransfer transfer,
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
        resource: _jobResource(
          job,
          (job.attempts - 1) % job.urls.length,
          _policyFor(batch.platform),
        ),
        onProgress: (progress) {
          job.progress = progress;
          job.lastProgressAt = DateTime.now().millisecondsSinceEpoch;
          notifyListeners();
          unawaited(_refreshNotification(batch));
          _throttlePersistProgress(batch, batch.progress);
        },
        jobKey: job.key,
        itemIndex: job.itemIndex,
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
      if (e.network) {
        // The connection broke or was never there (v1.11 batch 3). Wait for it
        // instead of failing the file: the media was never judged.
        await _waitForNetwork(
          batch,
          job,
          cause: e.statusCode == null ? 'network' : 'status_${e.statusCode}',
          refundAttempt: true,
        );
      } else {
        job.state = JobState.failed;
        job.error = e.message;
        job.lastStatusCode = e.statusCode;
        if (isStorageFullError(e.message)) _markStorageFull(job);
      }
    } catch (e) {
      job.savingPhase = null;
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
    job.error = storageFullMessage(
      job.expectedBytes == null
          ? null
          : requiredBytesForDownload(job.expectedBytes!),
    );
  }

  Future<void> _handleStaleComplete(
    DownloadBatch batch,
    DownloadJob job,
    Task task,
  ) async {
    if (job.saved || job.state == JobState.done) {
      String? filePath;
      try {
        filePath = await task.filePath();
      } catch (_) {}
      final file = filePath != null ? File(filePath) : null;
      try {
        if (file != null && file.existsSync()) file.deleteSync();
      } catch (_) {}
      unawaited(
        DevLog.write('V16DL', 'stale_complete_discarded taskId=${task.taskId}'),
      );
      return;
    }

    String? filePath;
    try {
      filePath = await task.filePath();
    } catch (_) {}
    final file = filePath != null ? File(filePath) : null;
    bool valid = false;
    if (file != null && file.existsSync()) {
      final len = file.lengthSync();
      final expected = job.expectedBytes;
      final sizeMatch = (expected != null && expected > 0)
          ? (len == expected)
          : (len > 0);
      if (sizeMatch) {
        final content = await _contentOf(filePath!);
        final verdict = contentVerdictFor(
          isImage: job.isImage,
          attempts: job.attempts,
          candidateCount: job.urls.length,
          content: content,
        );
        if (verdict == ContentVerdict.accept) {
          valid = true;
        }
      }
    }
    if (valid) {
      unawaited(
        DevLog.write('V16DL', 'adopt_stale_complete taskId=${task.taskId}'),
      );
      if (job.currentTaskId != null && job.currentTaskId != task.taskId) {
        unawaited(
          _cancelTaskWithId(job.currentTaskId!, source: 'adopt_stale_complete'),
        );
      }
      job.currentTaskId = task.taskId;
      _inFlightResumes.remove(job.key);
      job.downloadCompleteAt ??= DateTime.now().millisecondsSinceEpoch;
      unawaited(_finishFile(batch, job, task));
    } else {
      try {
        if (file != null && file.existsSync()) file.deleteSync();
      } catch (_) {}
      unawaited(
        DevLog.write('V16DL', 'stale_complete_discarded taskId=${task.taskId}'),
      );
    }
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
    if (batch.usesNewTransferPipeline) {
      return;
    }
    DownloadJob? job;
    for (final j in batch.jobs) {
      if (j.currentTaskId == task.taskId ||
          task.taskId.startsWith('${j.key}-r') ||
          task.taskId.startsWith('${j.key}-try') ||
          task.taskId == j.key) {
        job = j;
        break;
      }
    }
    if (job == null) return;
    final taskRound = parseTaskRound(task.taskId);
    bool isStale = false;
    if (job.previousTaskIds.contains(task.taskId) &&
        task.taskId != job.currentTaskId) {
      isStale = true;
    } else if (taskRound != null) {
      if (job.round > 0 && taskRound < job.round) {
        isStale = true;
      } else {
        // A1: Only compare round number (-rN), -tryN does not participate in comparison.
        job.currentTaskId = task.taskId;
        if (taskRound > job.round) {
          job.round = taskRound;
        }
      }
    } else if (job.currentTaskId != null && task.taskId != job.currentTaskId) {
      isStale = true;
    }

    if (isStale) {
      final statusName = update is TaskStatusUpdate
          ? update.status.name
          : (update is TaskProgressUpdate ? 'progress' : 'unknown');
      DevLog.write(
        'V16DL',
        'stale_update taskId=${task.taskId} status=$statusName',
      );

      if (update is TaskProgressUpdate ||
          (update is TaskStatusUpdate &&
              (update.status == TaskStatus.running ||
                  update.status == TaskStatus.enqueued))) {
        unawaited(DevLog.write('V16DL', 'zombie_task taskId=${task.taskId}'));
        unawaited(_cancelTaskWithId(task.taskId, source: 'zombie_cancel'));
        return;
      }

      if (update is TaskStatusUpdate && update.status == TaskStatus.complete) {
        unawaited(_handleStaleComplete(batch, job, task));
        return;
      }

      return;
    }
    // A paused job has no live task; a late update of the cancelled one must
    // not flip it back to active/canceled/failed.
    if (job.state == JobState.paused ||
        batch.cancelledByDeletion ||
        job.state == JobState.canceled) {
      return;
    }
    // 3a: A job in the finishing stage cannot be canceled or failed by late background events
    if (job.isFinishing || _finishing.containsKey(job.key)) {
      if (update is TaskStatusUpdate && update.status == TaskStatus.complete) {
        unawaited(_finishFile(batch, job, task));
      }
      return;
    }
    job.lastProgressAt = DateTime.now().millisecondsSinceEpoch;
    if (update is TaskProgressUpdate) {
      if (update.progress >= 0) {
        job.state = JobState.active;
        job.progress = update.progress;
        if (update.progress >= 1.0) {
          job.downloadCompleteAt ??= DateTime.now().millisecondsSinceEpoch;
        }
        notifyListeners();
        unawaited(_refreshNotification(batch));
        _throttlePersistProgress(batch, batch.progress);
      }
      return;
    }
    if (update is! TaskStatusUpdate) return;
    switch (update.status) {
      case TaskStatus.running:
        job.state = JobState.active;
        notifyListeners();
        unawaited(_refreshNotification(batch));
        _throttlePersistProgress(batch, batch.progress);
      case TaskStatus.complete:
        _inFlightResumes.remove(job.key);
        job.downloadCompleteAt ??= DateTime.now().millisecondsSinceEpoch;
        unawaited(_finishFile(batch, job, task));
      case TaskStatus.failed:
      case TaskStatus.notFound:
        job.lastStatusCode = update.responseStatusCode;
        unawaited(_failAttempt(batch, job, update));
      case TaskStatus.canceled:
        // A stale cancellation update for an older task must not cancel a resuming/active/waiting job
        if (job.isWaitingForNetwork || job.state == JobState.queued) {
          return;
        }
        if (!job.userCancelRequested) {
          // Internal interruption: preserve temp file and resume data, enter "下载中断"
          // (JobState.paused), do NOT settle as failed!
          unawaited(_failAttempt(batch, job, update));
          return;
        }
        _inFlightResumes.remove(job.key);
        // A storage failure cancels its task; keep the failure visible.
        if (job.state != JobState.done && job.errorCode != storageFullCode) {
          job.state = JobState.canceled;
        }
        unawaited(_afterTerminal(batch, recovered: false));
      case TaskStatus.paused:
        job.state = JobState.paused;
        final currentJob = job;
        unawaited(() async {
          try {
            final rData = await _getResumeData(task.taskId);
            if (rData != null) {
              currentJob.resumeStartByte = rData.requiredStartByte;
              currentJob.resumeTempPath = rData.data;
              currentJob.resumeEtag = rData.eTag;
              await _persist(batch);
            }
          } catch (_) {}
        }());
        notifyListeners();
      case TaskStatus.enqueued:
      case TaskStatus.waitingToRetry:
        notifyListeners();
    }
  }

  /// Batches whose album was already indexed for the idempotency guard.
  final Set<String> _albumIndexed = <String>{};

  @visibleForTesting
  Future<AssetEntity?> findExistingAlbumAssetForTesting(
    DownloadBatch batch,
    DownloadJob job, {
    bool refresh = false,
  }) => _findExistingAlbumAsset(batch, job, refresh: refresh);

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
    // The full name first, then a base-name match of the *same kind*: an old
    // `…_1.jpg` cover must never answer the lookup of a new `…_1.mp4`, or the
    // video row would take the still's id and fail to play.
    final asset =
        locator.assetByExactName(name) ??
        locator.assetByBaseNameOfType(base, video: !job.isImage) ??
        locator.assetByBaseName(base);
    final matchesType =
        asset != null &&
        (job.isImage
            ? asset.type == AssetType.image
            : asset.type == AssetType.video);
    if (!matchesType) return null;
    final rel = asset.relativePath;
    if (rel != null &&
        rel.isNotEmpty &&
        !GalleryLocatorService.isAllowedPublishPath(
          rel,
          const ['EasySave'],
        )) {
      return null;
    }
    return await locator.isPresent(asset.id) ? asset : null;
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

  Future<bool> _isAlreadySaved(DownloadBatch batch, DownloadJob job) async {
    if (job.saved ||
        job.state == JobState.done ||
        job.mediaId != null ||
        job.assetId != null) {
      return true;
    }
    try {
      final db = await HistoryDb.instance();
      final rec = await db.getByPostId(batch.postId);
      if (rec != null) {
        final savedFile = rec.files
            .where(
              (f) => f.itemIndex == job.itemIndex && f.isImage == job.isImage,
            )
            .firstOrNull;
        if (savedFile != null &&
            (savedFile.assetId != null || savedFile.mediaId != null)) {
          job.assetId ??= savedFile.assetId;
          job.mediaId ??= savedFile.mediaId;
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> _finishFile(
    DownloadBatch batch,
    DownloadJob job,
    Task task,
  ) async {
    if (await _isAlreadySaved(batch, job)) {
      job.saved = true;
      job.state = JobState.done;
      job.error = null;
      unawaited(
        DevLog.write(
          'V16DL',
          'finish_skipped taskId=${task.taskId} index=${job.itemIndex} reason=already_saved',
        ),
      );
      if (batch.isTerminal) {
        await _afterTerminal(batch, recovered: false);
      }
      return;
    }
    if (job.isTerminal) return;
    job.isFinishing = true;
    notifyListeners();
    unawaited(_persist(batch));
    try {
      await _trackFinish(job.key, () => _finishFileOnce(batch, job, task));
    } finally {
      job.isFinishing = false;
      notifyListeners();
      unawaited(_persist(batch));
    }
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
    if (await _isAlreadySaved(batch, job)) {
      job.saved = true;
      job.state = JobState.done;
      job.error = null;
      unawaited(
        DevLog.write(
          'V16DL',
          'finish_skipped taskId=${task.taskId} index=${job.itemIndex} reason=already_saved',
        ),
      );
      return;
    }
    String path;
    try {
      path = await task.filePath();
    } catch (_) {
      if (await _isAlreadySaved(batch, job)) {
        job.saved = true;
        job.state = JobState.done;
        job.error = null;
        unawaited(
          DevLog.write(
            'V16DL',
            'finish_skipped taskId=${task.taskId} index=${job.itemIndex} reason=already_saved',
          ),
        );
        await _persist(batch);
        notifyListeners();
        if (batch.isTerminal) {
          await _afterTerminal(batch, recovered: false);
        }
        return;
      }
      job.error = '文件丢失，请重试';
      job.state = JobState.failed;
      await _persist(batch);
      notifyListeners();
      await _afterTerminal(batch, recovered: false);
      return;
    }

    if (!File(path).existsSync()) {
      if (await _isAlreadySaved(batch, job)) {
        job.saved = true;
        job.state = JobState.done;
        job.error = null;
        unawaited(
          DevLog.write(
            'V16DL',
            'finish_skipped taskId=${task.taskId} index=${job.itemIndex} reason=already_saved',
          ),
        );
        await _persist(batch);
        notifyListeners();
        if (batch.isTerminal) {
          await _afterTerminal(batch, recovered: false);
        }
        return;
      }
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

    final waitMs = job.downloadCompleteAt != null
        ? (DateTime.now().millisecondsSinceEpoch - job.downloadCompleteAt!)
        : 0;
    job.waitCompleteMs = waitMs;

    // The plan trusts URL kinds; the bytes decide. A CDN may answer an image
    // URL with an ISO-BMFF HEIC (saved as an unplayable .mp4 before this
    // check), or with the post's own motion clip (a parent video URL).
    final content = await _contentOf(path);
    final verdict = contentVerdictFor(
      isImage: job.isImage,
      attempts: job.attempts,
      candidateCount: job.urls.length,
      content: content,
    );
    // A HEIC / HEIF / AVIF original is only accepted when the platform
    // decoders of *this* device really decode it. The probe runs on the
    // finished temp file, off the main thread and off photo_manager's queue,
    // and it is bounded: a decode that never answers cannot hold the item.
    final effective = await _gatedVerdict(batch, job, path, content, verdict);
    if (effective != ContentVerdict.accept) {
      await _handleContentVerdict(batch, job, path);
      return;
    }
    // Quality first: the candidates are ordered so a preview-size derivative is
    // only downloaded once every original-resolution one failed. Its file is a
    // scaled copy, so it keeps the existing "非原图" mark.
    _markPreviewOnly(job);

    if (await shouldRetryForMissingAudio(job, path)) {
      unawaited(
        DevLog.write(
          'V16DL', // i18n:ignore 日志
          'event=retry reason=no_audio_track index=${job.itemIndex} '
              'candidate=${candidateProgressLabel(job)}',
        ),
      );
      try {
        await File(path).delete();
      } catch (_) {}
      await _enqueueAttempt(batch, job, source: 'missing_audio');
      return;
    }

    await _importFile(
      batch,
      job,
      path,
      existingAssetId: existingAssetId,
      itemIndex: itemIndex,
      isImage: isImage,
      content: content,
    );
  }

  /// Header identity of a finished file (production: [sniffMediaFile]).
  @visibleForTesting
  Future<MediaContentType?> Function(String path)? mediaContentTypeForTesting;

  Future<MediaContentType?> _contentOf(String path) async {
    try {
      return await (mediaContentTypeForTesting ?? sniffMediaFile)(path);
    } catch (_) {
      return null;
    }
  }

  /// What the role of [job] is called in logs and in user-facing text.
  static String roleOf(DownloadJob job) => job.isLivePhoto
      ? (job.isImage ? 'live_still' : 'live_clip')
      : (job.isImage ? 'image' : 'video');

  /// Marks a still whose file came from a preview-size candidate "非原图": the
  /// quality ladder only reaches a preview once every original-resolution
  /// candidate of the item failed.
  void _markPreviewOnly(DownloadJob job) {
    if (!importsPreviewOnly(job)) return;
    job.notOriginal = true;
    unawaited(
      DevLog.write(
        'V16DL', // i18n:ignore 日志
        'item preview_only index=${job.itemIndex} role=${roleOf(job)} '
            'label=${candidateLabelOf(candidateUrlOf(job) ?? '')} '
            'not_original=true',
      ),
    );
  }

  /// The candidate URL [job] just downloaded (never logged verbatim).
  static String? candidateUrlOf(DownloadJob job) {
    if (job.urls.isEmpty) return null;
    return job.urls[candidateIndexOf(job)];
  }

  /// Index into [urls] of [job]'s last attempt: [candidateIndex] only advances
  /// to a *different* candidate, so a backoff retry keeps pointing at the same
  /// URL. Clamped, never wrapped: a candidate is never downloaded twice except
  /// by its one deliberate backoff retry.
  static int candidateIndexOf(DownloadJob job) {
    final last = job.urls.length - 1;
    if (last <= 0) return 0;
    if (job.candidateIndex < 0) return 0;
    return job.candidateIndex > last ? last : job.candidateIndex;
  }

  /// `2/4`-style label for the candidate being tried.
  ///
  /// The numerator is the candidate's own position, not the retry counter:
  /// build 48 logged `candidate=3/1` and `candidate=11/4` because the attempt
  /// counter (which keeps growing across backoff retries) was printed over the
  /// number of candidates.
  static String candidateProgressLabel(DownloadJob job) =>
      '${candidateIndexOf(job) + 1}/${job.urls.length}';

  String? _candidateUrlOf(DownloadJob job) => candidateUrlOf(job);

  /// `[V16DL] candidate index=2 role=live_still label=img:jpg bytes=… sniff=heic
  /// result=…` — host/format label only, no URL, query, cookie or account.
  Future<void> _logCandidate(
    DownloadBatch batch,
    DownloadJob job,
    String path,
    MediaContentType? content,
    ContentVerdict verdict, {
    String? extra,
  }) async {
    var bytes = -1;
    try {
      bytes = await File(path).length();
    } catch (_) {}
    final label = candidateLabelOf(_candidateUrlOf(job) ?? '');
    final sniff = content?.extension ?? 'unknown';
    final result = switch (verdict) {
      // A HEIC / AVIF / GIF still is saved in its own container without
      // embedded provenance: a success, logged as such.
      ContentVerdict.accept =>
        content == null ||
                sniff == 'unknown' ||
                !content.isImage ||
                provenanceEmbeddableStill(content)
            ? 'ok'
            : 'ok:provenance_skipped',
      ContentVerdict.rejectKind =>
        job.isImage ? 'rejected:video_container' : 'rejected:still_for_video',
      ContentVerdict.rejectUnplayable => 'rejected:unplayable_video',
      ContentVerdict.rejectUndecodableOnDevice =>
        'rejected:undecodable_on_device',
    };
    unawaited(
      DevLog.write(
        'V16DL', // i18n:ignore 日志
        'candidate index=${job.itemIndex} role=${roleOf(job)} label=$label '
            'bytes=$bytes sniff=$sniff result=$result '
            'candidate=${candidateProgressLabel(job)} '
            'format_pref=${batch.formatPref.logToken}'
            '${extra == null ? '' : ' $extra'}',
      ),
    );
  }

  /// The verdict of a finished file after the device decode gate, logged once.
  ///
  /// Only a still whose own header says the platform must decode it
  /// ([requiresDeviceDecode]) is probed; everything else keeps the content
  /// verdict unchanged. The probe never runs on the main thread or on
  /// photo_manager's queue, and its timeout cannot block another item.
  Future<ContentVerdict> _gatedVerdict(
    DownloadBatch batch,
    DownloadJob job,
    String path,
    MediaContentType? content,
    ContentVerdict verdict,
  ) async {
    final gate = verdict != ContentVerdict.accept
        ? const StillDecodeGate.notRequired()
        : await (ImageDecodeProbe.stillGateForTesting ??
              StillDecodeGate.forStoredStill)(content, path);
    final effective = gate.rejected
        ? ContentVerdict.rejectUndecodableOnDevice
        : verdict;
    await _logCandidate(
      batch,
      job,
      path,
      content,
      effective,
      extra: gate.probed ? gate.logFields : null,
    );
    return effective;
  }

  @visibleForTesting
  Future<ContentVerdict> gatedVerdictForTesting(
    DownloadBatch batch,
    DownloadJob job,
    String path, {
    MediaContentType? content,
  }) => _gatedVerdict(
    batch,
    job,
    path,
    content,
    contentVerdictFor(
      isImage: job.isImage,
      attempts: job.attempts,
      candidateCount: job.urls.length,
      content: content,
    ),
  );

  /// Per-item, user-readable failure text ("第3项实况的静态图保存失败"). Never
  /// the raw exception: a `StateError('该格式…')` prefix belongs in the log.
  static String failureTextFor(DownloadJob job, {bool saving = false}) {
    final where = job.itemIndex > 0 ? '第${job.itemIndex}项' : '该文件';
    final what = job.isLivePhoto
        ? (job.isImage ? '实况的静态图' : '实况的动态视频')
        : (job.isImage ? '图片' : '视频');
    return '$where$what${saving ? '保存' : '下载'}失败';
  }

  /// The file's own container when it contradicts [job], null when it matches
  /// or the header is unreadable (kept, as before this check existed).
  Future<MediaContentType?> _wrongContent(DownloadJob job, String path) async {
    final content = await _contentOf(path);
    if (content == null) return null;
    final kindMismatch = content.isImage != job.isImage;
    final unplayable = content.playable == false;
    return kindMismatch || unplayable ? content : null;
  }

  @visibleForTesting
  Future<MediaContentType?> wrongContentForTesting(
    DownloadJob job,
    String path,
  ) => _wrongContent(job, path);

  @visibleForTesting
  Future<void> discardWrongContentForTesting(
    DownloadBatch batch,
    DownloadJob job,
    String path,
  ) => _discardWrongContent(batch, job, path);

  /// Acts on a finished file whose own bytes are not what the job's current
  /// candidate should deliver.
  Future<void> _handleContentVerdict(
    DownloadBatch batch,
    DownloadJob job,
    String path,
  ) async {
    await _discardWrongContent(batch, job, path);
  }

  /// Drops a finished file whose own bytes are not what [job] asked for. The
  /// next candidate is tried; once every candidate is used the job fails, so a
  /// still never lands in the album under a `.mp4` name.
  Future<void> _discardWrongContent(
    DownloadBatch batch,
    DownloadJob job,
    String path,
  ) async {
    try {
      await File(path).delete();
    } catch (_) {}
    if (job.attempts < candidateCapFor(job)) {
      await _persist(batch);
      await _enqueueAttempt(batch, job, source: 'wrong_content');
      return;
    }
    if (await _importBestSetAside(batch, job, reason: 'content_rejected')) {
      return;
    }
    await _failReadable(batch, job);
  }

  /// Imports the largest still kept aside while better candidates were tried.
  /// Returns false when nothing was set aside, so the caller can fail the job.
  Future<bool> _importBestSetAside(
    DownloadBatch batch,
    DownloadJob job, {
    required String reason,
  }) async {
    // A full-size image kept from an earlier candidate still beats nothing;
    // it already matched the job's kind when it was set aside.
    final kept = job.lowResPath;
    if (job.isImage && kept != null && await File(kept).exists()) {
      job
        ..lowResPath = null
        ..notOriginal = true;
      _log(
        'importing low resolution copy index=${job.itemIndex} reason=$reason',
      );
      await _importFile(
        batch,
        job,
        kept,
        isImage: true,
        itemIndex: job.itemIndex,
      );
      return true;
    }
    return false;
  }

  /// Fails [job] with a per-item, user-readable message (no raw exception).
  Future<void> _failReadable(
    DownloadBatch batch,
    DownloadJob job, {
    String? error,
    String? code,
  }) async {
    job
      ..state = JobState.failed
      ..errorCode = code
      ..error = error ?? (job.isImage ? failureTextFor(job) : '下载到的文件不是视频，已跳过');
    await _cleanupJobTemp(batch, job, reason: 'final_fail');
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch, recovered: false);
  }

  Future<void> _importFile(
    DownloadBatch batch,
    DownloadJob job,
    String path, {
    String? existingAssetId,
    int? itemIndex,
    required bool isImage,
    MediaContentType? content,
  }) async {
    // A file the developer switch failed stays failed until the user retries
    // it: a late task or a reconciler pass must not sneak it into the album.
    if (job.errorCode == simulatedFailureCode) return;
    int? sourceBytes;
    try {
      sourceBytes = await File(path).length();
    } catch (_) {}
    // A hung album scan / metadata write / gallery copy must not leave the
    // job `active` forever (the batch would never finish).
    final work = (() async {
      // Developer switch (v1.11 batch 2, targeted at the plan's first file in
      // batch 3): the download finished, nothing has been written to the
      // album yet. The failure is final on purpose — the switch exists to see
      // the failure state and its snapshot, so no automatic path may
      // re-download the file afterwards. A manual retry clears the code and
      // downloads normally.
      if (DevDownloadFailure.take(
        batch.batchId,
        firstFile: batch.jobs.isNotEmpty && identical(batch.jobs.first, job),
      )) {
        unawaited(
          DevLog.write(
            logTag, // i18n:ignore 日志
            'simulated_failure=1 ${job.key}',
          ),
        );
        job
          ..errorCode = simulatedFailureCode
          ..error = '下载失败（模拟失败）'
          ..state = JobState.failed;
        return;
      }
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
          if (read == null && job.provenanceSkipped) {
            // A HEIC/AVIF still carries no provenance by design, so there
            // are no credentials to compare; the album name (<postId>_<n>)
            // already pins its identity.
            reusedProvenance = null;
          } else if (read == null ||
              read.platform != expected.platform ||
              read.sourceId != expected.sourceId ||
              read.itemIndex != expected.itemIndex) {
            existing = null;
          } else {
            reusedProvenance = read;
          }
          if (existing != null) {
            final expectedSize = job.fileBytes ?? await file.length();
            final albumSize = await (mediaSizeForTesting ?? _mediaSize)(
              existing.id,
              !job.isImage,
            );
            if (albumSize == null ||
                albumSize <= 0 ||
                (expectedSize > 0 && albumSize != expectedSize)) {
              existing = null;
            }
          }
        }
        if (existing != null) {
          _log(
            'gallery import skipped, already saved: ${existing.title ?? job.filename}',
          );
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
          job.savingPhase = '写入来源信息';
          notifyListeners();
          await _persist(batch);
          final provSw = Stopwatch()..start();
          final writtenAssetId = await _embedProvenance(
            filePath: path,
            batch: batch,
            job: job,
            existingAssetId: existingAssetId,
            itemIndex: itemIndex ?? job.itemIndex,
            content: content,
          );
          provSw.stop();
          job.provenanceMs = provSw.elapsedMilliseconds;
          try {
            job.fileBytes = await File(path).length();
            job.provenanceBytesWritten = job.fileBytes;
          } catch (_) {}
          final finalName = await exportNameFor(
            path,
            batch.postId,
            itemIndex ?? job.itemIndex,
          );

          job.savingPhase = '复制到相册';
          notifyListeners();
          await _persist(batch);
          final copySw = Stopwatch()..start();
          final outcome = await saveWithConflictHandling(
            filename: finalName,
            tempPath: path,
            album: batch.album,
            // A provenance-skipped still (HEIC / HEIF / AVIF / GIF) carries no
            // embedded identity, so the collision lookup never inspects an
            // album row: the native import writes the bytes directly; name
            // clashes fall back through the saved filename ladder instead.
            inspect: job.provenanceSkipped ? (String name) async => null : null,
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
          copySw.stop();
          job.importCopyMs = copySw.elapsedMilliseconds;
          job.importBytes = job.fileBytes ?? 0;
          final saved = outcome.saved;
          job.importThread = saved.thread ?? 'bg';
          _log(
            'gallery import done: ${saved.title ?? job.filename} mime=${content?.mime ?? '-'} -> ${saved.mediaId}',
          );
          job.mediaId = saved.mediaId;
          job.savedTitle = saved.title;
          job.relativePath = saved.relativePath;
          job.state = JobState.done;
          job.progress = 1;
          job.saved = true;
          job.savingPhase = null;
          batch.historyWritten = false;
          batch.settledBy = null;

          // Store assetId for reuse
          job.assetId = outcome.reusedAssetId ?? writtenAssetId;
        }
      }
    })();
    try {
      await work.timeout(
        finishTimeoutForTesting ?? finishTimeoutFor(sourceBytes),
      );
    } on TimeoutException {
      _log(
        'gallery import timed out: planned=${job.filename} bytes=${sourceBytes ?? -1}',
      );
      job.error = '保存超时，请重试';
      job.state = JobState.failed;
      // The album copy keeps running; record its real outcome when it ends
      // instead of leaving an album file without a history row.
      _lateImports[job.key] = work
          .then(
            (_) => _settleLateImport(batch, job, path),
            onError: (Object e) =>
                _settleLateImport(batch, job, path, error: e),
          )
          .whenComplete(() {
            // A block body: returning the removed future would await itself.
            _lateImports.remove(job.key);
          });
    } catch (e) {
      job.state = JobState.failed;
      if (isStorageFullError(e)) {
        _markStorageFull(job);
      } else {
        // The raw exception ("Bad state: 该格式无法写入来源信息") stays in the
        // log; the user gets a per-item sentence they can act on.
        _log(
          'import failed index=${job.itemIndex} role=${roleOf(job)} '
          'type=${e.runtimeType} detail=$e',
        );
        job.error = failureTextFor(job, saving: true);
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
      batch.settledBy = null;
      _settledBatchIds.remove(batch.batchId);
      await _persist(batch);
      notifyListeners();
      await _afterTerminal(batch, recovered: false);
      return;
    }
    _log(
      'late import failed index=${job.itemIndex} '
      'reason=${isStorageFullError(error) ? storageFullCode : error?.runtimeType ?? 'unsaved'}',
    );
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
    if (read == null && job.provenanceSkipped) {
      // A still kept in its own format (HEIC / AVIF) never carries provenance.
      final size = await (mediaSizeForTesting ?? _mediaSize)(
        asset.id,
        !job.isImage,
      );
      if (job.fileBytes != null && size != job.fileBytes) {
        _log(
          'retry album copy rejected index=${job.itemIndex} reason=size '
          'album=${size ?? -1} expected=${job.fileBytes}',
        );
        return null;
      }
      return asset;
    }
    if (read == null ||
        read.platform != expected.platform ||
        read.sourceId != expected.sourceId ||
        read.itemIndex != expected.itemIndex) {
      _log(
        'retry album copy rejected index=${job.itemIndex} reason=provenance',
      );
      return null;
    }
    final size = await (mediaSizeForTesting ?? _mediaSize)(
      asset.id,
      !job.isImage,
    );
    if (job.fileBytes != null && size != job.fileBytes) {
      _log(
        'retry album copy rejected index=${job.itemIndex} reason=size '
        'album=${size ?? -1} expected=${job.fileBytes}',
      );
      return null;
    }
    job.provenanceItemCount = read.itemCount;
    job.provenanceCapturedBy = read.capturedBy;
    return asset;
  }

  static Future<int?> _mediaSize(String mediaId, bool video) async {
    try {
      final size = await const MethodChannel(
        'easysave/media',
      ).invokeMethod<num>('mediaSize', {'id': mediaId, 'video': video});
      return size?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// Embed provenance metadata into an image or video file.
  /// Returns the assetId if written, null when disabled by the user or when the
  /// container cannot carry provenance (HEIC / AVIF / GIF stills: the file is
  /// saved in its original format instead, and history still records the pair).
  Future<String?> _embedProvenance({
    required String filePath,
    required DownloadBatch batch,
    required DownloadJob job,
    String? existingAssetId,
    required int itemIndex,
    MediaContentType? content,
  }) async {
    job.metadataNotice = null;
    // Check setting
    final settings = await AppSettings.load();
    if (!settings.saveProvenanceInImages) {
      _log('provenance skipped (setting disabled): ${job.filename}');
      return null;
    }
    // A HEIC / AVIF / GIF still is a real photo and is saved as it arrived.
    // provenance_dart has no writer for those containers (every ISO-BMFF file
    // looks like MP4 to it), so the metadata is skipped instead of failing the
    // whole item.
    final type = content ?? await _contentOf(filePath);
    if (type != null && type.isImage && !provenanceEmbeddableStill(type)) {
      job
        ..provenanceSkipped = true
        ..metadataNotice = null;
      unawaited(
        DevLog.write(
          'V16DL', // i18n:ignore 日志
          'candidate index=${job.itemIndex} role=${roleOf(job)} '
              'sniff=${type.extension} result=ok:provenance_skipped '
              'provenance=skipped container=${type.extension}',
        ),
      );
      _log(
        'provenance=skipped index=${job.itemIndex} '
        'container=${type.extension} (saved in its own format)',
      );
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

  Future<({bool acceptsRange, int? contentLength})> _probeCandidateRangeAndSize(
    DownloadBatch batch,
    DownloadJob job,
    String url,
  ) async {
    try {
      final probeFn = candidateRangeProbeForTesting;
      if (probeFn != null) {
        return await probeFn(job, url);
      }
      final policy = _policyFor(batch.platform);
      final resource = _jobResource(job, 0, policy);
      final authorized = await policy.authorize(resource);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      final req = await client.openUrl('GET', authorized.uri);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      unifiedTransferHeaders(authorized.headers).forEach((k, v) {
        req.headers.set(k, v);
      });
      final resp = await req.close();
      final statusCode = resp.statusCode;
      final acceptRanges = resp.headers.value(HttpHeaders.acceptRangesHeader);
      final contentRange = resp.headers.value('content-range');
      int? total;
      if (contentRange != null) {
        final match = RegExp(r'/(\d+)').firstMatch(contentRange);
        if (match != null) {
          total = int.tryParse(match.group(1)!);
        }
      }
      total ??= resp.contentLength > 0 ? resp.contentLength : null;
      await resp.drain();
      client.close();
      final acceptsRange = statusCode == 206 || acceptRanges == 'bytes';
      return (acceptsRange: acceptsRange, contentLength: total);
    } catch (_) {
      return (acceptsRange: false, contentLength: null);
    }
  }

  Future<bool> _handleExpiredUrlResume(
    DownloadBatch batch,
    DownloadJob job,
    ResumeData resumeData,
  ) async {
    if (job.isFinishing || _finishing.containsKey(job.key)) {
      unawaited(
        DevLog.write(
          'V16DL',
          'enqueue_blocked taskId=${job.currentTaskId ?? job.key} index=${job.itemIndex} role=${roleOf(job)} reason=finishing source=expired_url',
        ),
      );
      return false;
    }
    if (job.saved || job.state == JobState.done) {
      unawaited(
        DevLog.write(
          'V16DL',
          'enqueue_blocked taskId=${job.currentTaskId ?? job.key} index=${job.itemIndex} role=${roleOf(job)} reason=completed source=expired_url',
        ),
      );
      return false;
    }
    try {
      final outcome =
          await (reparseForTesting?.call(batch.postUrl) ??
              parsePostOutcome(
                batch.postUrl,
                source: 'download_retry',
                forceRefresh: true,
              ));
      final postIdx = job.itemIndex > 0 ? job.itemIndex - 1 : job.itemIndex;
      final planned =
          planFiles(
                outcome.data,
                [postIdx],
                (_, _, _) => job.filename,
                formatPref: (await AppSettings.load()).imageFormat,
              )
              .where(
                (file) =>
                    file.isImage == job.isImage &&
                    file.isLivePhoto == job.isLivePhoto,
              )
              .firstOrNull;
      if (planned != null && planned.urls.isNotEmpty) {
        final policy = _policyFor(batch.platform);
        final declarations = policy.resourcesFor(outcome.data.items[postIdx]);
        final freshResources = [
          for (final u in planned.urls)
            resourceForCandidate(policy, declarations, u),
        ];
        job.urls = planned.urls;
        job.resources = freshResources;

        final freshUrl = planned.urls.first;
        final probe = await _probeCandidateRangeAndSize(batch, job, freshUrl);
        final total = job.expectedBytes ?? -1;
        if (probe.acceptsRange &&
            (total <= 0 || probe.contentLength == total)) {
          final authorized = await policy.authorize(job.resources.first);
          final updatedTask = DownloadTask(
            taskId: job.currentTaskId ?? job.key,
            url: freshUrl,
            filename: job.filename,
            headers: unifiedTransferHeaders(authorized.headers),
            directory: downloadTempDirectory(
              batch.batchId,
              job.currentTaskId ?? job.key,
            ),
            baseDirectory: BaseDirectory.temporary,
            group: batch.batchId,
            updates: Updates.statusAndProgress,
            retries: 0,
            allowPause: true,
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
              'mediaPolicyHosts':
                  (policy.site.data['download'] as Map)['mediaHosts'],
            }),
          );
          await _setResumeData(
            ResumeData(
              updatedTask,
              resumeData.data,
              resumeData.requiredStartByte,
              resumeData.eTag,
            ),
          );
          unawaited(
            DevLog.write(
              'V16DL',
              'resume index=${job.itemIndex} role=${roleOf(job)} from_bytes=${resumeData.requiredStartByte} '
                  'total=$total result=resumed reason=range_accepted',
            ),
          );
          final resumed = await _resumeTask(updatedTask);
          if (resumed) return true;
        } else {
          try {
            final f = File(resumeData.data);
            if (await f.exists()) await f.delete();
          } catch (_) {}
          await _removeResumeData(job.currentTaskId ?? job.key);
          unawaited(
            DevLog.write(
              'V16DL',
              'resume index=${job.itemIndex} role=${roleOf(job)} from_bytes=0 '
                  'total=${probe.contentLength ?? total} result=restart reason=${!probe.acceptsRange ? 'no_range' : 'validator_changed'}',
            ),
          );
          job.progress = 0;
          await _enqueueAttempt(batch, job, source: 'expired_url');
          return true;
        }
      }
    } catch (e) {
      _log('reparse after expired URL failed index=${job.itemIndex}: $e');
    }
    return false;
  }

  Future<void> _failAttempt(
    DownloadBatch batch,
    DownloadJob job,
    TaskStatusUpdate update,
  ) async {
    _inFlightResumes.remove(job.key);
    final isResumable =
        !job.isImage &&
        (job.expectedBytes == null || job.expectedBytes! >= kResumableMinBytes);
    final taskId = update.task.taskId;
    ResumeData? resumeData;
    if (isResumable) {
      try {
        resumeData = await _getResumeData(
          taskId,
        ).timeout(const Duration(milliseconds: 300), onTimeout: () => null);
      } catch (_) {}
    }
    File? tempFile;
    int tempSize = -1;
    bool tempExists = false;
    if (resumeData != null && resumeData.data.isNotEmpty) {
      tempFile = File(resumeData.data);
      tempExists = tempFile.existsSync();
      if (tempExists) tempSize = tempFile.lengthSync();
    }
    final hasEtag = resumeData?.eTag != null && resumeData!.eTag!.isNotEmpty;
    if (resumeData != null && resumeData.data.isNotEmpty) {
      job.resumeTempPath = resumeData.data;
      if (resumeData.eTag != null && resumeData.eTag!.isNotEmpty) {
        job.resumeEtag = resumeData.eTag;
      }
      await ResumableDownloadStore.instance.writeMetadata(
        job.key,
        ResumeMetadata(
          validator: resumeData.eTag ?? '',
          totalBytes: job.expectedBytes ?? -1,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    unawaited(
      DevLog.write(
        'V16DL',
        'failure_callback taskId=$taskId status=${update.status.name} '
            'exception_type=${update.exception?.exceptionType ?? "none"} '
            'has_resume_data=${resumeData != null} '
            'required_start_byte=${resumeData?.requiredStartByte ?? 0} '
            'temp_exists=$tempExists temp_size=$tempSize has_etag=$hasEtag',
      ),
    );
    final diagnostic = update.exception?.description ?? '';
    if (_diagnosticPolicyCode.hasMatch(diagnostic)) {
      unawaited(DevLog.write('RequestPolicy', diagnostic));
      job.state = JobState.failed;
      // A policy rejection is final: retrying the same URL cannot pass a rule
      // that exists to keep it out, and build 46 showed what re-enqueuing it
      // costs (220 rejections for one batch, `attempt=5/3` in the item log).
      job.errorCode = policyRejectedCode;
      job.error = diagnostic.startsWith('REQUEST_EXPIRED ')
          ? expiredMediaMessage
          : '该资源地址不在允许范围内';
      await _persist(batch);
      notifyListeners();
      await _afterTerminal(batch, recovered: false);
      return;
    }
    if (isStorageFullError(diagnostic) ||
        isStorageFullError(update.exception)) {
      _log(
        'download write failed index=${job.itemIndex} reason=$storageFullCode',
      );
      await _failForStorage(batch, job, null);
      return;
    }
    // One line per failed attempt: the retry counter is bounded by
    // retryCapFor(), so the log always shows how a file used its tries. The
    // host class and the cause are fixed tokens — never the URL, the host name
    // or its query.
    final cap = retryCapFor(batch, job);
    final cause = _failureCause(
      update,
      userCancelRequested: job.userCancelRequested,
    );

    final desc = update.exception?.description ?? '';
    final isSizeMismatch = desc.contains('size_mismatch');
    if (isSizeMismatch) {
      final fromBytes = (job.expectedBytes != null && job.progress > 0)
          ? (job.expectedBytes! * job.progress).round()
          : 0;
      unawaited(
        DevLog.write(
          'V16DL',
          'resume taskId=$taskId index=${job.itemIndex} role=${roleOf(job)} from_bytes=$fromBytes '
              'total=${job.expectedBytes ?? -1} result=restart reason=size_mismatch',
        ),
      );
      unawaited(DevLog.write('V16DL', 'temp_discard reason=size_mismatch'));
      await _removeResumeData(job.currentTaskId ?? job.key);
      await ResumableDownloadStore.instance.cleanForJob(job.key);
      job.resumeStartByte = null;
      job.resumeTempPath = null;
      job.resumeEtag = null;
      job.progress = 0;
      await _enqueueAttempt(batch, job, source: 'size_mismatch');
      return;
    }

    final isValidatorChanged =
        desc.contains('ETag is not identical') ||
        desc.contains('validator_changed');
    if (isValidatorChanged) {
      final fromBytes = (job.expectedBytes != null && job.progress > 0)
          ? (job.expectedBytes! * job.progress).round()
          : 0;
      unawaited(
        DevLog.write(
          'V16DL',
          'resume index=${job.itemIndex} role=${roleOf(job)} from_bytes=$fromBytes '
              'total=${job.expectedBytes ?? -1} result=restart reason=validator_changed',
        ),
      );
      await _removeResumeData(job.currentTaskId ?? job.key);
      await ResumableDownloadStore.instance.cleanForJob(job.key);
      job.resumeStartByte = null;
      job.resumeTempPath = null;
      job.resumeEtag = null;
      job.progress = 0;
      await _enqueueAttempt(batch, job, source: 'validator_changed');
      return;
    }

    if ((update.responseStatusCode == 403 ||
            update.responseStatusCode == 410) &&
        isResumable) {
      final resumeData = await _getResumeData(job.currentTaskId ?? job.key);
      if (resumeData != null &&
          resumeData.requiredStartByte >= kResumableMinBytes) {
        final fromBytes = resumeData.requiredStartByte;
        final total = job.expectedBytes ?? -1;
        unawaited(
          DevLog.write(
            'V16DL',
            'resume index=${job.itemIndex} role=${roleOf(job)} from_bytes=$fromBytes '
                'total=$total result=restart reason=expired',
          ),
        );
        final handled = await _handleExpiredUrlResume(batch, job, resumeData);
        if (handled) return;
      }
    }

    final partialBytes = await _calculateResumeStartByte(
      job,
      resumeData: resumeData,
      taskId: taskId,
      filename: job.filename,
      batchId: batch.batchId,
    );

    final isResumeFail =
        desc.contains('resume_failed') ||
        update.exception is TaskResumeException;
    final failReason = isResumeFail
        ? 'resume_failed'
        : (update.status == TaskStatus.canceled && !job.userCancelRequested
              ? 'interrupted'
              : (cause.isNotEmpty
                    ? cause
                    : (_transferReason(
                            update,
                            userCancelRequested: job.userCancelRequested,
                          ).isNotEmpty
                          ? _transferReason(
                              update,
                              userCancelRequested: job.userCancelRequested,
                            )
                          : update.status.name)));
    _trackFailureReason(job, failReason);

    // Rule A2: App-initiated / internal cancellation without user cancel requested
    // must never lead to final failure.
    final isInternalInterrupt =
        update.status == TaskStatus.canceled && !job.userCancelRequested;
    if (isInternalInterrupt) {
      if (partialBytes > 0 && isResumable) {
        // Handled below by the existing partialBytes > 0 && isResumable block
      } else {
        // If no downloaded data: automatically re-enqueue from scratch, counting towards regular retry attempts.
        if (job.attempts < cap) {
          unawaited(
            DevLog.write(
              'V16DL',
              'auto_retry reason=interrupted from_bytes=0 attempt=${job.attempts + 1}/$cap',
            ),
          );
          job.state = JobState.queued;
          job.error = null;
          await _persist(batch);
          notifyListeners();
          await _enqueueAttempt(batch, job, source: 'interrupted_retry');
          return;
        } else {
          // Cap exhausted: park as paused ("已中断，点继续"), NEVER final fail, NEVER cleanup temp with final_fail
          job.state = JobState.paused;
          job.userPaused = false;
          job.error = '已中断，点继续';
          _autoResumeTimers.remove(job.key)?.cancel();
          await _persist(batch);
          notifyListeners();
          unawaited(_refreshNotification(batch));
          return;
        }
      }
    }

    // B5: 同一原因连续失败 2 次（例如两次都是 resume_failed）时，不再用同样的参数重试：按 B1 重新计算起点；仍然失败就转为「已中断，点继续」，不得无限循环。
    if (job.consecutiveFailCount >= 2 && isResumable) {
      if (job.consecutiveFailCount > 2) {
        job.state = JobState.paused;
        job.userPaused = false;
        job.error = '已中断，点继续';
        _autoResumeTimers.remove(job.key)?.cancel();
        await _persist(batch);
        notifyListeners();
        unawaited(_refreshNotification(batch));
        return;
      }
    }

    // Rule 2a: If temp file has bytes (> 0), ANY failure (resume_failed, connection abort,
    // timeout, unknown) must NEVER mark final failure or delete temp file. Enter "下载中断"
    // (JobState.paused).
    if (partialBytes > 0 && isResumable) {
      _inFlightResumes.remove(job.key);
      job.state = JobState.paused;
      job.lastProgressAt = DateTime.now().millisecondsSinceEpoch;
      job.resumeStartByte = partialBytes;
      if (job.resumeTempPath != null && job.resumeTempPath!.isNotEmpty) {
        final updatedResumeData = ResumeData(
          update.task,
          job.resumeTempPath!,
          partialBytes,
          resumeData?.eTag ?? job.resumeEtag,
        );
        try {
          await _setResumeData(updatedResumeData);
        } catch (_) {}
      }
      if (resumeData?.eTag != null && resumeData!.eTag!.isNotEmpty) {
        job.resumeEtag = resumeData.eTag;
      }

      final lastFailReason = failReason;

      final settings = await AppSettings.load();
      if (settings.manualResumeOnlyOnDisconnect) {
        job.error = '已中断，点继续';
        await _persist(batch);
        notifyListeners();
        unawaited(_refreshNotification(batch));
        return;
      }

      // If offline, wait for network recovery (stability timer will trigger auto-resume)
      if (!NetworkStatus.instance.online) {
        job.error = '下载中断 · 等待网络';
        await _persist(batch);
        notifyListeners();
        unawaited(_refreshNotification(batch));
        return;
      }

      // 2b. Auto-resume: max 5 retries with exponential backoff (5s, 15s, 30s, 60s, 120s)
      final retries = _autoResumeRetries[job.key] ?? 0;
      if (retries < 5) {
        final nextRetry = retries + 1;
        final backoff = kAutoResumeBackoff[retries];
        job.error = '自动重试 $nextRetry/5';
        await _persist(batch);
        notifyListeners();
        unawaited(_refreshNotification(batch));

        _autoResumeTimers[job.key]?.cancel();
        _autoResumeTimers[job.key] = Timer(backoff, () async {
          _autoResumeTimers.remove(job.key);
          if (batch.usesNewTransferPipeline) return;
          if (job.state != JobState.paused) return;
          if (_isResumeInFlight(job)) {
            unawaited(
              DevLog.write(
                'V16DL',
                'resume_skipped reason=in_flight source=auto_resume',
              ),
            );
            return;
          }
          if (!NetworkStatus.instance.online) {
            job.error = '下载中断 · 等待网络';
            await _persist(batch);
            notifyListeners();
            return;
          }
          _autoResumeRetries[job.key] = nextRetry;
          job.autoResumeRetry = nextRetry;
          int actualStartByte = await _calculateResumeStartByte(
            job,
            taskId: taskId,
            filename: job.filename,
            batchId: batch.batchId,
          );
          if (actualStartByte == 0) {
            await _clearResumeState(job, taskId: taskId);
          }
          unawaited(
            DevLog.write(
              'V16DL',
              'auto_resume n=$nextRetry/5 from_bytes=$actualStartByte reason=$lastFailReason',
            ),
          );
          job.state = JobState.queued;
          job.error = '自动重试 $nextRetry/5';
          await _persist(batch);
          notifyListeners();
          await _enqueueAttempt(batch, job, source: 'auto_resume');
        });
      } else {
        // 2c. 5 retries exhausted: enter "已中断，点继续" (keeps JobState.paused)
        job.error = '已中断，点继续';
        await _persist(batch);
        notifyListeners();
        unawaited(_refreshNotification(batch));
      }
      return;
    } else if (isResumable) {
      await _clearResumeState(job, taskId: taskId);
    }

    // No connection means the transfer never had a chance: park the file until
    // the network is back instead of spending its attempts on a dead link
    // (v1.11 batch 3). The native queue is left alone on purpose — it already
    // waits by itself — this only makes the wait visible and refundable.
    final shouldWaitNetwork =
        isNetworkCause(cause) &&
        (!NetworkStatus.instance.online ||
            (isResumable &&
                (job.progress > 0 ||
                    (job.resumeStartByte != null &&
                        job.resumeStartByte! > 0))));
    if (shouldWaitNetwork) {
      if (job.attempts > 0) job.attempts--;
      unawaited(
        DevLog.write(
          'V16DL', // i18n:ignore 日志
          'item waiting_network index=${job.itemIndex} role=${roleOf(job)} '
              'cause=$cause attempts=${job.attempts}/$cap '
              'candidate=${candidateProgressLabel(job)}',
        ),
      );
      await _waitForNetwork(batch, job, cause: cause, refundAttempt: false);
      return;
    }
    // A dropped connection or a timeout is usually transient: the same
    // candidate is retried on an exponential ladder (0.6s, 1.2s, 2.4s) before
    // it is written off. Every other failure rotates to the next candidate at
    // once.
    final backoffRetry =
        (cause == 'reset' || cause == 'timeout') &&
        job.candidateRetryCount < kCandidateRetryLimit &&
        job.attempts < cap;
    final nextRetry = job.candidateRetryCount + 1;
    final backoff = candidateBackoffFor(nextRetry);
    unawaited(
      DevLog.write(
        'V16DL', // i18n:ignore 日志
        'candidate index=${job.itemIndex} role=${roleOf(job)} '
            'label=${candidateLabelOf(_candidateUrlOf(job) ?? '')} '
            'host_class=${_hostClassOf(batch, job)} bytes=- '
            'sniff=- result=transfer_failed reason=${_transferReason(update, userCancelRequested: job.userCancelRequested)} '
            'cause=$cause attempts=${job.attempts}/$cap '
            'candidate=${candidateProgressLabel(job)} '
            'format_pref=${batch.formatPref.logToken}'
            '${backoffRetry ? ' retry=backoff retry_index=$nextRetry/$kCandidateRetryLimit wait_ms=${backoff.inMilliseconds} candidate_seq=${candidateIndexOf(job) + 1}/${job.urls.length}' : ''}',
      ),
    );
    if (backoffRetry) {
      job.candidateRetryCount = nextRetry;
      await Future<void>.delayed(backoff);
      await _enqueueAttempt(batch, job, source: 'backoff_retry');
      return;
    }
    job.candidateRetryCount = 0;
    final nextCandidate = candidateIndexOf(job) + 1;
    // Never wrap around to a candidate that was already downloaded: the item
    // gives up (or imports its best small copy) instead of re-requesting it.
    if (nextCandidate < job.urls.length && job.attempts < cap) {
      job.candidateIndex = nextCandidate;
      await _enqueueAttempt(batch, job, source: 'next_candidate');
      return;
    }
    if (await _importBestSetAside(batch, job, reason: 'transfer_failed')) {
      return;
    }
    _log(
      'transfer gave up index=${job.itemIndex} role=${roleOf(job)} '
      'reason=${_transferReason(update, userCancelRequested: job.userCancelRequested)} '
      'cause=${_failureCause(update, userCancelRequested: job.userCancelRequested)} '
      'detail=${update.exception?.toString() ?? 'unknown'}',
    );
    await _cleanupJobTemp(batch, job);
    // A file that never got a connection is a network failure, never a content
    // verdict: the bytes were never seen (v1.11 batch 3). The per-item sentence
    // stays the readable one; the *classification* is what must not be CONTENT.
    final networkGaveUp = isNetworkCause(cause);
    await _failReadable(
      batch,
      job,
      error: update.responseStatusCode != null
          ? '${failureTextFor(job)}（HTTP ${update.responseStatusCode}）'
          : failureTextFor(job),
      code: networkGaveUp ? networkFailureCode : null,
    );
  }

  /// The transport-failure path for one candidate (production: a
  /// `TaskStatus.failed` update). Exposed so the quality ladder can be tested
  /// end to end: original candidates rotate first, preview candidates last,
  /// and the same candidate is never tried twice.
  @visibleForTesting
  @visibleForTesting
  void taskUpdateForTesting(TaskUpdate update) => _onUpdate(update);

  Future<void> taskFailureForTesting(
    DownloadBatch batch,
    DownloadJob job,
    TaskStatusUpdate update,
  ) => _failAttempt(batch, job, update);

  /// Log-safe class of the candidate host: the site's own media host
  /// (`site_media`), a declared CDN host (`cdn_media`) or anything else
  /// (`other`). The host name itself is never written.
  String _hostClassOf(DownloadBatch batch, DownloadJob job) {
    final raw = _candidateUrlOf(job);
    if (raw == null) return 'other';
    final host = Uri.tryParse(raw)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return 'other';
    final site = SiteRegistry.current.byId(batch.platform);
    if (site == null) return 'other';
    if (site.hasHost(host)) return 'site_media';
    final download = site.data['download'] as Map?;
    final mediaHosts =
        (download?['mediaHosts'] as List?)?.cast<Map>() ?? const <Map>[];
    return mediaHosts.any((rule) => matchesHost(host, rule))
        ? 'cdn_media'
        : 'other';
  }

  /// Short, log-safe transfer failure reason (no URL, no query).
  static String _transferReason(
    TaskStatusUpdate update, {
    bool userCancelRequested = false,
  }) {
    if (update.status == TaskStatus.canceled) {
      return userCancelRequested ? 'canceled' : 'interrupted';
    }
    final status = update.responseStatusCode;
    if (status != null) return 'http_$status';
    final description = update.exception?.description ?? '';
    if (description.contains('Timeout') || description.contains('超时')) {
      return 'timeout';
    }
    if (isStorageFullError(description) ||
        isStorageFullError(update.exception)) {
      return storageFullCode;
    }
    final type = update.exception?.runtimeType;
    return type == null ? 'unknown' : type.toString().toLowerCase();
  }

  /// Detail of a connection failure as a fixed token. The native description
  /// is never logged: on Android it embeds the host name and the request URL.
  static String _failureCause(
    TaskStatusUpdate update, {
    bool userCancelRequested = false,
  }) {
    if (update.status == TaskStatus.canceled) {
      return userCancelRequested ? 'canceled' : 'interrupted';
    }
    if (update.responseStatusCode != null) return 'http';
    final description = update.exception?.description ?? '';
    bool has(String pattern) =>
        RegExp(pattern, caseSensitive: false).hasMatch(description);
    if (has(
      r'unknownhost|unresolved|gaierror|nodename|failed host lookup|host lookup',
    )) {
      return 'dns';
    }
    if (has(r'ssl|certificate|handshake|certpath|\btls\b')) return 'tls';
    if (has(r'econnrefused|connection refused|connectexception')) {
      return 'refused';
    }
    if (has(r'timeout|timed out|超时')) return 'timeout';
    if (has(r'noroutetohost|enetunreach|ehostunreach|unreachable')) {
      return 'unreachable';
    }
    if (has(
      r'econnreset|connection reset|epipe|eof|broken pipe|connection closed',
    )) {
      return 'reset';
    }
    if (has(
      r'socketexception|connection abort|software caused connection abort',
    )) {
      return 'network';
    }
    // The plugin wraps a socket failure in its own connection exception; trust
    // the type even when the description carries no recognisable token.
    if (update.exception is TaskConnectionException) return 'network';
    return 'other';
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
          unawaited(
            DevLog.write(
              'HistoryDb',
              'event=write_recovered '
                  'stage=$stage post=${batch.postId} attempt=$attempt',
            ),
          );
        }
        return true;
      } catch (e) {
        final reason = isStorageFullError(e)
            ? storageFullCode
            : '${e.runtimeType}';
        unawaited(
          DevLog.write(
            'HistoryDb',
            'event=write_retry stage=$stage '
                'post=${batch.postId} attempt=$attempt reason=$reason',
          ),
        );
        if (attempt > delays.length) {
          unawaited(
            DevLog.write(
              'HistoryDb',
              'event=write_failed stage=$stage '
                  'post=${batch.postId} reason=$reason',
            ),
          );
          return false;
        }
        await Future<void>.delayed(delays[attempt - 1]);
      }
    }
  }

  final _historyRetries = <String, Timer>{};
  final _activeQueryTimeouts = <String, int>{};
  final _activeQueryRetries = <String, Timer>{};
  Duration activeQueryRetryDelay = const Duration(seconds: 30);

  @visibleForTesting
  Map<String, int> get activeQueryTimeoutsForTesting => _activeQueryTimeouts;

  @visibleForTesting
  Map<String, Timer> get activeQueryRetriesForTesting => _activeQueryRetries;

  /// Log line index per batch, taken when the batch started.
  final _batchLogStarts = <String, int>{};

  /// Batches that already wrote a failure snapshot.
  final _failureSnapshotsTaken = <String>{};

  void _scheduleHistoryRetry(DownloadBatch batch) {
    _historyRetries[batch.batchId]?.cancel();
    _historyRetries[batch.batchId] = Timer(historyRetryDelay, () {
      _historyRetries.remove(batch.batchId);
      unawaited(_afterTerminal(batch, recovered: false));
    });
  }

  void _scheduleActiveQueryRetry(
    DownloadBatch batch, {
    required bool recovered,
    String? reason,
  }) {
    _activeQueryRetries[batch.batchId]?.cancel();
    _activeQueryRetries[batch.batchId] = Timer(activeQueryRetryDelay, () {
      _activeQueryRetries.remove(batch.batchId);
      unawaited(_afterTerminal(batch, recovered: recovered, reason: reason));
    });
  }

  Future<int?> _queryActiveNativeCountForTaskIds(
    String batchId,
    List<String> taskIds,
  ) async {
    final sw = Stopwatch()..start();
    var activeCount = 0;
    try {
      for (final taskId in taskIds) {
        final record = recordForIdForTesting != null
            ? await recordForIdForTesting!(
                taskId,
              ).timeout(const Duration(seconds: 3))
            : allRecordsForTesting != null
            ? (await allRecordsForTesting!(
                batchId,
              )).where((r) => r.taskId == taskId).firstOrNull
            : await FileDownloader().database
                  .recordForId(taskId)
                  .timeout(const Duration(seconds: 3));
        if (record != null) {
          final s = record.status;
          if (s == TaskStatus.enqueued ||
              s == TaskStatus.running ||
              s == TaskStatus.paused ||
              s == TaskStatus.waitingToRetry) {
            activeCount++;
          }
        }
      }
      sw.stop();
      unawaited(
        DevLog.write(
          'V16DL',
          'active_query taskIds=${taskIds.length} ms=${sw.elapsedMilliseconds} result=$activeCount',
        ),
      );
      return activeCount;
    } on TimeoutException {
      sw.stop();
      unawaited(
        DevLog.write(
          'V16DL',
          'active_query taskIds=${taskIds.length} ms=${sw.elapsedMilliseconds} result=timeout',
        ),
      );
      unawaited(DevLog.write('V16DL', 'active_count_timeout id=$batchId'));
      return null;
    } catch (_) {
      sw.stop();
      unawaited(
        DevLog.write(
          'V16DL',
          'active_query taskIds=${taskIds.length} ms=${sw.elapsedMilliseconds} result=error',
        ),
      );
      unawaited(DevLog.write('V16DL', 'active_count_timeout id=$batchId'));
      return null;
    }
  }

  final Set<String> _settledBatchIds = <String>{};

  Future<void> _afterTerminal(
    DownloadBatch batch, {
    required bool recovered,
    String? reason,
    bool fromTransferPipeline = false,
    String transferTrigger = 'event',
  }) async {
    if (!batch.isTerminal) return;
    if (batch.usesNewTransferPipeline && !fromTransferPipeline) return;

    final unconfirmedJobs = batch.jobs
        .where(
          (j) =>
              !j.saved &&
              j.state != JobState.done &&
              j.state != JobState.canceled,
        )
        .toList();

    var settleReason = reason;

    if (!batch.usesNewTransferPipeline && unconfirmedJobs.isNotEmpty) {
      final taskIds = unconfirmedJobs
          .map((j) => j.currentTaskId ?? j.key)
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList();

      if (taskIds.isNotEmpty) {
        final activeNative = await _queryActiveNativeCountForTaskIds(
          batch.batchId,
          taskIds,
        );

        if (activeNative == null) {
          final timeouts = (_activeQueryTimeouts[batch.batchId] ?? 0) + 1;
          _activeQueryTimeouts[batch.batchId] = timeouts;
          if (timeouts < 3) {
            unawaited(
              DevLog.write(
                'V16DL',
                'batch_settle_blocked id=${batch.batchId} active_native=1',
              ),
            );
            _scheduleActiveQueryRetry(
              batch,
              recovered: recovered,
              reason: reason,
            );
            return;
          }
          _activeQueryTimeouts.remove(batch.batchId);
          _activeQueryRetries.remove(batch.batchId)?.cancel();
          settleReason = 'native_query_unavailable';
        } else if (activeNative > 0) {
          _activeQueryTimeouts.remove(batch.batchId);
          _activeQueryRetries.remove(batch.batchId)?.cancel();
          unawaited(
            DevLog.write(
              'V16DL',
              'batch_settle_blocked id=${batch.batchId} active_native=$activeNative',
            ),
          );
          return;
        } else {
          _activeQueryTimeouts.remove(batch.batchId);
          _activeQueryRetries.remove(batch.batchId)?.cancel();
        }
      }
    } else {
      _activeQueryTimeouts.remove(batch.batchId);
      _activeQueryRetries.remove(batch.batchId)?.cancel();
    }

    // Settled terminal batches already wrote history and released claims; do not
    // repeat work.
    if (batch.historyWritten &&
        (batch.usesNewTransferPipeline ||
            batch.source == DownloadManager.owner ||
            batch.settledBy != null)) {
      return;
    }
    if ((!batch.usesNewTransferPipeline && batch.settledBy != null) ||
        !_settledBatchIds.add(batch.batchId)) {
      return;
    }

    final filesCount = batch.jobs.where((j) => j.saved).length;
    final finalReason =
        settleReason ??
        (recovered
            ? 'reconcile_terminal'
            : (batch.succeeded > 0 ? 'all_completed' : 'all_failed'));
    unawaited(
      DevLog.write(
        'V16DL',
        'batch_settle id=${batch.batchId} by=${DownloadManager.owner} '
            'reason=$finalReason files=$filesCount active_native=0',
      ),
    );
    // v1.11 batch 1: a batch that ended with failures saves the log around it
    // to the app's private directory. This never affects the download itself.
    if (batch.failedCount > 0 && _failureSnapshotsTaken.add(batch.batchId)) {
      unawaited(
        DownloadFailureSnapshots.capture(
          batchId: batch.batchId,
          platform: batch.platform,
          postId: batch.postId,
          failed: batch.failedCount,
          total: batch.jobs.length,
          startLine: _batchLogStarts.remove(batch.batchId),
        ),
      );
    }
    await DownloadClaims.release(batch.batchId);
    unawaited(
      ResumableDownloadStore.instance.cleanForJobKeys(
        batch.jobs.map((j) => j.key),
      ),
    );
    if (batch.cancelledByDeletion ||
        await DownloadClaims.isCancelled(batch.batchId)) {
      return;
    }
    if (!batch.historyWritten) {
      if (batch.usesNewTransferPipeline) {
        final needsSnapshotSync = batch.jobs.any(
          (j) =>
              j.state == JobState.done &&
              ((j.mediaId == null || j.mediaId!.isEmpty) ||
                  (j.savedTitle == null || j.savedTitle!.isEmpty) ||
                  (j.relativePath == null || j.relativePath!.isEmpty) ||
                  (j.md5 == null || j.md5!.isEmpty) ||
                  ((j.fileBytes ?? 0) <= 0)),
        );
        if (needsSnapshotSync) {
          await _syncTransferBatchFromServiceSnapshot(batch);
        }
        final claimed = await _transferClient.claimHistoryWrite(batch.batchId);
        unawaited(
          DevLog.write(
            'V16DL',
            'transfer_settle batch=${batch.batchId} trigger=$transferTrigger '
                'engine=${DownloadManager.owner} claim=${claimed ? 'won' : 'lost'}',
          ),
        );
        if (!claimed) {
          _settledBatchIds.remove(batch.batchId);
          unawaited(_onClaimLostRefresh(batch));
          return;
        }
      }
      batch.historyWritten = true;
      final histSw = Stopwatch()..start();
      final written = await _writeHistoryWithRetry(
        batch,
        (db) =>
            (historyWriterForTesting ??
            (db, batch, recovered) => writeBatchHistory(
              db,
              batch,
              recovered: recovered,
            ))(db, batch, recovered),
        stage: 'terminal',
      );
      histSw.stop();
      final histMs = histSw.elapsedMilliseconds;
      if (!written) {
        // Keep the batch owing its history row; try again later.
        _settledBatchIds.remove(batch.batchId);
        batch.historyWritten = false;
        await _persist(batch);
        _scheduleHistoryRetry(batch);
        return;
      }
      if (batch.usesNewTransferPipeline) {
        final ackIds = batch.jobs
            .where((j) => j.transferJobId != null && j.state == JobState.done)
            .map((j) => j.transferJobId!)
            .toList();
        if (ackIds.isNotEmpty) {
          await _transferClient.ackHistoryWritten(ackIds);
        }
      }
      for (final j in batch.jobs.where((j) => j.saved)) {
        unawaited(
          DevLog.write(
            'V16DL',
            'finish_timing wait_complete_ms=${j.waitCompleteMs ?? 0} '
                'provenance_ms=${j.provenanceMs ?? 0} '
                'provenance_bytes_written=${j.provenanceBytesWritten ?? 0} '
                'import_copy_ms=${j.importCopyMs ?? 0} '
                'import_bytes=${j.importBytes ?? 0} '
                'thread=${j.importThread ?? 'bg'} '
                'history_ms=$histMs',
          ),
        );
      }
      // 1d: Never permanently delete user-initiated downloads! Keep the record
      // with status '已取消' or '下载失败' so user can retry or re-parse.
      // (discardEmptyPlaceholder is not called on terminal batches).
      final db = await HistoryDb.instance();
      final locator = GalleryLocatorService.instance;
      if (batch.usesNewTransferPipeline) {
        for (final j in batch.jobs) {
          final mid = j.mediaId;
          if (j.state == JobState.done && mid != null && mid.isNotEmpty) {
            unawaited(locator.getAssetByIdAsync(mid));
          }
        }
      }
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
    if (!batch.usesNewTransferPipeline) {
      batch.settledBy = DownloadManager.owner;
    }
    _log(
      'settle batch ${batch.batchId} '
      '(source=${batch.source} by=${batch.settledBy} recovered=$recovered)',
    );
    await _persist(batch);
    notifyListeners();
    unawaited(_refreshNotification(batch, forceCancel: recovered));
    await _forgetSupersededFailureBatches(batch);
  }

  /// A retry runs in a fresh flow, so an older batch of the same post can still
  /// sit in the snapshot index with its failed jobs. Those stale failures kept
  /// the failure strip on the history card and at the top of the preview page
  /// until the page was rebuilt. Once [batch] finished without a failure, drop
  /// them: dismiss the snapshot, so neither engine resurrects it, and let the
  /// listeners repaint. Nothing is removed while any job is unfinished, and a
  /// batch that still fails keeps its own failure.
  ///
  /// The stored snapshot and this engine's own copy are examined, not
  /// [liveBatches]: its merged view already clears a failure that a later save
  /// supersedes, which would hide exactly the batches looked for here.
  Future<void> _forgetSupersededFailureBatches(DownloadBatch batch) async {
    if (batch.failedCount > 0) return;
    final ids = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final id
          in prefs.getStringList(_batchIndexKey) ?? const <String>[]) {
        if (id == batch.batchId) continue;
        if (prefs.getBool('$_dismissedPrefix$id') == true) continue;
        final raw = prefs.getString(_batchKey(id));
        if (raw == null) continue;
        DownloadBatch stored;
        try {
          stored = DownloadBatch.fromJson(
            (jsonDecode(raw) as Map).cast<String, Object?>(),
          );
        } catch (_) {
          continue;
        }
        if (stored.postId != batch.postId) continue;
        if (!stored.isTerminal || stored.failedCount == 0) continue;
        ids.add(id);
      }
    } catch (_) {
      // Fall through to the in-memory copies.
    }
    for (final local in _batches.values) {
      if (local.batchId == batch.batchId) continue;
      if (local.postId != batch.postId) continue;
      if (!local.isTerminal || local.failedCount == 0) continue;
      ids.add(local.batchId);
    }
    if (ids.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final removed = <DownloadBatch>[];
    for (final id in ids) {
      await prefs.setBool('$_dismissedPrefix$id', true);
      final local = _batches.remove(id);
      _lastShownPercent.remove(id);
      _lastShownWaiting.remove(id);
      await _removeSnapshot(id);
      if (local != null) removed.add(local);
      _log(
        'drop superseded failure batch $id '
        '(post=${batch.postId} retried by ${batch.batchId})',
      );
    }
    if (removed.isNotEmpty) {
      await cancelNotifications(removed);
    }
    notifyListeners();
  }

  /// Manual per-row retry: re-parse the post first so 403/expired CDN links
  /// are refreshed; fall back to the stored URLs when parsing fails.
  Future<void> retryJob(DownloadBatch batch, DownloadJob job) async {
    if (batch.usesNewTransferPipeline) {
      final needsReenqueue =
          job.error == '启动失败，点重试' || job.transferState == 'interrupted';
      final syncedIds = await _syncTransferBatchSnapshotIds(batch);
      if (job.state == JobState.done || job.saved) {
        if (syncedIds.isNotEmpty) {
          await _persist(batch);
          notifyListeners();
        }
        if (batch.isTerminal && !batch.historyWritten) {
          await _afterTerminal(
            batch,
            recovered: true,
            fromTransferPipeline: true,
            transferTrigger: 'snapshot',
          );
        }
        return;
      }
      if (job.state != JobState.failed && job.state != JobState.canceled) {
        return;
      }
      job.state = JobState.queued;
      job.transferState = 'queued';
      job.error = null;
      job.errorCode = null;
      batch.historyWritten = false;
      batch.settledBy = null;
      final tId = job.transferJobId;
      if (tId != null && !needsReenqueue && (syncedIds.contains(tId) || syncedIds.isEmpty)) {
        await _persist(batch);
        notifyListeners();
        await _transferClient.retry(tId);
      } else {
        try {
          await _enqueueViaTransferService(batch, job);
        } catch (e) {
          job.state = JobState.failed;
          job.transferState = 'failed';
          job.error = '启动失败，点重试';
        }
        await _persist(batch);
        notifyListeners();
      }
      return;
    }
    await _finishing[job.key];
    // A timed-out import may still finish its album copy: its outcome decides.
    await _lateImports[job.key];
    if (await _isAlreadySaved(batch, job)) {
      job.saved = true;
      job.state = JobState.done;
      job.error = null;
      job.errorCode = null;
      unawaited(
        DevLog.write(
          'V16DL',
          'finish_skipped taskId=${job.currentTaskId ?? job.key} index=${job.itemIndex} reason=already_saved',
        ),
      );
      await _persist(batch);
      notifyListeners();
      await _afterTerminal(batch, recovered: false);
      return;
    }
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
        _log(
          'retry reused album copy index=${job.itemIndex} media=${existing.id}',
        );
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
      _log(
        'retry album lookup failed index=${job.itemIndex}: ${e.runtimeType}',
      );
    }
    job.errorCode = null;
    job.notOriginal = false;
    try {
      final outcome =
          await (reparseForTesting?.call(batch.postUrl) ??
              parsePostOutcome(
                batch.postUrl,
                source: 'download_retry',
                forceRefresh: true,
              ));
      final postIdx = job.itemIndex > 0 ? job.itemIndex - 1 : job.itemIndex;
      final planned =
          planFiles(
                outcome.data,
                [postIdx],
                (_, _, _) => job.filename,
                formatPref: (await AppSettings.load()).imageFormat,
              )
              .where(
                (file) =>
                    file.isImage == job.isImage &&
                    file.isLivePhoto == job.isLivePhoto,
              )
              .firstOrNull;
      if (planned != null && planned.urls.isNotEmpty) {
        final policy = _policyFor(batch.platform);
        final declarations = policy.resourcesFor(outcome.data.items[postIdx]);
        final freshResources = [
          for (final url in planned.urls)
            resourceForCandidate(policy, declarations, url),
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
    job.candidateIndex = 0;
    job.candidateRetryCount = 0;
    job.lastStatusCode = null;
    job.userCancelRequested = false;
    job.userPaused = false;
    _inFlightResumes.remove(job.key);
    try {
      await _enqueueAttempt(batch, job, source: 'manual_retry');
    } catch (_) {
      job.state = JobState.failed;
      job.error = '加入下载队列失败，请重试';
    }
    await _persist(batch);
    notifyListeners();
  }

  /// Retry every failed job in the batch (manual "重试" from the preview page).
  Future<void> retryBatch(DownloadBatch batch) async {
    if (batch.usesNewTransferPipeline) {
      final synced = await _syncTransferBatchFromServiceSnapshot(batch);
      if (synced) {
        await _persist(batch);
        notifyListeners();
      }
      if (batch.isTerminal && !batch.historyWritten) {
        await _afterTerminal(
          batch,
          recovered: true,
          fromTransferPipeline: true,
          transferTrigger: 'snapshot',
        );
      }
    }
    final failed = batch.jobs.where((j) => j.state == JobState.failed).toList();
    for (final job in failed) {
      await retryJob(batch, job);
    }
  }

  Future<void> cancelBatch(
    DownloadBatch batch, {
    String source = 'cancel_batch',
  }) async {
    if (batch.usesNewTransferPipeline) {
      for (final job in batch.jobs) {
        if (!job.isTerminal) {
          job.userCancelRequested = true;
          job.state = JobState.canceled;
          job.transferState = 'canceled';
          if (job.transferJobId != null) {
            await _transferClient.cancel(job.transferJobId!);
          }
        }
      }
      await _persist(batch);
      notifyListeners();
      await _afterTerminal(batch, recovered: false);
      return;
    }
    // 3a: Await any job currently in the finishing stage
    for (final job in batch.jobs) {
      if (job.isFinishing || _finishing.containsKey(job.key)) {
        await _finishing[job.key];
      }
    }
    // If every job is done or saved, the batch has completed; do not cancel it!
    if (batch.jobs.every((j) => j.state == JobState.done || j.saved)) {
      if (batch.isTerminal) await _afterTerminal(batch, recovered: false);
      return;
    }
    for (final job in batch.jobs) {
      if (!job.isTerminal) {
        job.userCancelRequested = true;
        _inFlightResumes.remove(job.key);
        _autoResumeTimers.remove(job.key)?.cancel();
        unawaited(
          DevLog.write(
            'V16DL',
            'temp_discard reason=user_canceled source=$source',
          ),
        );
      }
    }
    if (batch.source != owner &&
        batch.jobs.any((j) => needsSessionDownload(batch, j))) {
      for (final job in batch.jobs.where((j) => !j.isTerminal)) {
        await cancelJob(batch, job, source: source);
      }
      return;
    }
    for (final job in batch.jobs) {
      if (needsSessionDownload(batch, job) && !job.isTerminal) {
        _networkRetryTimers.remove(job.key)?.cancel();
        job.state = JobState.canceled;
        await _sessionTransfers[job.key]?.cancel();
        unawaited(_cleanupJobTemp(batch, job, reason: 'cancel'));
        unawaited(_removeResumeData(job.currentTaskId ?? job.key));
        await ResumableDownloadStore.instance.cleanForJob(job.key);
      }
    }
    final ids = [
      for (final job in batch.jobs)
        if (job.currentTaskId != null &&
            (job.state == JobState.queued || job.state == JobState.active))
          job.currentTaskId!,
    ];
    if (ids.isNotEmpty) {
      await _cancelTasksWithIds(ids, source: source);
    }
    for (final job in batch.jobs) {
      if (job.state == JobState.queued ||
          job.state == JobState.active ||
          job.state == JobState.paused ||
          job.state == JobState.waitingNetwork) {
        _networkRetryTimers.remove(job.key)?.cancel();
        job.state = JobState.canceled;
        unawaited(_cleanupJobTemp(batch, job, reason: 'cancel'));
        unawaited(_removeResumeData(job.currentTaskId ?? job.key));
        await ResumableDownloadStore.instance.cleanForJob(job.key);
      }
    }
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch, recovered: false);
  }

  /// User-confirmed history deletion also cancels foreign engine work. Native
  /// controls stop pending starts; the database barrier rejects late writes.
  Future<void> cancelPostDownloads(
    String platform,
    String postId, {
    String source = 'history_delete',
  }) async {
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
        job.userCancelRequested = true;
        _inFlightResumes.remove(job.key);
        _autoResumeTimers.remove(job.key)?.cancel();
        unawaited(
          DevLog.write(
            'V16DL',
            'temp_discard reason=user_canceled source=$source',
          ),
        );
        job.state = JobState.canceled;
        if (job.currentTaskId != null) ids.add(job.currentTaskId!);
        final transfer = _sessionTransfers[job.key];
        if (transfer != null) await transfer.cancel();
        if (needsSessionDownload(batch, job)) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('session_cancel_${job.key}', true);
        }
        unawaited(_cleanupJobTemp(batch, job, reason: 'cancel'));
        unawaited(_removeResumeData(job.currentTaskId ?? job.key));
      }
      _batches[batch.batchId] = batch;
      await _persist(batch);
      await DownloadClaims.release(batch.batchId);
      await ResumableDownloadStore.instance.cleanForJobKeys(
        batch.jobs.map((j) => j.key),
      );
    }
    notifyListeners();
    if (ids.isNotEmpty) {
      await _cancelTasksWithIds(ids, source: source);
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

  /// Pause a batch: running files are paused (resumable files keep their partial
  /// data and resume from the break point) and the watchdog leaves them alone
  /// until [resumeBatch].
  Future<void> pauseBatch(DownloadBatch batch) async {
    if (batch.usesNewTransferPipeline) {
      for (final job in batch.jobs) {
        if (job.state != JobState.queued && job.state != JobState.active) {
          continue;
        }
        job.state = JobState.paused;
        job.transferState = 'paused';
        job.userPaused = true;
        job.error = null;
        if (job.transferJobId != null) {
          await _transferClient.pause(job.transferJobId!);
        }
      }
      await _persist(batch);
      notifyListeners();
      return;
    }
    batch = await _ownedOrAdopt(batch);
    for (final job in batch.jobs) {
      if (job.state != JobState.queued && job.state != JobState.active) {
        continue;
      }
      final id = job.currentTaskId;
      job.state = JobState.paused;
      job.userPaused = true;
      job.error = null;
      _inFlightResumes.remove(job.key);
      _autoResumeTimers.remove(job.key)?.cancel();
      // Preserve job.progress, do not reset to 0
      if (needsSessionDownload(batch, job)) {
        await _sessionTransfers[job.key]?.cancel();
      } else if (id != null) {
        try {
          final task = await _taskForId(id);
          if (task is DownloadTask && task.allowPause) {
            final ok = await _pauseTask(task, source: 'pause_batch');
            _log('pauseTask taskId=$id success=$ok');
            if (ok) {
              try {
                final resumeData = await _getResumeData(id);
                if (resumeData != null) {
                  job.resumeStartByte = resumeData.requiredStartByte;
                  job.resumeTempPath = resumeData.data;
                  job.resumeEtag = resumeData.eTag;
                }
              } catch (_) {}
              if (pauseForTesting != null) {
                final rd = await _getResumeData(id);
                final p = rd?.data ?? job.resumeTempPath;
                final f = p != null && p.isNotEmpty ? File(p) : null;
                final exists = f?.existsSync() ?? false;
                final size = exists ? f!.lengthSync() : 0;
                final present = rd != null || job.resumeTempPath != null
                    ? 'yes'
                    : 'no';
                final reqStart =
                    rd?.requiredStartByte ?? job.resumeStartByte ?? size;
                unawaited(
                  DevLog.write(
                    'V16DL',
                    'pause_resume_data taskId=$id present=$present required_start_byte=$reqStart temp_exists=$exists temp_size=$size',
                  ),
                );
              }
            }
          } else {
            await _cancelTaskWithId(id, source: 'pause_batch_fallback');
          }
        } catch (_) {}
      }
    }
    await _persist(batch);
    notifyListeners();
    unawaited(_refreshNotification(batch));
  }

  /// Re-enqueue / resume every paused file of a batch.
  Future<void> resumeBatch(DownloadBatch batch) async {
    if (batch.usesNewTransferPipeline) {
      final syncedIds = await _syncTransferBatchSnapshotIds(batch);
      for (final job in batch.jobs.where(
        (j) => j.state == JobState.paused || j.state == JobState.waitingNetwork,
      )) {
        final wasInterrupted = job.transferState == 'interrupted' ||
            job.error == '启动失败，点重试';
        job.userPaused = false;
        job.userCancelRequested = false;
        job.error = null;
        job.errorCode = null;
        job.state = JobState.queued;
        job.transferState = 'queued';
        final tId = job.transferJobId;
        if (tId != null && !wasInterrupted && (syncedIds.contains(tId) || syncedIds.isEmpty)) {
          await _transferClient.resume(tId);
        } else {
          final partBytes = tId == null ? 0 : await _transferPartBytes(tId);
          try {
            await _enqueueViaTransferService(
              batch,
              job,
              initialBytesRead: partBytes,
            );
          } catch (e) {
            job.state = JobState.failed;
            job.transferState = 'failed';
            job.error = '启动失败，点重试';
          }
        }
      }
      await _persist(batch);
      notifyListeners();
      if (batch.isTerminal && !batch.historyWritten) {
        await _afterTerminal(
          batch,
          recovered: true,
          fromTransferPipeline: true,
          transferTrigger: 'snapshot',
        );
      }
      return;
    }
    batch = await _ownedOrAdopt(batch);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final job in batch.jobs.where((j) => j.state == JobState.paused)) {
      final wasUserPaused = job.userPaused;
      job.userPaused = false;
      job.userCancelRequested = false;
      _inFlightResumes.remove(job.key);
      _autoResumeTimers.remove(job.key)?.cancel();
      _autoResumeRetries.remove(job.key);
      job.consecutiveFailCount = 0;
      job.lastFailReason = null;
      job.error = null;
      job.lastProgressAt = now;

      // A1: 用户暂停后点继续：只要该 job 有一个处于 paused 状态的插件任务，就直接对它调用插件 resume（同一个 taskId），不做 preflight 判断，也不开新一轮
      bool resumedSameTask = false;
      final id = job.currentTaskId;
      if (id != null && !needsSessionDownload(batch, job)) {
        try {
          var task = await _taskForId(id);
          final status = await _queryTaskStatus(id);
          final isPluginPaused =
              (status == TaskStatus.paused ||
              (wasUserPaused &&
                  status != TaskStatus.failed &&
                  status != TaskStatus.complete));
          if (task == null && isPluginPaused && !job.isImage) {
            task = DownloadTask(
              taskId: id,
              url: job.urls.first,
              filename: job.filename,
              directory: downloadTempDirectory(batch.batchId, job.key),
              baseDirectory: BaseDirectory.temporary,
              group: batch.batchId,
              updates: Updates.statusAndProgress,
              retries: 0,
              allowPause: true,
            );
          }
          if (task is DownloadTask && task.allowPause && isPluginPaused) {
            var rData = await _getResumeData(id);
            if (rData == null && id != job.key) {
              rData = await _getResumeData(job.key);
            }
            if (rData == null &&
                job.resumeTempPath != null &&
                job.resumeTempPath!.isNotEmpty) {
              rData = ResumeData(
                task,
                job.resumeTempPath!,
                job.resumeStartByte ?? 0,
                job.resumeEtag,
              );
              await _setResumeData(rData);
            }

            final startByte = await _calculateResumeStartByte(
              job,
              resumeData: rData,
              taskId: id,
              filename: job.filename,
              batchId: batch.batchId,
            );

            final path = rData?.data ?? job.resumeTempPath;
            if (path != null && path.isNotEmpty) {
              await _setResumeData(
                ResumeData(
                  task,
                  path,
                  startByte,
                  rData?.eTag ?? job.resumeEtag,
                ),
              );
            }

            final ok = await _resumeTask(task);
            if (ok) {
              resumedSameTask = true;
              job.state = JobState.active;
              _log('resumeTask taskId=$id success=true');
            }
          }
        } catch (e) {
          _log('resume same task failed $id: $e');
        }
      }

      if (!resumedSameTask) {
        job.state = JobState.queued;
        try {
          await _enqueueAttempt(batch, job, source: 'resume_batch');
        } catch (e) {
          _log('resume enqueue failed ${job.key}: $e');
          job.state = JobState.failed;
          job.error = '加入下载队列失败';
        }
      }
    }
    await _persist(batch);
    notifyListeners();
    if (batch.isTerminal) await _afterTerminal(batch, recovered: false);
  }

  /// Retry everything that is not finished: failed files (re-parsed for fresh
  /// links) and files that are stuck, queued or paused (plain re-enqueue).
  Future<void> restartBatch(DownloadBatch batch) async {
    if (batch.usesNewTransferPipeline) {
      await _syncTransferBatchFromServiceSnapshot(batch);
      for (final job in batch.jobs) {
        if (job.isTerminal) {
          if ((job.state == JobState.failed ||
                  job.state == JobState.canceled) &&
              job.transferJobId != null) {
            job.state = JobState.queued;
            job.transferState = 'queued';
            job.error = null;
            job.errorCode = null;
            batch.historyWritten = false;
            await _transferClient.retry(job.transferJobId!);
          }
          continue;
        }
        if ((job.state == JobState.paused ||
                job.state == JobState.waitingNetwork ||
                job.transferState == 'interrupted' ||
                job.transferState == 'storage_full') &&
            job.transferJobId != null) {
          job.userPaused = false;
          job.userCancelRequested = false;
          job.error = null;
          job.errorCode = null;
          job.state = JobState.queued;
          job.transferState = 'queued';
          await _transferClient.resume(job.transferJobId!);
        }
      }
      await _persist(batch);
      notifyListeners();
      if (batch.isTerminal && !batch.historyWritten) {
        await _afterTerminal(
          batch,
          recovered: true,
          fromTransferPipeline: true,
          transferTrigger: 'snapshot',
        );
      }
      return;
    }
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
          await cancelJob(batch, job, source: 'restart_batch');
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
        case JobState.waitingNetwork:
          final id = job.currentTaskId;
          if (id != null && job.state != JobState.paused) {
            await _cancelTaskWithId(id, source: 'restart_batch');
          }
          job.attempts = 0;
          job.progress = 0;
          job.lastProgressAt = now;
          try {
            await _enqueueAttempt(batch, job, source: 'restart_batch');
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
  Future<void> cancelJob(
    DownloadBatch batch,
    DownloadJob job, {
    String source = 'cancel_job',
  }) async {
    if (job.isFinishing || _finishing.containsKey(job.key)) {
      await _finishing[job.key];
    }
    if (batch.source != owner &&
        needsSessionDownload(batch, job) &&
        !batch.isStalledAt(DateTime.now().millisecondsSinceEpoch)) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('session_cancel_${job.key}', true);
      return;
    }
    batch = await _ownedOrAdopt(batch);
    job = batch.jobs.firstWhere((j) => j.key == job.key, orElse: () => job);
    if (job.saved || job.state == JobState.done) {
      return; // The album write won the race; keep it completed.
    }
    if (job.isTerminal) return;
    job.userCancelRequested = true;
    _inFlightResumes.remove(job.key);
    _autoResumeTimers.remove(job.key)?.cancel();
    unawaited(
      DevLog.write('V16DL', 'temp_discard reason=user_canceled source=$source'),
    );
    _networkRetryTimers.remove(job.key)?.cancel();
    if (needsSessionDownload(batch, job)) {
      job.state = JobState.canceled;
      await _sessionTransfers[job.key]?.cancel();
    }
    final id = job.currentTaskId;
    if (id != null) {
      await _cancelTaskWithId(id, source: source);
    }
    job.state = JobState.canceled;
    await _cleanupJobTemp(batch, job, reason: 'cancel');
    await _removeResumeData(job.currentTaskId ?? job.key);
    await ResumableDownloadStore.instance.cleanForJob(job.key);
    await _persist(batch);
    notifyListeners();
    await _afterTerminal(batch, recovered: false);
  }

  /// Cancel a batch and drop it from the queue, including its snapshot. An
  /// empty placeholder history record is removed by [_afterTerminal]; a post
  /// that already has saved files stays in the history.
  Future<void> removeBatch(
    DownloadBatch batch, {
    String source = 'remove_batch',
  }) async {
    final owned = batch.usesNewTransferPipeline
        ? (_batches[batch.batchId] ?? batch)
        : await _ownedOrAdopt(batch);
    if (!owned.isTerminal) await cancelBatch(owned, source: source);
    for (final job in owned.jobs) {
      job.userCancelRequested = true;
      _inFlightResumes.remove(job.key);
      _autoResumeTimers.remove(job.key)?.cancel();
      unawaited(
        DevLog.write(
          'V16DL',
          'temp_discard reason=user_canceled source=$source',
        ),
      );
      await _cleanupJobTemp(owned, job, reason: 'delete');
      await _removeResumeData(job.currentTaskId ?? job.key);
      await ResumableDownloadStore.instance.cleanForJob(job.key);
    }
    _batches.remove(owned.batchId);
    _lastShownPercent.remove(owned.batchId);
    await _removeSnapshot(owned.batchId);
    unawaited(_cancelNotification(owned));
    notifyListeners();
  }

  /// Cancel every unfinished batch, then drop them (restore-anyway path).
  Future<void> cancelAll({String source = 'cancel_all'}) async {
    for (final b in await liveBatches()) {
      if (b.isTerminal) continue;
      await removeBatch(b, source: source);
    }
  }

  /// Take over a batch whose owner engine is gone or stuck, so this engine's
  /// task updates, watchdog and cancel logic apply to it.
  Future<DownloadBatch> forceAdopt(DownloadBatch batch) async {
    if (batch.usesNewTransferPipeline) {
      _batches[batch.batchId] ??= batch;
      return _batches[batch.batchId]!;
    }
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
    await _setBatchOwner(
      batch.batchId,
      DownloadManager.owner,
      reason: 'force_adopt',
    );
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
    if (batch.usesNewTransferPipeline) {
      _batches[batch.batchId] ??= batch;
      return _batches[batch.batchId]!;
    }
    final known = _batches[batch.batchId];
    if (known != null && known.source == DownloadManager.owner) return known;
    if (batch.source == DownloadManager.owner) {
      _batches[batch.batchId] = batch;
      return batch;
    }
    return forceAdopt(batch);
  }

  Future<DownloadBatch?> reloadBatchSnapshot(String batchId) async {
    try {
      final existing = _batches[batchId];
      // If this batch is owned by this engine and is actively running, do not
      // overwrite live memory with a potentially stale disk snapshot.
      if (existing != null &&
          existing.source == DownloadManager.owner &&
          !existing.isTerminal) {
        return existing;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_batchKey(batchId));
      if (raw == null) return _batches[batchId];
      final updated = DownloadBatch.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
      if (existing != null &&
          existing.source == DownloadManager.owner &&
          !existing.isTerminal) {
        return existing;
      }
      _batches[batchId] = updated;
      return updated;
    } catch (_) {
      return _batches[batchId];
    }
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

  @visibleForTesting
  Future<bool> repairUnsettledSavedBatchesForTesting() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final index = prefs.getStringList(_batchIndexKey) ?? [];
    return _repairUnsettledSavedBatches(prefs, index);
  }

  Future<bool> _repairUnsettledSavedBatches(
    SharedPreferences prefs,
    List<String> index,
  ) async {
    var repaired = false;
    final batchesToCheck = <String, DownloadBatch>{};

    for (final batchId in index) {
      if (prefs.getBool('$_dismissedPrefix$batchId') == true) continue;
      final raw = prefs.getString(_batchKey(batchId));
      if (raw == null) continue;
      try {
        final b = DownloadBatch.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
        );
        batchesToCheck[b.batchId] = b;
      } catch (_) {}
    }
    for (final b in _batches.values) {
      batchesToCheck.putIfAbsent(b.batchId, () => b);
    }

    for (final batch in batchesToCheck.values) {
      final allSaved =
          batch.jobs.isNotEmpty &&
          batch.jobs.every(
            (j) =>
                j.saved ||
                j.state == JobState.done ||
                (j.mediaId != null && j.mediaId!.isNotEmpty),
          );
      if (!allSaved) continue;

      final isSettled =
          batch.historyWritten &&
          (batch.source == DownloadManager.owner || batch.settledBy != null);
      bool needsRepair = !isSettled;
      if (isSettled) {
        // If already marked settled, only repair if HistoryDb actually has an empty placeholder (files=0)
        try {
          final db = await HistoryDb.instance();
          final record = await db.getByPostId(batch.postId);
          if (record != null &&
              (record.files.isEmpty || record.fileCount == 0)) {
            needsRepair = true;
          }
        } catch (_) {}
      }

      if (needsRepair) {
        for (final j in batch.jobs) {
          if (j.mediaId != null && j.mediaId!.isNotEmpty) {
            j.saved = true;
            j.state = JobState.done;
            j.error = null;
          }
        }
        final filesCount = batch.jobs.where((j) => j.saved).length;
        unawaited(
          DevLog.write(
            'V16DL',
            'settle_repair batch=${batch.batchId} files=$filesCount',
          ),
        );
        if (!batch.usesNewTransferPipeline) {
          batch.source = DownloadManager.owner;
        }
        batch.historyWritten = false;
        batch.settledBy = null;
        _batches[batch.batchId] = batch;
        await _afterTerminal(batch, recovered: true, reason: 'settle_repair');
        repaired = true;
      }
    }
    return repaired;
  }

  /// Kill-recovery: finish gallery imports for tasks that completed while
  /// the app was dead, then write pending history records. Called on
  /// startup and when returning to the foreground.
  Future<void> reconcile() async {
    if (!_ready) {
      await init();
    }
    if (_reconcileFuture != null) {
      await _reconcileFuture;
      _reconcileFuture = null;
      return;
    }
    await _loadAndReconcile();
  }

  @visibleForTesting
  Future<void> reconcileForTesting() async {
    await _migrateAllLegacyBatchesEarly();
    await _loadAndReconcile();
    await _cleanOrphanTransferParts();
  }

  Future<void> _loadAndReconcile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final index = prefs.getStringList(_batchIndexKey) ?? [];
      var changed = await _repairUnsettledSavedBatches(prefs, index);
      var adopted = 0;
      for (final batchId in index) {
        if (prefs.getBool('$_dismissedPrefix$batchId') == true) continue;
        final raw = prefs.getString(_batchKey(batchId));
        if (raw == null) continue;
        final batch = DownloadBatch.fromJson(
          (jsonDecode(raw) as Map).cast<String, Object?>(),
        );
        // Rule 6: transfer-pipeline batches have no engine ownership, adopt,
        // or foreign-skip logic. Every live engine loads and displays them;
        // single history write is guaranteed by claimHistoryWrite.
        if (batch.usesNewTransferPipeline) {
          final existing = _batches[batchId];
          if (existing == null || existing.isTerminal) {
            _batches[batchId] = batch;
          }
          continue;
        }
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
            _batches.putIfAbsent(batchId, () => batch);
            continue;
          }
          if (await _isStalledForeignBatch(batch)) {
            // The owner is gone (its engine was killed) and every task of the
            // batch already finished: adopt it so the album import and the
            // history record still happen exactly once.
            _log('adopt stalled foreign batch ${batch.batchId}');
            adopted++;
            await _setBatchOwner(
              batch.batchId,
              DownloadManager.owner,
              reason: 'adopt_stalled',
            );
            batch.source = DownloadManager.owner;
            _batches[batchId] = batch;
            if (await _reconcileBatch(batch)) changed = true;
          } else {
            _log('skip foreign batch ${batch.batchId} (${batch.source})');
          }
          continue;
        }
        // Foreground resume must not replace objects still owned by live Dart
        // transfers with older persisted copies.
        final existing = _batches[batchId];
        if (existing != null && !existing.isTerminal) {
          continue;
        }
        if (existing?.jobs.any((j) => _sessionTransfers.containsKey(j.key)) ??
            false) {
          continue;
        }
        _batches[batchId] = batch;
        if (batch.usesNewTransferPipeline) {
          continue;
        }
        if (batch.isTerminal && batch.historyWritten) {
          // Settled terminal batches already wrote history: skip re-reconciling.
          continue;
        }
        if (await _reconcileBatch(batch)) changed = true;
      }
      // One line per start makes two launches directly comparable in the log.
      _log('reconcile done batches=${index.length} adopted=$adopted');
      unawaited(_cleanupTransferOrphanLegacyTasks());
      unawaited(tempSweep());
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
      historyWritten: batch.historyWritten,
      isTerminal: batch.isTerminal,
      succeeded: batch.succeeded,
    );
  }

  Future<bool> _allTasksTerminal(DownloadBatch batch) async {
    if (batch.usesNewTransferPipeline) {
      return batch.jobs.every((j) => j.isTerminal);
    }
    if (batch.jobs.every(
      (j) => j.isTerminal || needsSessionDownload(batch, j),
    )) {
      return true;
    }
    try {
      final records = allRecordsForTesting != null
          ? await allRecordsForTesting!(batch.batchId)
          : await FileDownloader().database.allRecords(group: batch.batchId);
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

  @visibleForTesting
  Future<bool> reconcileBatchForTesting(DownloadBatch batch) =>
      _reconcileBatch(batch);

  @visibleForTesting
  Future<void> enqueueAttemptForTesting(
    DownloadBatch batch,
    DownloadJob job, {
    String source = 'testing',
  }) => _enqueueAttempt(batch, job, source: source);

  @visibleForTesting
  void onNetworkChangedForTesting() => _onNetworkChanged();

  /// Returns true when the batch snapshot changed.
  Future<bool> _reconcileBatch(DownloadBatch batch) async {
    if (batch.usesNewTransferPipeline) return false;
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
      tracked = allRecordsForTesting != null
          ? await allRecordsForTesting!(batch.batchId)
          : await FileDownloader().database.allRecords(group: batch.batchId);
    } catch (_) {
      return false;
    }
    final byId = {for (final r in tracked) r.taskId: r};
    for (final job in batch.jobs) {
      if (job.saved) continue;
      if (await _isAlreadySaved(batch, job)) {
        job.saved = true;
        job.state = JobState.done;
        job.error = null;
        unawaited(
          DevLog.write(
            'V16DL',
            'finish_skipped taskId=${job.currentTaskId ?? job.key} index=${job.itemIndex} reason=already_saved',
          ),
        );
        changed = true;
        continue;
      }
      final taskId = job.currentTaskId;
      if (taskId == null) continue;
      final record = byId[taskId];
      if (record == null) {
        // Task unknown to the tracker (e.g. never enqueued before the
        // kill): leave active jobs to resume via native updates, mark
        // stale queued jobs for a fresh attempt below.
        if (job.state == JobState.queued) {
          await _enqueueAttempt(batch, job, source: 'reconcile_queued');
          changed = true;
        }
        continue;
      }
      if (record.status == TaskStatus.complete) {
        await _finishFile(batch, job, record.task);
        changed = true;
      } else if (record.status == TaskStatus.running ||
          record.status == TaskStatus.enqueued ||
          record.status == TaskStatus.waitingToRetry) {
        job.state = JobState.active;
        changed = true;
      } else if (record.status == TaskStatus.paused) {
        job.state = JobState.paused;
        changed = true;
      } else if (record.status == TaskStatus.failed ||
          record.status == TaskStatus.notFound) {
        // A policy rejection is final (see [policyRejectedCode]): re-enqueueing
        // it produced the 220 repeated `REQUEST_HEADER_REJECTED` lines of build
        // 46 and pushed the attempt counter past the displayed limit. A
        // simulated failure is final for the same reason (v1.11 batch 3).
        if (!isFinalFailure(job) && job.attempts < retryCapFor(batch, job)) {
          await _enqueueAttempt(batch, job, source: 'reconcile_retry');
        } else {
          job.state = JobState.failed;
          job.error ??= job.isImage ? failureTextFor(job) : '下载到的文件不是视频，已跳过';
        }
        changed = true;
      }
    }
    if (batch.isTerminal) {
      if (!batch.historyWritten ||
          (batch.source != DownloadManager.owner && batch.settledBy == null)) {
        await _afterTerminal(batch, recovered: true);
        changed = true;
      }
    }
    return changed;
  }

  /// Jobs whose failure was already logged (key -> attempts when logged), so a
  /// snapshot write does not repeat the same "item failed" line every time.
  final _loggedFailures = <String, int>{};

  void _logFailedJobs(DownloadBatch batch) {
    for (final job in batch.jobs.where((j) => j.state == JobState.failed)) {
      if (_loggedFailures[job.key] == job.attempts) continue;
      _loggedFailures[job.key] = job.attempts;
      unawaited(
        DevLog.write('V16DL', failedJobLogLine(batch, job)),
      ); // i18n:ignore 日志
    }
  }

  final Map<String, int> _lastProgressPersistMs = {};
  final Map<String, double> _lastProgressPersistValue = {};

  void _throttlePersistProgress(DownloadBatch batch, double currentProgress) {
    if (!batch.usesNewTransferPipeline &&
        batch.source != DownloadManager.owner) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastMs = _lastProgressPersistMs[batch.batchId] ?? 0;
    final lastVal = _lastProgressPersistValue[batch.batchId] ?? -1.0;
    if ((now - lastMs >= 1000) || ((currentProgress - lastVal).abs() >= 0.01)) {
      _lastProgressPersistMs[batch.batchId] = now;
      _lastProgressPersistValue[batch.batchId] = currentProgress;
      unawaited(_persist(batch));
    }
  }

  @visibleForTesting
  void throttlePersistProgressForTesting(
    DownloadBatch batch,
    double progress,
  ) => _throttlePersistProgress(batch, progress);

  Future<void> _persist(DownloadBatch batch) async {
    _logFailedJobs(batch);
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

  // --- v1.13 P0-4a: TransferService (TransferClient) integration ---

  @visibleForTesting
  TransferClient? transferClientForTesting;

  @visibleForTesting
  bool? useNewTransferPipelineForTesting;

  TransferClient? _defaultTransferClient;
  StreamSubscription<TransferEvent>? _transferEventsSub;
  final Set<String> _reresolvingTransferJobs = <String>{};
  final Set<String> _enqueuingTransferJobs = <String>{};

  TransferClient get _transferClient =>
      transferClientForTesting ?? (_defaultTransferClient ??= TransferClient());

  @visibleForTesting
  void subscribeTransferEventsForTesting() => _subscribeTransferEvents();

  void _subscribeTransferEvents() {
    _transferEventsSub?.cancel();
    _transferEventsSub = _transferClient.events.listen((event) {
      unawaited(_handleTransferEvent(event));
    });
  }

  (DownloadBatch, DownloadJob)? _findTransferJob(String transferJobId) {
    for (final batch in _batches.values) {
      for (final job in batch.jobs) {
        if (job.transferJobId == transferJobId) {
          return (batch, job);
        }
      }
    }
    return null;
  }

  @visibleForTesting
  Future<Directory> Function()? transfersDirForTesting;

  @visibleForTesting
  Future<AppSettings> Function()? settingsLoaderForTesting;

  @visibleForTesting
  Future<void> Function(File src, File dst)? moveFileForTesting;

  @visibleForTesting
  DateTime Function()? clockForTesting;

  @visibleForTesting
  Future<int> cleanOrphanTransferPartsForTesting({DateTime? now}) =>
      _cleanOrphanTransferParts(now: now);

  Future<Directory> _transfersDir() async {
    final hook = transfersDirForTesting;
    if (hook != null) return hook();
    final supportDir = await getApplicationSupportDirectory();
    return Directory('${supportDir.path}/transfers');
  }

  Future<void> _moveFileToPart(File src, File dst) async {
    await dst.parent.create(recursive: true);
    final hook = moveFileForTesting;
    if (hook != null) {
      await hook(src, dst);
      return;
    }
    try {
      await src.rename(dst.path);
    } on FileSystemException {
      final expectedLen = await src.length();
      await src.copy(dst.path);
      final actualLen = await dst.length();
      if (actualLen != expectedLen) {
        try {
          await dst.delete();
        } catch (_) {}
        throw FileSystemException(
          'Copied size mismatch ($actualLen != $expectedLen)',
          dst.path,
        );
      }
      await src.delete();
    }
  }

  Future<bool> _isNewTransferPipelineEnabled() async {
    if (useNewTransferPipelineForTesting != null) {
      return useNewTransferPipelineForTesting!;
    }
    final settings =
        await (settingsLoaderForTesting?.call() ?? AppSettings.load());
    return settings.useNewTransferPipeline;
  }

  Future<void> _migrateAllLegacyBatchesEarly() async {
    try {
      if (!await _isNewTransferPipelineEnabled()) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final index = prefs.getStringList(_batchIndexKey) ?? const <String>[];
      for (final batchId in index) {
        if (prefs.getBool('$_dismissedPrefix$batchId') == true) continue;
        final raw = prefs.getString(_batchKey(batchId));
        if (raw == null) continue;
        DownloadBatch batch;
        try {
          batch = DownloadBatch.fromJson(
            (jsonDecode(raw) as Map).cast<String, Object?>(),
          );
        } catch (_) {
          continue;
        }
        if (batch.usesNewTransferPipeline) continue;
        if (batch.historyWritten ||
            batch.settledBy != null ||
            batch.cancelledByDeletion) {
          continue;
        }
        if (batch.jobs.every((j) => j.isTerminal)) continue;

        final claimed = await _transferClient.claimMigration(batch.batchId);
        if (!claimed) continue;

        await _migrateLegacyBatchIfNeeded(batch, prefs);
      }
    } catch (_) {
      // Best effort: never block startup.
    }
  }

  Future<bool> _migrateLegacyBatchIfNeeded(
    DownloadBatch batch,
    SharedPreferences prefs,
  ) async {
    if (!await _isNewTransferPipelineEnabled()) return false;
    if (batch.usesNewTransferPipeline) return false;
    if (batch.historyWritten ||
        batch.settledBy != null ||
        batch.cancelledByDeletion) {
      return false;
    }

    // Re-read from prefs to ensure another engine didn't already migrate it.
    await prefs.reload();
    final freshRaw = prefs.getString(_batchKey(batch.batchId));
    if (freshRaw != null) {
      try {
        final fresh = DownloadBatch.fromJson(
          (jsonDecode(freshRaw) as Map).cast<String, Object?>(),
        );
        if (fresh.usesNewTransferPipeline ||
            fresh.historyWritten ||
            fresh.settledBy != null ||
            fresh.cancelledByDeletion) {
          return false;
        }
      } catch (_) {}
    }

    final unfinished = batch.jobs.where((j) => !j.isTerminal).toList();
    if (unfinished.isEmpty) {
      // All jobs are already terminal (e.g. completed & saved to album); settle via legacy.
      return false;
    }

    // P0-5c: Read ResumeData & temp files FIRST, move to .part, enqueue, and
    // persist BEFORE cancelling legacy tasks (cancelling a paused task in
    // background_downloader deletes its ResumeData and temp file).
    final allBatchLegacyIds = <String>{};
    for (final job in unfinished) {
      if (job.currentTaskId != null && job.currentTaskId!.isNotEmpty) {
        allBatchLegacyIds.add(job.currentTaskId!);
      }
      allBatchLegacyIds.addAll(
        job.previousTaskIds.where((id) => id.isNotEmpty),
      );
      allBatchLegacyIds.add(job.key);
    }
    try {
      final records = allRecordsForTesting != null
          ? await allRecordsForTesting!(batch.batchId)
          : await FileDownloader().database.allRecords(group: batch.batchId);
      for (final r in records) {
        if (r.taskId.isNotEmpty) allBatchLegacyIds.add(r.taskId);
      }
    } catch (_) {}

    final transfersDir = await _transfersDir();
    var resumed = 0;
    var fromZero = 0;
    var bytesMoved = 0;
    var partBytesTotal = 0;
    var migratedJobs = 0;
    final legacyIdsToClean = <String>[...allBatchLegacyIds];
    final stagedMoves =
        <
          ({
            DownloadJob job,
            String transferJobId,
            int initialBytes,
            bool schedulerHasPairPartner,
          })
        >[];

    for (final job in unfinished) {
      final index = candidateIndexOf(job);
      final transferJobId = index == 0
          ? 'xfer_${job.key}'
          : 'xfer_${job.key}_c$index';
      final legacyIds = <String>{
        if (job.currentTaskId != null && job.currentTaskId!.isNotEmpty)
          job.currentTaskId!,
        ...job.previousTaskIds.where((id) => id.isNotEmpty),
        job.key,
      }.toList();

      // Locate temp file from plugin ResumeData BEFORE any cancel.
      String? tempPath;
      var expectedStartByte = 0;
      for (final id in legacyIds) {
        final rd = await _getResumeData(id);
        if (rd != null && rd.data.isNotEmpty) {
          tempPath = rd.data;
          expectedStartByte = rd.requiredStartByte;
          break;
        }
      }

      final partFile = File('${transfersDir.path}/$transferJobId.part');
      var initialBytes = 0;

      try {
        if (tempPath != null && tempPath.isNotEmpty) {
          final srcFile = File(tempPath);
          if (await srcFile.exists()) {
            final len = await srcFile.length();
            if (expectedStartByte > 0 && len < expectedStartByte) {
              await DevLog.write(
                'V16DL',
                'legacy_restart_before_migration expected=$expectedStartByte actual=$len',
              );
            }
            if (len > 0) {
              await _moveFileToPart(srcFile, partFile);
              final movedLen = await partFile.length();
              bytesMoved += movedLen;
              partBytesTotal += movedLen;
              initialBytes = movedLen;
              resumed++;
            } else {
              fromZero++;
            }
          } else if (await partFile.exists() && await partFile.length() > 0) {
            // Killed mid-migration after moving temp file to .part: reuse .part.
            initialBytes = await partFile.length();
            partBytesTotal += initialBytes;
            resumed++;
          } else {
            fromZero++;
          }
        } else if (await partFile.exists() && await partFile.length() > 0) {
          initialBytes = await partFile.length();
          partBytesTotal += initialBytes;
          resumed++;
        } else {
          fromZero++;
        }
      } catch (e) {
        // Move failed -> keep legacy pipeline, do not drop tasks.
        await DevLog.write(
          'V16DL',
          'legacy_migrated batch=${batch.batchId} jobs=0 resumed=0 '
              'from_zero=0 kept_legacy=${unfinished.length} bytes_moved=0 part_bytes=0',
        );
        return false;
      }

      final hasCompletedPartner =
          job.isLivePhoto &&
          batch.jobs.any(
            (p) =>
                p.key != job.key &&
                p.itemIndex == job.itemIndex &&
                p.state == JobState.done &&
                p.saved,
          );

      stagedMoves.add((
        job: job,
        transferJobId: transferJobId,
        initialBytes: initialBytes,
        schedulerHasPairPartner: !hasCompletedPartner,
      ));
    }

    // Enqueue all staged jobs to TransferService.
    try {
      for (final item in stagedMoves) {
        item.job.resumeTempPath = null;
        await _enqueueViaTransferService(
          batch,
          item.job,
          schedulerHasPairPartner: item.schedulerHasPairPartner,
          initialBytesRead: item.initialBytes,
        );
        migratedJobs++;
      }
    } catch (e) {
      await DevLog.write(
        'V16DL',
        'legacy_migrated batch=${batch.batchId} jobs=0 resumed=0 '
            'from_zero=0 kept_legacy=${unfinished.length} bytes_moved=$bytesMoved part_bytes=$partBytesTotal',
      );
      return false;
    }

    batch.pipeline = DownloadBatch.pipelineTransfer;
    for (final j in batch.jobs) {
      j.usesNewTransferPipeline = true;
    }
    _batches[batch.batchId] = batch;
    await _persist(batch);

    // Cancel legacy plugin tasks LAST (after .part move, enqueue, and persist).
    if (allBatchLegacyIds.isNotEmpty) {
      await _cancelTasksWithIds(
        allBatchLegacyIds.toList(),
        batch: batch,
        source: 'legacy_migration',
      );
    }
    for (final id in legacyIdsToClean) {
      await _removeResumeData(id);
    }
    if (legacyIdsToClean.isNotEmpty) {
      final delHook = deleteLegacyRecordsForTesting;
      if (delHook != null) {
        try {
          await delHook(legacyIdsToClean);
        } catch (_) {}
      } else {
        try {
          await FileDownloader().database.deleteRecordsWithIds(
            legacyIdsToClean,
          );
        } catch (_) {}
      }
    }

    await DevLog.write(
      'V16DL',
      'legacy_migrated batch=${batch.batchId} jobs=$migratedJobs '
          'resumed=$resumed from_zero=$fromZero kept_legacy=0 '
          'bytes_moved=$bytesMoved part_bytes=$partBytesTotal',
    );
    return true;
  }

  Future<void> _enqueueViaTransferService(
    DownloadBatch batch,
    DownloadJob job, {
    bool? schedulerHasPairPartner,
    int initialBytesRead = 0,
  }) async {
    final addedByMe = _enqueuingTransferJobs.add(job.key);
    try {
      await _enqueueViaTransferServiceImpl(
        batch,
        job,
        schedulerHasPairPartner: schedulerHasPairPartner,
        initialBytesRead: initialBytesRead,
      );
    } finally {
      if (addedByMe) {
        _enqueuingTransferJobs.remove(job.key);
      }
    }
  }

  Future<void> _enqueueViaTransferServiceImpl(
    DownloadBatch batch,
    DownloadJob job, {
    bool? schedulerHasPairPartner,
    int initialBytesRead = 0,
  }) async {
    _subscribeTransferEvents();

    // 本机已有相同文件的「关联」逻辑（save plan 里的 associate）照旧在 Dart 侧判断，关联的文件不入队。
    try {
      final existing = await _findExistingAlbumAsset(batch, job);
      if (existing != null) {
        final read = await _albumProvenance(existing);
        final expected = provenanceForBatchItem(
          batch,
          itemIndex: job.itemIndex,
        );
        if (sameSavedOrigin(read, expected) ||
            (read == null && job.provenanceSkipped)) {
          final albumSize = await (mediaSizeForTesting ?? _mediaSize)(
            existing.id,
            !job.isImage,
          );
          final sizeOk =
              albumSize != null &&
              albumSize > 0 &&
              (job.fileBytes == null ||
                  job.fileBytes! <= 0 ||
                  albumSize == job.fileBytes);
          if (!sizeOk) {
            _log(
              'new pipeline associate rejected size mismatch: '
              'album=${albumSize ?? -1} expected=${job.fileBytes ?? -1}',
            );
          } else {
            _log(
              'new pipeline associated existing album file: ${existing.title ?? job.filename}',
            );
            job
              ..mediaId = existing.id
              ..savedTitle = existing.title
              ..relativePath = existing.relativePath
              ..assetId = read?.assetId
              ..provenanceItemCount = read?.itemCount
              ..provenanceCapturedBy = read?.capturedBy
              ..state = JobState.done
              ..transferState = 'done'
              ..progress = 1.0
              ..saved = true;
            await _persist(batch);
            notifyListeners();
            return;
          }
        }
      }
    } catch (_) {
      // Best-effort associate check; proceed to enqueue if lookup fails.
    }

    if (job.urls.isEmpty) {
      job.state = JobState.failed;
      job.transferState = 'failed';
      job.error = '无可用下载地址';
      return;
    }

    final index = candidateIndexOf(job);
    final candidateUrl = job.urls[index];
    final policy = _policyFor(batch.platform);
    final resource = _jobResource(job, index, policy);
    final authorized = await policy.authorize(resource);

    final candidateLabel = candidateLabelOf(candidateUrl);
    final category = job.isImage ? 'image' : 'large_file';
    final String mime;
    if (!job.isImage) {
      mime = candidateUrl.toLowerCase().contains('.mov')
          ? 'video/quicktime'
          : 'video/mp4';
    } else {
      final token = candidateLabel.contains(':')
          ? candidateLabel.split(':').last
          : '';
      mime = switch (token) {
        'jpg' => 'image/jpeg',
        'png' => 'image/png',
        'webp' => 'image/webp',
        'heic' => 'image/heic',
        'avif' => 'image/avif',
        'gif' => 'image/gif',
        _ => 'image/jpeg',
      };
    }

    final site = SiteRegistry.current.byId(batch.platform);
    final downloadConfig = (site?.data['download'] as Map?) ?? {};
    final mediaHosts = ((downloadConfig['mediaHosts'] as List?) ?? [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final cookieDomains = ((downloadConfig['cookieDomains'] as List?) ?? [])
        .whereType<String>()
        .toList();

    final provenancePairId = job.isLivePhoto
        ? '${batch.postId}#${job.itemIndex}'
        : null;
    final schedulerPairId = (schedulerHasPairPartner ?? true)
        ? provenancePairId
        : null;
    final provenance = provenanceForBatchItem(
      batch,
      itemIndex: job.itemIndex,
      pairId: provenancePairId,
    );
    job.assetId = provenance.assetId;
    job.provenanceItemCount = provenance.itemCount;
    job.provenanceCapturedBy = provenance.capturedBy;

    final transferJobId = index == 0
        ? 'xfer_${job.key}'
        : 'xfer_${job.key}_c$index';
    job.transferJobId = transferJobId;
    job.transferState = 'queued';
    job.state = JobState.queued;
    job.bytesRead = initialBytesRead;
    if (initialBytesRead > 0 &&
        job.expectedBytes != null &&
        job.expectedBytes! > 0) {
      job.progress = (initialBytesRead / job.expectedBytes!).clamp(0.0, 1.0);
    } else {
      job.progress = 0.0;
    }
    job.error = null;
    job.errorCode = null;
    job.lastProgressAt = DateTime.now().millisecondsSinceEpoch;

    unawaited(
      DevLog.write(
        'V16DL',
        'candidate_seq=${index + 1}/${job.urls.length} role=${roleOf(job)} '
            'label=$candidateLabel format_pref=${batch.formatPref.logToken} '
            'transfer_job=$transferJobId pair_id=${provenancePairId ?? "-"}',
      ),
    );

    try {
      await _transferClient.enqueue(
        jobId: transferJobId,
        direction: 'download',
        category: category,
        batchId: batch.batchId,
        pairId: schedulerPairId,
        url: authorized.uri.toString(),
        headers: authorized.headers,
        cookie: authorized.cookie,
        allowedCookieDomains: cookieDomains,
        policyHosts: mediaHosts,
        mime: mime,
        policyKey: batch.platform,
        provenance: provenance.toJson(),
        batchTotalCount: batch.jobs.length,
      );
    } catch (e) {
      await DevLog.write(
        'V16DL',
        'transfer_enqueue_failed batch=${batch.batchId} job=$transferJobId reason=$e',
      );
      rethrow;
    }
  }

  Future<void> _reloadMissingBatchesFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final id
          in prefs.getStringList(_batchIndexKey) ?? const <String>[]) {
        if (_batches.containsKey(id)) continue;
        if (prefs.getBool('$_dismissedPrefix$id') == true) continue;
        final raw = prefs.getString(_batchKey(id));
        if (raw == null) continue;
        try {
          final loaded = DownloadBatch.fromJson(
            (jsonDecode(raw) as Map).cast<String, Object?>(),
          );
          _batches[id] = loaded;
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _handleTransferEvent(TransferEvent event) async {
    var found = _findTransferJob(event.jobId);
    if (found == null) {
      await _reloadMissingBatchesFromPrefs();
      found = _findTransferJob(event.jobId);
    }
    if (found == null) return;
    final (batch, job) = found;
    final now = DateTime.now().millisecondsSinceEpoch;

    if (event is TransferProgressEvent) {
      job.lastProgressAt = now;
      job.bytesRead = event.bytesRead;
      if (event.totalBytes > 0) {
        job.expectedBytes = event.totalBytes;
        job.progress = (event.bytesRead / event.totalBytes).clamp(0.0, 1.0);
      }
      notifyListeners();
      return;
    }

    if (event is TransferReresolveRequiredEvent) {
      await _reresolveTransferJob(batch, job);
      return;
    }

    if (event is TransferCompletedEvent) {
      job
        ..mediaId = event.mediaId
        ..savedTitle = event.title
        ..relativePath = event.relativePath
        ..md5 = event.md5
        ..fileBytes = event.fileSize > 0 ? event.fileSize : job.fileBytes
        ..saved = true
        ..isFinishing = false
        ..savingPhase = null
        ..state = JobState.done
        ..transferState = 'done'
        ..progress = 1.0
        ..error = null
        ..errorCode = null
        ..lastProgressAt = now;
      if (event.mediaId != null &&
          event.mediaId!.isNotEmpty &&
          GalleryLocatorService.instance.hasAccess) {
        unawaited(
          GalleryLocatorService.instance.getAssetByIdAsync(event.mediaId),
        );
      }
      await _persist(batch);
      notifyListeners();
      if (batch.isTerminal) {
        await _afterTerminal(
          batch,
          recovered: false,
          fromTransferPipeline: true,
        );
      }
      return;
    }

    if (event is TransferStateChangeEvent) {
      job.transferState = event.to;
      job.lastProgressAt = now;
      switch (event.to) {
        case 'queued':
          job.state = JobState.queued;
          job.userPaused = false;
          job.isFinishing = false;
        case 'running':
          job.state = JobState.active;
          job.userPaused = false;
          job.isFinishing = false;
          job.error = null;
          job.errorCode = null;
        case 'waiting_network':
          job.state = JobState.waitingNetwork;
          job.isFinishing = false;
        case 'storage_full':
          job.state = JobState.paused;
          job.userPaused = false;
          job.isFinishing = false;
          job.errorCode = storageFullCode;
          job.transferRequiredBytes = event.requiredBytes;
          job.transferAvailableBytes = event.availableBytes;
        case 'paused':
          job.state = JobState.paused;
          job.userPaused = true;
          job.isFinishing = false;
        case 'interrupted':
          job.state = JobState.paused;
          job.userPaused = false;
          job.isFinishing = false;
          job.error = '已中断，点继续';
        case 'finishing':
        case 'waiting_pair':
          job.state = JobState.active;
          job.isFinishing = true;
          job.savingPhase = event.to == 'waiting_pair' ? '等待配对' : '正在保存到相册';
        case 'canceled':
          job.state = JobState.canceled;
          job.isFinishing = false;
        case 'failed':
          // 候选回退：404 / sniff_mismatch 等不可重试错误时换下一个候选重新入队
          if (event.reason != 'pair_partner_failed' &&
              job.candidateIndex + 1 < job.urls.length) {
            job.candidateIndex++;
            job.isFinishing = false;
            job.progress = 0.0;
            try {
              await _enqueueViaTransferService(batch, job);
            } catch (e) {
              job.state = JobState.failed;
              job.transferState = 'failed';
              job.error = '启动失败，点重试';
            }
          } else {
            job.state = JobState.failed;
            job.isFinishing = false;
            job.error = event.reason ?? '下载失败';
          }
        case 'done':
          job.transferState = 'done';
          job.isFinishing = false;
          job.progress = 1.0;
      }
      await _persist(batch);
      notifyListeners();
      if (batch.isTerminal && job.saved) {
        await _afterTerminal(
          batch,
          recovered: false,
          fromTransferPipeline: true,
        );
      }
    }
  }

  Future<void> _reresolveTransferJob(
    DownloadBatch batch,
    DownloadJob job,
  ) async {
    final transferJobId = job.transferJobId;
    if (transferJobId == null) return;
    if (!_reresolvingTransferJobs.add(transferJobId)) return;
    try {
      final outcome =
          await (reparseForTesting?.call(batch.postUrl) ??
              parsePostOutcome(
                batch.postUrl,
                source: 'transfer_reresolve',
                forceRefresh: true,
              ));
      final postIdx = job.itemIndex > 0 ? job.itemIndex - 1 : job.itemIndex;
      if (postIdx < 0 || postIdx >= outcome.data.items.length) return;
      final item = outcome.data.items[postIdx];
      final freshUrls = planFilesForItem(
        outcome.data,
        postIdx,
        formatPref: batch.formatPref,
      );
      if (freshUrls == null || freshUrls.isEmpty) return;

      final String freshUrl;
      if (job.isLivePhoto && !job.isImage && freshUrls.length >= 2) {
        freshUrl = freshUrls[1];
      } else {
        freshUrl = freshUrls.first;
      }

      final policy = _policyFor(batch.platform);
      final declarations = policy.resourcesFor(item);
      final resource = resourceForCandidate(policy, declarations, freshUrl);
      final authorized = await policy.authorize(resource);

      final site = SiteRegistry.current.byId(batch.platform);
      final downloadConfig = (site?.data['download'] as Map?) ?? {};
      final mediaHosts = ((downloadConfig['mediaHosts'] as List?) ?? [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
      final cookieDomains = ((downloadConfig['cookieDomains'] as List?) ?? [])
          .whereType<String>()
          .toList();

      final updated = await _transferClient.updateUrlAndResume(
        jobId: transferJobId,
        url: authorized.uri.toString(),
        headers: authorized.headers,
        cookie: authorized.cookie,
        allowedCookieDomains: cookieDomains,
        policyHosts: mediaHosts,
        policyKey: batch.platform,
      );
      if (!updated) {
        throw StateError('updateUrlAndResume returned false');
      }
    } catch (e) {
      _log('reresolve failed for $transferJobId: $e');
      await DevLog.write(
        'V16DL',
        'transfer_enqueue_failed batch=${batch.batchId} job=$transferJobId reason=$e',
      );
      job.state = JobState.failed;
      job.transferState = 'failed';
      job.isFinishing = false;
      job.error = '启动失败，点重试';
      await _persist(batch);
      notifyListeners();
      if (batch.isTerminal) {
        await _afterTerminal(
          batch,
          recovered: false,
          fromTransferPipeline: true,
        );
      }
    } finally {
      _reresolvingTransferJobs.remove(transferJobId);
    }
  }

  void _applyTransferSnapshotToJob(DownloadJob job, TransferJobSnapshot snap) {
    job.transferState = snap.state;
    job.bytesRead = snap.bytesRead;
    if (snap.totalBytes > 0) {
      job.expectedBytes = snap.totalBytes;
      job.progress = (snap.bytesRead / snap.totalBytes).clamp(0.0, 1.0);
    }
    switch (snap.state) {
      case 'queued':
        job.state = JobState.queued;
      case 'running':
      case 'finishing':
      case 'waiting_pair':
        job.state = JobState.active;
        job.isFinishing =
            snap.state == 'finishing' || snap.state == 'waiting_pair';
      case 'waiting_network':
        job.state = JobState.waitingNetwork;
      case 'paused':
        job.state = JobState.paused;
        job.userPaused = true;
      case 'interrupted':
      case 'storage_full':
        job.state = JobState.paused;
        job.userPaused = false;
      case 'canceled':
        job.state = JobState.canceled;
      case 'failed':
        job.state = JobState.failed;
      case 'done':
        final effectiveMediaId = snap.mediaId ?? job.mediaId;
        if (effectiveMediaId == null || effectiveMediaId.trim().isEmpty) {
          job.state = JobState.paused;
          job.userPaused = false;
          job.transferState = 'interrupted';
          job.isFinishing = false;
          job.saved = false;
          job.error = '已中断，点继续';
          break;
        }
        job.state = JobState.done;
        job.saved = true;
        job.isFinishing = false;
        job.progress = 1.0;
        job.error = null;
        job.errorCode = null;
        job.mediaId = effectiveMediaId;
        job.savedTitle = snap.title ?? job.savedTitle;
        job.relativePath = snap.relativePath ?? job.relativePath;
        job.md5 = snap.md5 ?? job.md5;
        if (snap.fileSize > 0) job.fileBytes = snap.fileSize;
    }
  }

  Future<int> _transferPartBytes(String transferJobId) async {
    try {
      final dir = await _transfersDir();
      final part = File('${dir.path}/$transferJobId.part');
      if (!await part.exists()) return 0;
      return await part.length();
    } catch (_) {
      return 0;
    }
  }

  bool _allTransferDoneJobsHaveMediaId(DownloadBatch batch) {
    for (final job in batch.jobs) {
      if (job.state == JobState.done &&
          (!job.saved || job.mediaId == null || job.mediaId!.trim().isEmpty)) {
        return false;
      }
    }
    return true;
  }

  Future<Set<String>> _syncTransferBatchSnapshotIds(
    DownloadBatch batch,
  ) async {
    try {
      final snapshots = await _transferClient.snapshot();
      if (snapshots.isEmpty) return const <String>{};
      final byJobId = {for (final s in snapshots) s.jobId: s};
      final matched = <String>{};
      for (final job in batch.jobs) {
        final tId = job.transferJobId;
        if (tId == null) continue;
        final snap = byJobId[tId];
        if (snap == null) continue;
        _applyTransferSnapshotToJob(job, snap);
        matched.add(tId);
      }
      return matched;
    } catch (_) {
      return const <String>{};
    }
  }

  Future<bool> _syncTransferBatchFromServiceSnapshot(
    DownloadBatch batch,
  ) async {
    final matched = await _syncTransferBatchSnapshotIds(batch);
    return matched.isNotEmpty;
  }

  Future<void> syncTransferBatchesFromSnapshot() =>
      _syncTransferBatchesFromSnapshot();

  @visibleForTesting
  Future<void> syncTransferBatchesFromSnapshotForTesting() =>
      _syncTransferBatchesFromSnapshot();

  Future<void> _syncTransferBatchesFromSnapshot() async {
    try {
      final snapshots = await _transferClient.snapshot();
      final byJobId = {for (final s in snapshots) s.jobId: s};
      var changed = false;
      for (final batch in _batches.values.toList()) {
        if (!batch.usesNewTransferPipeline ||
            (batch.isTerminal && batch.historyWritten)) {
          continue;
        }
        var batchChanged = false;
        for (final job in batch.jobs) {
          if (job.state == JobState.canceled) continue;
          if (_enqueuingTransferJobs.contains(job.key)) continue;
          if (job.state == JobState.done &&
              job.saved &&
              (job.mediaId?.trim().isNotEmpty == true)) {
            continue;
          }
          final tId = job.transferJobId;
          // Batch just created (e.g. from the other engine) and job has not
          // yet received its service transferJobId: skip missing check.
          if (tId == null || tId.isEmpty) continue;
          final snap = byJobId[tId];
          if (snap != null) {
            _applyTransferSnapshotToJob(job, snap);
            batchChanged = true;
            changed = true;
            continue;
          }
          // 快照中找不到该任务：绝不可视为完成
          final partBytes = await _transferPartBytes(tId);
          if (partBytes > 0) {
            await DevLog.write(
              'V16DL',
              'transfer_snapshot_missing batch=${batch.batchId} job=$tId '
                  'part_bytes=$partBytes action=reenqueue',
            );
            try {
              await _enqueueViaTransferService(
                batch,
                job,
                initialBytesRead: partBytes,
              );
            } catch (_) {
              job.state = JobState.failed;
              job.transferState = 'failed';
              job.isFinishing = false;
              job.error = '启动失败，点重试';
            }
          } else {
            await DevLog.write(
              'V16DL',
              'transfer_snapshot_missing batch=${batch.batchId} job=$tId '
                  'part_bytes=0 action=interrupted',
            );
            job.state = JobState.paused;
            job.userPaused = false;
            job.transferState = 'interrupted';
            job.isFinishing = false;
            job.saved = false;
            job.error = '已中断，点继续';
          }
          batchChanged = true;
          changed = true;
        }
        if (batchChanged) {
          await _persist(batch);
        }
        if (batch.isTerminal &&
            !batch.historyWritten &&
            _allTransferDoneJobsHaveMediaId(batch)) {
          await _afterTerminal(
            batch,
            recovered: true,
            fromTransferPipeline: true,
            transferTrigger: 'snapshot',
          );
        }
      }
      if (changed) notifyListeners();
    } catch (_) {}
  }

  Future<int> _cleanOrphanTransferParts({DateTime? now}) async {
    try {
      final dir = await _transfersDir();
      if (!await dir.exists()) return 0;
      final snapshots = await _transferClient.snapshot();
      final activeJobIds = <String>{for (final s in snapshots) s.jobId};
      for (final batch in _batches.values) {
        if (batch.isTerminal) continue;
        for (final j in batch.jobs) {
          final tId = j.transferJobId;
          if (tId != null && tId.isNotEmpty) {
            activeJobIds.add(tId);
          }
        }
      }
      final refNow = now ?? (clockForTesting?.call() ?? DateTime.now());
      var count = 0;
      var bytes = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        String? baseId;
        if (name.endsWith('.part')) {
          baseId = name.substring(0, name.length - 5);
        } else if (name.endsWith('.meta')) {
          baseId = name.substring(0, name.length - 5);
        } else {
          continue;
        }
        if (activeJobIds.contains(baseId)) continue;
        final stat = await entity.stat();
        if (refNow.difference(stat.modified) <= const Duration(days: 7)) {
          continue;
        }
        try {
          await entity.delete();
          count++;
          bytes += stat.size;
        } catch (_) {}
      }
      if (count > 0) {
        await DevLog.write(
          'V16DL',
          'transfer_orphan_cleaned count=$count bytes=$bytes',
        );
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// 启动补写：查询服务中 history_pending=1 的已完成任务，写入历史库后回执清除标记（幂等）。
  Future<void> _onClaimLostRefresh(DownloadBatch batch) async {
    try {
      final db = await HistoryDb.instance();
      var record = await db.getByPostId(batch.postId, platform: batch.platform);
      if (record == null) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        record = await db.getByPostId(batch.postId, platform: batch.platform);
      }
      final locator = GalleryLocatorService.instance;
      if (locator.hasAccess) {
        for (final j in batch.jobs) {
          final mId = j.mediaId;
          if (mId != null && mId.isNotEmpty) {
            await locator.getAssetByIdAsync(mId);
          }
        }
        if (record != null) {
          await locator.preloadMediaIds([record]);
        }
      }
      HostBridge.historyRevision.value = HostBridge.historyRevision.value + 1;
    } catch (_) {}
  }

  Future<void> reconcileTransferHistoryPending({HistoryDb? db}) async {
    try {
      final pending = await _transferClient.queryHistoryPending();
      if (pending.isEmpty) return;
      final byBatch = <String, List<TransferJobSnapshot>>{};
      final ackIds = <String>[];

      for (final snap in pending) {
        final bId = snap.batchId;
        if (bId != null && bId.isNotEmpty) {
          byBatch.putIfAbsent(bId, () => <TransferJobSnapshot>[]).add(snap);
        } else {
          ackIds.add(snap.jobId);
        }
      }

      SharedPreferences? prefs;
      for (final entry in byBatch.entries) {
        var batch = _batches[entry.key];
        if (batch == null) {
          prefs ??= await SharedPreferences.getInstance();
          final raw = prefs.getString(_batchKey(entry.key));
          if (raw != null) {
            try {
              batch = DownloadBatch.fromJson(
                (jsonDecode(raw) as Map).cast<String, Object?>(),
              );
              _batches[entry.key] = batch;
            } catch (_) {}
          }
        }
        if (batch == null) {
          // 批次快照已不在本地，直接回执避免无限重试
          ackIds.addAll(entry.value.map((s) => s.jobId));
          continue;
        }
        for (final snap in entry.value) {
          final job = batch.jobs.cast<DownloadJob?>().firstWhere(
            (j) => j?.transferJobId == snap.jobId,
            orElse: () => null,
          );
          if (job != null) {
            _applyTransferSnapshotToJob(job, snap);
          }
        }
        if (batch.isTerminal && !batch.historyWritten) {
          await _afterTerminal(
            batch,
            recovered: true,
            fromTransferPipeline: true,
            transferTrigger: 'startup_pending',
          );
        } else if (batch.historyWritten) {
          ackIds.addAll(entry.value.map((s) => s.jobId));
        }
      }

      if (ackIds.isNotEmpty) {
        await _transferClient.ackHistoryWritten(ackIds);
      }
      await (db ?? await HistoryDb.instance()).repairIncompleteTransferRows();
      HostBridge.historyRevision.value = HostBridge.historyRevision.value + 1;
    } catch (e) {
      _log('reconcileTransferHistoryPending failed: $e');
    }
  }

  @visibleForTesting
  Future<void> Function(List<String> taskIds)? deleteLegacyRecordsForTesting;

  @visibleForTesting
  Future<({int tasks, int files, int bytes})>
  cleanupTransferOrphanLegacyTasksForTesting() =>
      _cleanupTransferOrphanLegacyTasks();

  @visibleForTesting
  Future<void> runWatchdogForTesting(DownloadBatch batch) => _watchdog(batch);

  @visibleForTesting
  void triggerNetworkRecoveryForTesting() => _triggerNetworkRecoveryResume();

  @visibleForTesting
  Future<void> resumeWaitingJobsForTesting() => _resumeWaitingJobs();

  @visibleForTesting
  Future<bool> resumeTaskForTesting(
    DownloadTask task, {
    DownloadBatch? batch,
    String source = 'testing',
  }) => _resumeTask(task, batch: batch, source: source);

  @visibleForTesting
  Future<bool> pauseTaskForTesting(
    DownloadTask task, {
    DownloadBatch? batch,
    String source = 'testing',
  }) => _pauseTask(task, batch: batch, source: source);

  @visibleForTesting
  Future<void> cancelTaskWithIdForTesting(
    String taskId, {
    DownloadBatch? batch,
    String source = 'testing',
  }) => _cancelTaskWithId(taskId, batch: batch, source: source);

  /// Cancels and deletes any legacy `background_downloader` tasks and temp
  /// files belonging to batches owned by the `transfer` pipeline.
  Future<({int tasks, int files, int bytes})>
  _cleanupTransferOrphanLegacyTasks() async {
    final transferBatches = _batches.values
        .where((b) => b.usesNewTransferPipeline)
        .toList();
    if (transferBatches.isEmpty) return (tasks: 0, files: 0, bytes: 0);

    var orphanTasks = 0;
    var deletedFiles = 0;
    var deletedBytes = 0;
    final idsToCancel = <String>[];

    for (final batch in transferBatches) {
      try {
        final records = allRecordsForTesting != null
            ? await allRecordsForTesting!(batch.batchId)
            : await FileDownloader().database.allRecords(group: batch.batchId);
        for (final r in records) {
          idsToCancel.add(r.taskId);
          orphanTasks++;
          try {
            final path = await r.task.filePath();
            final f = File(path);
            if (await f.exists()) {
              deletedBytes += await f.length();
              deletedFiles++;
              await f.delete();
            }
          } catch (_) {}
        }
      } catch (_) {}

      for (final job in batch.jobs) {
        final resumePath = job.resumeTempPath;
        if (resumePath != null && resumePath.isNotEmpty) {
          try {
            final f = File(resumePath);
            if (await f.exists()) {
              deletedBytes += await f.length();
              deletedFiles++;
              await f.delete();
            }
          } catch (_) {}
        }
      }

      try {
        final root =
            await (tempRootForTesting?.call() ?? getTemporaryDirectory());
        for (final dirName in {
          batch.batchId,
          Uri.encodeComponent(batch.batchId),
        }) {
          final dir = Directory('${root.path}/easysave/$dirName');
          if (await dir.exists()) {
            await for (final child in dir.list(recursive: true)) {
              if (child is File) {
                try {
                  deletedBytes += await child.length();
                  deletedFiles++;
                } catch (_) {}
              }
            }
            try {
              await dir.delete(recursive: true);
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    if (idsToCancel.isNotEmpty) {
      final cancelHook = cancelTaskForTesting;
      if (cancelHook != null) {
        for (final id in idsToCancel) {
          try {
            await cancelHook(id);
          } catch (_) {}
        }
      } else {
        try {
          await FileDownloader().cancelTasksWithIds(idsToCancel);
        } catch (_) {}
      }
      final delHook = deleteLegacyRecordsForTesting;
      if (delHook != null) {
        try {
          await delHook(idsToCancel);
        } catch (_) {}
      } else {
        try {
          await FileDownloader().database.deleteRecordsWithIds(idsToCancel);
        } catch (_) {}
      }
      for (final id in idsToCancel) {
        await _removeResumeData(id);
      }
    }

    if (orphanTasks > 0 || deletedFiles > 0 || deletedBytes > 0) {
      unawaited(
        DevLog.write(
          'V16DL',
          'legacy_orphan_cleaned count=${orphanTasks + deletedFiles} tasks=$orphanTasks files=$deletedFiles bytes=$deletedBytes',
        ),
      );
    }
    return (tasks: orphanTasks, files: deletedFiles, bytes: deletedBytes);
  }
}

/// Title of the single merged download notification.
///
/// [done] and [total] count items, not files (v1.11 build 58): a Live photo's
/// still and clip are one item, so the number the notification shows is the
/// same one the bubble, the panel and the completion note show.
///
/// Offline the batch keeps waiting and continues by itself, so the title says
/// that instead of "正在下载" (v1.11 batch 2). Display only.
String downloadNotificationTitle({
  DownloadBatch? batch,
  required int done,
  required int total,
  required bool waitingForNetwork,
}) {
  if (batch != null) {
    final status = resolveDownloadStatus(
      batch: batch,
      waitingForNetwork: waitingForNetwork,
    );
    if (status.isStorageFull) return '空间不足 $done/$total';
    if (status.isUserPaused) return '已暂停 $done/$total';
    if (status.isWaitingNetwork) return '等待网络 $done/$total';
    if (status.isFinishing) return '正在保存 $done/$total';
  }
  return waitingForNetwork ? '等待网络 $done/$total' : '正在下载 $done/$total';
}

/// Body of the single merged download notification (see
/// [downloadNotificationTitle]).
String downloadNotificationBody({
  DownloadBatch? batch,
  required int percent,
  required bool waitingForNetwork,
}) {
  if (batch != null) {
    final status = resolveDownloadStatus(
      batch: batch,
      waitingForNetwork: waitingForNetwork,
      progress: percent / 100.0,
    );
    if (status.isStorageFull) return status.label;
    if (status.isUserPaused) return '已暂停';
    if (status.isWaitingNetwork) return '等待网络…联网后自动继续';
    if (status.isFinishing) return status.label;
  }
  return waitingForNetwork ? '等待网络…联网后自动继续' : '$percent%';
}

/// One `item failed` log line: the fixed reason token, and the attempts of the
/// file over the budget it actually has ([retryCapFor]) — never the
/// per-candidate transfer limit, which made build 46 print `attempt=5/3`.
String failedJobLogLine(DownloadBatch batch, DownloadJob job) {
  final error = job.error ?? '';
  final reason = job.errorCode == storageFullCode
      ? storageFullCode
      : job.errorCode == simulatedFailureCode
      ? 'SIMULATED'
      : job.errorCode == networkFailureCode
      ? 'NETWORK'
      : job.errorCode == policyRejectedCode
      ? 'POLICY'
      : error.contains('403')
      ? 'HTTP_403'
      : error.contains('404')
      ? 'HTTP_404'
      : error.contains('超时') || error.contains('Timeout')
      ? 'TIMEOUT'
      : error.contains('REQUEST_')
      ? 'POLICY'
      : error.contains('不是图片') ||
            error.contains('不是视频') ||
            error.contains('wrong_content') ||
            error.contains('sniff_mismatch')
      ? 'CONTENT'
      : error.contains('保存') || error.contains('import')
      ? 'IMPORT'
      : error.contains('中断') || error.contains('interrupted')
      ? 'INTERRUPTED'
      : 'TRANSFER';
  return 'item failed index=${job.itemIndex} role=${DownloadManager.roleOf(job)} '
      'reason=$reason attempt=${job.attempts}/${retryCapFor(batch, job)}';
}

/// The completion note the 「图片格式」 setting asks for (v1.11 batch 3), or
/// null when there is nothing to say.
///
/// `已保存为原始格式，本机可能无法显示` — the original bytes were kept and the
/// container is one a phone may not display (HEIC / HEIF / AVIF / WebP). The
/// check reads the saved file name only: no decode, no blocking call.
///
/// `未取得 JPEG，已按兼容优先保存` — JPEG only was asked for and an item had no
/// jpeg candidate, so the compat ladder was used.
///
/// The original-format note wins when both would apply, because it describes a
/// file the user may not be able to open.
String? imageFormatCompletionNote(DownloadBatch batch) {
  if (batch.formatPref == ImageFormatPreference.compat) return null;
  final savedOriginal = batch.jobs.any(
    (job) =>
        job.isImage &&
        job.state == JobState.done &&
        job.saved &&
        kOriginalOnlyStillExtensions.contains(stillExtensionOf(job.savedTitle)),
  );
  if (batch.formatPref == ImageFormatPreference.original && savedOriginal) {
    return '已保存为原始格式，本机可能无法显示';
  }
  if (batch.formatPref == ImageFormatPreference.jpeg &&
      batch.jpegFallbackPlanned) {
    return '未取得 JPEG，已按兼容优先保存';
  }
  return null;
}

/// Fresh CDN URLs for a single item after re-parsing (manual retry path).
/// Returns null when the item no longer exists in the refreshed post.
List<String>? planFilesForItem(
  ParsedPost post,
  int itemIndex, {
  ImageFormatPreference formatPref = ImageFormatPreference.compat,
}) {
  if (itemIndex < 0 || itemIndex >= post.items.length) return null;
  final item = post.items[itemIndex];
  final imageUrls = stillCandidatesFor(
    orderedMediaUrls(post, item),
    formatPref: formatPref,
  );
  if (item.type == 'live' && item.videoUrl != null) {
    return [imageUrls.first, item.videoUrl!];
  }
  if (item.type == 'video') {
    final url = item.videoUrl ?? item.url;
    return item.videoUrl != null
        ? [url]
        : dedupeFinalCandidates(
            filterMediaCandidates([
              item.url,
              ...item.fallbacks,
            ], isImage: false),
          );
  }
  return imageUrls;
}
