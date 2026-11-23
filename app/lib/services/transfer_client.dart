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
    required this.category,
    required this.createdAt,
    required this.updatedAt,
    this.bytesRead = 0,
    this.totalBytes = 0,
    this.fakePlan,
  });

  factory TransferJobSnapshot.fromMap(Map<dynamic, dynamic> map) {
    return TransferJobSnapshot(
      jobId: (map['jobId'] as String?) ?? '',
      direction: (map['direction'] as String?) ?? 'download',
      state: (map['state'] as String?) ?? 'queued',
      retryCount: (map['retryCount'] as num?)?.toInt() ?? 0,
      batchId: map['batchId'] as String?,
      category: (map['category'] as String?) ?? 'image',
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
      updatedAt: (map['updatedAt'] as num?)?.toInt() ?? 0,
      bytesRead: (map['bytesRead'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      fakePlan: map['fakePlan'] as String?,
    );
  }

  final String jobId;
  final String direction;
  final String state;
  final int retryCount;
  final String? batchId;
  final String category;
  final int createdAt;
  final int updatedAt;
  final int bytesRead;
  final int totalBytes;
  final String? fakePlan;
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
  });

  final String from;
  final String to;
  final String? reason;
  final int retryCount;

  String get shortId => jobId.length <= 8 ? jobId : jobId.substring(0, 8);

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
      } else {
        return TransferStateChangeEvent(
          jobId: jobId,
          from: (map['from'] as String?) ?? '',
          to: (map['to'] as String?) ?? '',
          reason: map['reason'] as String?,
          retryCount: (map['retryCount'] as num?)?.toInt() ?? 0,
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
    String? fakePlan,
  }) async {
    final result = await _methodChannel.invokeMethod<String>('enqueue', {
      if (jobId != null) 'jobId': jobId,
      'direction': direction,
      'category': category,
      if (batchId != null) 'batchId': batchId,
      if (fakePlan != null) 'fakePlan': fakePlan,
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

  Future<bool> simulateNetwork(bool isAvailable) async {
    final res = await _methodChannel.invokeMethod<bool>('simulateNetwork', {'isAvailable': isAvailable});
    return res ?? false;
  }
}

