import 'dart:async';
import 'package:flutter/services.dart';

/// 传输任务状态快照
class TransferJobSnapshot {
  const TransferJobSnapshot({
    required this.jobId,
    required this.direction,
    required this.state,
    required this.retryCount,
    this.batchId,
    this.pairId,
    required this.category,
    required this.createdAt,
    required this.updatedAt,
    this.bytesRead = 0,
    this.totalBytes = 0,
    this.fakePlan,
    this.mediaId,
    this.title,
    this.relativePath,
    this.md5,
    this.fileSize = 0,
    this.provenanceStatus,
    this.historyPending = false,
    this.batchTotalCount = 0,
  });

  factory TransferJobSnapshot.fromMap(Map<dynamic, dynamic> map) {
    return TransferJobSnapshot(
      jobId: (map['jobId'] as String?) ?? '',
      direction: (map['direction'] as String?) ?? 'download',
      state: (map['state'] as String?) ?? 'queued',
      retryCount: (map['retryCount'] as num?)?.toInt() ?? 0,
      batchId: map['batchId'] as String?,
      pairId: map['pairId'] as String?,
      category: (map['category'] as String?) ?? 'image',
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
      bytesRead: (map['bytesRead'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      fakePlan: map['fakePlan'] as String?,
      mediaId: map['mediaId'] as String?,
      title: map['title'] as String?,
      relativePath: map['relativePath'] as String?,
      md5: map['md5'] as String?,
      fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
      provenanceStatus: map['provenanceStatus'] as String?,
      historyPending: (map['historyPending'] as bool?) ?? false,
      batchTotalCount: (map['batchTotalCount'] as num?)?.toInt() ?? 0,
    );
  }

  final String jobId;
  final String direction;
  final String state;
  final int retryCount;
  final String? batchId;
  final String? pairId;
  final String category;
  final int createdAt;
  final int updatedAt;
  final int bytesRead;
  final int totalBytes;
  final String? fakePlan;
  final String? mediaId;
  final String? title;
  final String? relativePath;
  final String? md5;
  final int fileSize;
  final String? provenanceStatus;
  final bool historyPending;
  final int batchTotalCount;
}

/// 传输事件基类
sealed class TransferEvent {
  const TransferEvent({required this.jobId});
  final String jobId;
}

/// 状态改变事件
class TransferStateChangeEvent extends TransferEvent {
  const TransferStateChangeEvent({
    required super.jobId,
    required this.from,
    required this.to,
    this.reason,
    required this.retryCount,
    this.requiredBytes = 0,
    this.availableBytes = 0,
  });

  final String from;
  final String to;
  final String? reason;
  final int retryCount;
  final int requiredBytes;
  final int availableBytes;

  String get shortId => jobId.length <= 8 ? jobId : jobId.substring(jobId.length - 8);

  String toLogString() {
    return '[XFER] job=$shortId state=$from->$to reason=${reason ?? "none"} retry=$retryCount';
  }
}

/// 传输进度事件
class TransferProgressEvent extends TransferEvent {
  const TransferProgressEvent({
    required super.jobId,
    required this.bytesRead,
    required this.totalBytes,
  });

  final int bytesRead;
  final int totalBytes;
}

/// 传输完成事件（带相册 mediaId、md5、文件名等）
class TransferCompletedEvent extends TransferEvent {
  const TransferCompletedEvent({
    required super.jobId,
    this.mediaId,
    this.md5,
    this.title,
    this.fileSize = 0,
    this.relativePath,
  });

  final String? mediaId;
  final String? md5;
  final String? title;
  final int fileSize;
  final String? relativePath;
}

/// 需要重新解析地址事件 (HTTP 403/410)
class TransferReresolveRequiredEvent extends TransferEvent {
  const TransferReresolveRequiredEvent({required super.jobId});
}

/// 传输客户端（薄封装）
class TransferClient {
  TransferClient({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel = methodChannel ?? const MethodChannel('easysave/transfer'),
        _eventChannel = eventChannel ?? const EventChannel('easysave/transfer/events');

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  Stream<TransferEvent>? _eventsStream;

  Stream<TransferEvent> get events {
    _eventsStream ??= _eventChannel.receiveBroadcastStream().map<TransferEvent>((dynamic raw) {
      final map = (raw as Map<dynamic, dynamic>?) ?? {};
      final type = map['type'] as String?;
      final jobId = (map['jobId'] as String?) ?? '';

      if (type == 'progress') {
        return TransferProgressEvent(
          jobId: jobId,
          bytesRead: (map['bytesRead'] as num?)?.toInt() ?? 0,
          totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
        );
      } else if (type == 'completed') {
        return TransferCompletedEvent(
          jobId: jobId,
          mediaId: map['mediaId'] as String?,
          md5: map['md5'] as String?,
          title: map['title'] as String?,
          fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
          relativePath: map['relativePath'] as String?,
        );
      } else if (type == 'reresolve_required') {
        return TransferReresolveRequiredEvent(jobId: jobId);
      } else {
        return TransferStateChangeEvent(
          jobId: jobId,
          from: (map['from'] as String?) ?? '',
          to: (map['to'] as String?) ?? '',
          reason: map['reason'] as String?,
          retryCount: (map['retryCount'] as num?)?.toInt() ?? 0,
          requiredBytes: (map['requiredBytes'] as num?)?.toInt() ?? 0,
          availableBytes: (map['availableBytes'] as num?)?.toInt() ?? 0,
        );
      }
    });
    return _eventsStream!;
  }

  Future<String> enqueue({
    String? jobId,
    String direction = 'download',
    String category = 'image',
    String? batchId,
    String? pairId,
    String? fakePlan,
    String? url,
    Map<String, String>? headers,
    String? cookie,
    List<String>? allowedCookieDomains,
    List<Map<String, dynamic>>? policyHosts,
    String? mime,
    String? policyKey,
    Map<String, dynamic>? provenance,
    int? batchTotalCount,
  }) async {
    final result = await _methodChannel.invokeMethod<String>('enqueue', {
      if (jobId != null) 'jobId': jobId,
      'direction': direction,
      'category': category,
      if (batchId != null) 'batchId': batchId,
      if (pairId != null) 'pairId': pairId,
      if (fakePlan != null) 'fakePlan': fakePlan,
      if (url != null) 'url': url,
      if (headers != null) 'headers': headers,
      if (cookie != null) 'cookie': cookie,
      if (allowedCookieDomains != null) 'allowedCookieDomains': allowedCookieDomains,
      if (policyHosts != null) 'policyHosts': policyHosts,
      if (mime != null) 'mime': mime,
      if (policyKey != null) 'policyKey': policyKey,
      if (provenance != null) 'provenance': provenance,
      if (batchTotalCount != null && batchTotalCount > 0)
        'batchTotalCount': batchTotalCount,
    });
    return result ?? jobId ?? '';
  }

  Future<bool> pause(String jobId) async {
    final res = await _methodChannel.invokeMethod<bool>('pause', {'jobId': jobId});
    return res ?? false;
  }

  Future<bool> resume(String jobId) async {
    final res = await _methodChannel.invokeMethod<bool>('resume', {'jobId': jobId});
    return res ?? false;
  }

  Future<bool> cancel(String jobId) async {
    final res = await _methodChannel.invokeMethod<bool>('cancel', {'jobId': jobId});
    return res ?? false;
  }

  Future<bool> retry(String jobId) async {
    final res = await _methodChannel.invokeMethod<bool>('retry', {'jobId': jobId});
    return res ?? false;
  }

  Future<List<TransferJobSnapshot>> snapshot() async {
    final res = await _methodChannel.invokeMethod<List<dynamic>>('snapshot');
    if (res == null) return const [];
    return res
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => TransferJobSnapshot.fromMap(m))
        .toList();
  }

  Future<Map<String, dynamic>> getJobFileInfo(String jobId) async {
    final res = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>('getJobFileInfo', {'jobId': jobId});
    return res?.cast<String, dynamic>() ?? {'exists': false};
  }

  Future<String> computeMediaSha256({String? jobId, String? mediaId}) async {
    final res = await _methodChannel.invokeMethod<String>('computeMediaSha256', {
      if (jobId != null) 'jobId': jobId,
      if (mediaId != null) 'mediaId': mediaId,
    });
    return res ?? '';
  }

  Future<bool> deleteJobFile(String jobId) async {
    final res = await _methodChannel.invokeMethod<bool>('deleteJobFile', {'jobId': jobId});
    return res ?? false;
  }

  Future<bool> simulateNetwork(bool isAvailable) async {
    final res = await _methodChannel.invokeMethod<bool>('simulateNetwork', {'isAvailable': isAvailable});
    return res ?? false;
  }

  Future<bool> clearSelfCheckJobs() async {
    final res = await _methodChannel.invokeMethod<bool>('clearSelfCheckJobs');
    return res ?? false;
  }

  Future<bool> openInGallery(String mediaId, {String? mime}) async {
    final res = await _methodChannel.invokeMethod<bool>('openInGallery', {
      'mediaId': mediaId,
      if (mime != null) 'mime': mime,
    });
    return res ?? false;
  }

  Future<bool> updateUrlAndResume({
    required String jobId,
    required String url,
    Map<String, String>? headers,
    String? cookie,
    List<String>? allowedCookieDomains,
    List<Map<String, dynamic>>? policyHosts,
    String? mime,
    String? policyKey,
  }) async {
    final res = await _methodChannel.invokeMethod<bool>('updateUrlAndResume', {
      'jobId': jobId,
      'url': url,
      if (headers != null) 'headers': headers,
      if (cookie != null) 'cookie': cookie,
      if (allowedCookieDomains != null) 'allowedCookieDomains': allowedCookieDomains,
      if (policyHosts != null) 'policyHosts': policyHosts,
      if (mime != null) 'mime': mime,
      if (policyKey != null) 'policyKey': policyKey,
    });
    return res ?? false;
  }

  Future<List<TransferJobSnapshot>> queryHistoryPending() async {
    final res = await _methodChannel.invokeMethod<List<dynamic>>('queryHistoryPending');
    if (res == null) return const [];
    return res
        .whereType<Map<dynamic, dynamic>>()
        .map((m) => TransferJobSnapshot.fromMap(m))
        .toList();
  }

  Future<bool> claimHistoryWrite(String batchId) async {
    try {
      final res = await _methodChannel.invokeMethod<bool>('claimHistoryWrite', {
        'batchId': batchId,
      });
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> ackHistoryWritten(List<String> jobIds) async {
    if (jobIds.isEmpty) return true;
    try {
      final res = await _methodChannel.invokeMethod<bool>('ackHistoryWritten', {
        'jobIds': jobIds,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }
}

