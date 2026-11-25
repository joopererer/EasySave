// Copyright 2026 EasySave. All rights reserved.
// Unified download status presentation across:
// 1. History Cards (HistoryPendingCard / DownloadingOverlay)
// 2. Download Queue (DownloadQueuePage)
// 3. Preview Download Sheet (DownloadSheet)
// 4. Floating Bubble (background_entry.dart)
// 5. System Notifications (downloadNotificationTitle / downloadNotificationBody)

import 'package:flutter/material.dart';

import 'download_manager.dart';
import 'network_status.dart';
import 'storage_guard.dart';

enum DownloadStatusKind {
  storageFull,
  userPaused,
  interrupted,
  waitingNetwork,
  finishing,
  failed,
  downloading,
  queued,
  stalled,
  done,
}

class DownloadStatusPresentation {
  const DownloadStatusPresentation({
    required this.kind,
    required this.label,
    required this.shortLabel,
    required this.icon,
    required this.actionTip,
    required this.actionIcon,
  });

  final DownloadStatusKind kind;
  final String label;
  final String shortLabel;
  final IconData icon;
  final String actionTip;
  final IconData actionIcon;

  bool get isStorageFull => kind == DownloadStatusKind.storageFull;
  bool get isUserPaused => kind == DownloadStatusKind.userPaused;
  bool get isInterrupted => kind == DownloadStatusKind.interrupted;
  bool get isWaitingNetwork => kind == DownloadStatusKind.waitingNetwork;
  bool get isFinishing => kind == DownloadStatusKind.finishing;
  bool get isFailed => kind == DownloadStatusKind.failed;
  bool get isDownloading => kind == DownloadStatusKind.downloading;
  bool get isDone => kind == DownloadStatusKind.done;
}

/// Unified function resolving display text, short labels, and icons for downloads.
///
/// Priority (strictly build 75):
/// 1. 空间不足 (Storage Full)
/// 2. 用户暂停 (User Paused)
/// 3. 下载中断 / 自动重试 / 等待网络 (Interrupted / Auto Retry / Network Wait)
/// 4. 收尾阶段 (Finishing Phase: 正在保存到相册)
/// 5. 失败 (Failed)
/// 6. 下载进度 (Downloading / In-flight)
DownloadStatusPresentation resolveDownloadStatus({
  DownloadBatch? batch,
  DownloadJob? job,
  double? progress,
  String? statusText,
  String? failureReason,
  bool? paused,
  bool? userPaused,
  bool? isFinishing,
  String? savingPhase,
  bool? waitingForNetwork,
  bool? stalled,
  bool? failed,
  bool? partial,
  int? doneCount,
  int? totalCount,
  String? transferState,
  int? requiredBytes,
  int? availableBytes,
  bool? totalKnown,
}) {
  final effectiveTransferState =
      transferState ?? job?.transferState ?? _batchTransferState(batch);
  final bool isNewPipeline = effectiveTransferState != null ||
      (batch?.usesNewTransferPipeline == true) ||
      (job?.usesNewTransferPipeline == true);

  if (isNewPipeline && effectiveTransferState != null) {
    final effectiveProgress = progress ?? job?.progress ?? batch?.progress ?? 0.0;
    final pct = (effectiveProgress.clamp(0.0, 1.0) * 100).round();
    final knownTotal = totalKnown ??
        ((job?.expectedBytes ?? 0) > 0 ||
            (batch?.jobs.any((j) => (j.expectedBytes ?? 0) > 0) ?? false));
    final reqBytes = requiredBytes ?? job?.transferRequiredBytes ?? 0;
    final availBytes = availableBytes ?? job?.transferAvailableBytes ?? 0;

    switch (effectiveTransferState) {
      case 'storage_full':
        final String label;
        if (reqBytes > 0) {
          final needGb = (reqBytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
          final availGb = (availBytes / (1024 * 1024 * 1024)).toStringAsFixed(1);
          label = '空间不足 · 需${needGb}GB，可用${availGb}GB';
        } else {
          label = '空间不足';
        }
        return DownloadStatusPresentation(
          kind: DownloadStatusKind.storageFull,
          label: label,
          shortLabel: '空间不足',
          icon: Icons.disc_full_outlined,
          actionTip: '清理后继续',
          actionIcon: Icons.refresh_rounded,
        );
      case 'waiting_network':
        return const DownloadStatusPresentation(
          kind: DownloadStatusKind.waitingNetwork,
          label: '等待网络',
          shortLabel: '等网络',
          icon: Icons.wifi_off_rounded,
          actionTip: '继续下载',
          actionIcon: Icons.play_arrow_rounded,
        );
      case 'interrupted':
        return const DownloadStatusPresentation(
          kind: DownloadStatusKind.interrupted,
          label: '已中断，点继续',
          shortLabel: '已中断',
          icon: Icons.refresh_rounded,
          actionTip: '继续下载',
          actionIcon: Icons.play_arrow_rounded,
        );
      case 'paused':
        return const DownloadStatusPresentation(
          kind: DownloadStatusKind.userPaused,
          label: '已暂停',
          shortLabel: '已暂停',
          icon: Icons.play_arrow_rounded,
          actionTip: '继续下载',
          actionIcon: Icons.play_arrow_rounded,
        );
      case 'finishing':
      case 'waiting_pair':
        return const DownloadStatusPresentation(
          kind: DownloadStatusKind.finishing,
          label: '正在保存到相册',
          shortLabel: '保存中',
          icon: Icons.save_alt_rounded,
          actionTip: '正在保存',
          actionIcon: Icons.hourglass_top_rounded,
        );
      case 'running':
        return DownloadStatusPresentation(
          kind: DownloadStatusKind.downloading,
          label: knownTotal ? '下载中 $pct%' : '下载中',
          shortLabel: knownTotal ? '$pct%' : '下载中',
          icon: Icons.pause_rounded,
          actionTip: '暂停下载',
          actionIcon: Icons.pause_rounded,
        );
      case 'queued':
        return const DownloadStatusPresentation(
          kind: DownloadStatusKind.queued,
          label: '排队中',
          shortLabel: '排队中',
          icon: Icons.hourglass_empty_rounded,
          actionTip: '等待中',
          actionIcon: Icons.hourglass_empty_rounded,
        );
      case 'done':
        return const DownloadStatusPresentation(
          kind: DownloadStatusKind.done,
          label: '全部完成 ✓',
          shortLabel: '已完成',
          icon: Icons.check_circle_rounded,
          actionTip: '已完成',
          actionIcon: Icons.check_circle_rounded,
        );
      case 'failed':
        final reason = failureReason ?? job?.error;
        final suffix = (reason != null && reason.isNotEmpty) ? '（$reason）' : '';
        return DownloadStatusPresentation(
          kind: DownloadStatusKind.failed,
          label: '下载失败$suffix',
          shortLabel: '失败',
          icon: Icons.error_outline_rounded,
          actionTip: '重试',
          actionIcon: Icons.refresh,
        );
    }
  }

  final currentStatusText = statusText ?? job?.error ?? batch?.statusText;

  // Determine storage full
  final bool storageFull = (failureReason?.contains('空间不足') == true) ||
      (failureReason?.contains('STORAGE_FULL') == true) ||
      (statusText?.contains('空间不足') == true) ||
      (job != null &&
          (job.errorCode == storageFullCode ||
              (job.error != null && job.error!.contains('空间不足')))) ||
      (batch != null &&
          (batch.statusText?.contains('空间不足') == true ||
              batch.jobs.any((j) =>
                  j.errorCode == storageFullCode ||
                  (j.error != null && j.error!.contains('空间不足')))));

  if (storageFull) {
    final text = currentStatusText ?? '空间不足';
    return DownloadStatusPresentation(
      kind: DownloadStatusKind.storageFull,
      label: text,
      shortLabel: '空间不足',
      icon: Icons.disc_full_outlined,
      actionTip: '清理后继续',
      actionIcon: Icons.refresh_rounded,
    );
  }

  // Determine user paused
  final effectiveProgress = progress ?? job?.progress ?? batch?.progress ?? 0.0;
  final pct = (effectiveProgress.clamp(0.0, 1.0) * 100).round();
  final bool isUserPause = userPaused == true ||
      (job != null && job.userPaused) ||
      (batch != null && batch.isUserPaused) ||
      (paused == true && (userPaused ?? true));

  if (isUserPause) {
    final pctSuffix = pct > 0 ? ' $pct%' : '';
    return DownloadStatusPresentation(
      kind: DownloadStatusKind.userPaused,
      label: '已暂停$pctSuffix',
      shortLabel: '已暂停',
      icon: Icons.play_arrow_rounded,
      actionTip: '继续下载',
      actionIcon: Icons.play_arrow_rounded,
    );
  }

  // Interrupted when paused (non-user paused or network disconnected)
  final bool isOffline = !NetworkStatus.instance.online;
  final bool isBatchInterrupted = (paused == true && !(userPaused ?? false)) ||
      (batch != null && batch.isPaused && !batch.isUserPaused) ||
      (job != null && job.state == JobState.paused && !job.userPaused);

  if (isBatchInterrupted) {
    final text = currentStatusText ?? (isOffline ? '下载中断 · 等待网络' : '已中断，点继续');
    return DownloadStatusPresentation(
      kind: DownloadStatusKind.interrupted,
      label: text,
      shortLabel: isOffline ? '等网络' : '已中断',
      icon: Icons.refresh_rounded,
      actionTip: '继续下载',
      actionIcon: Icons.play_arrow_rounded,
    );
  }

  // Finishing phase (saving to gallery)
  final DownloadJob? finishingJob = job?.isFinishing == true
      ? job
      : (batch?.jobs.cast<DownloadJob?>().firstWhere(
            (j) => j?.isFinishing == true,
            orElse: () => null,
          ));
  final bool finishing = isFinishing == true || finishingJob != null;
  if (finishing) {
    final phase = savingPhase ?? finishingJob?.savingPhase;
    final text = phase != null ? '正在保存到相册（$phase）' : '正在保存到相册';
    return DownloadStatusPresentation(
      kind: DownloadStatusKind.finishing,
      label: text,
      shortLabel: '保存中',
      icon: Icons.save_alt_rounded,
      actionTip: '正在保存',
      actionIcon: Icons.hourglass_top_rounded,
    );
  }

  // Failure
  final bool isFailed = failed == true ||
      job?.state == JobState.failed ||
      (batch != null && batch.isTerminal && batch.failedCount > 0);

  if (isFailed) {
    final reason = failureReason ??
        job?.error ??
        batch?.jobs
            .where((j) => j.error != null && j.error!.isNotEmpty)
            .map((j) => j.error!)
            .firstOrNull;
    final reasonSuffix = (reason != null && reason.isNotEmpty) ? '（$reason）' : '';
    final isPartial = partial ?? (batch != null && batch.doneCount > 0);
    final text = isPartial ? '部分保存成功$reasonSuffix' : '下载失败$reasonSuffix';
    return DownloadStatusPresentation(
      kind: DownloadStatusKind.failed,
      label: text,
      shortLabel: '失败',
      icon: Icons.error_outline_rounded,
      actionTip: '重试',
      actionIcon: Icons.refresh,
    );
  }

  // Auto-retry statusText
  if (currentStatusText != null && currentStatusText.startsWith('自动重试')) {
    return DownloadStatusPresentation(
      kind: DownloadStatusKind.interrupted,
      label: currentStatusText,
      shortLabel: currentStatusText.replaceFirst('自动重试', '重试'),
      icon: Icons.refresh_rounded,
      actionTip: '重试',
      actionIcon: Icons.refresh_rounded,
    );
  }

  // Network wait
  final bool isNetworkWait = waitingForNetwork == true ||
      job?.state == JobState.waitingNetwork ||
      (batch != null && (batch.waitingForNetwork || (!batch.isTerminal && isOffline))) ||
      (job != null && isOffline && job.state == JobState.paused);

  if (isNetworkWait) {
    return const DownloadStatusPresentation(
      kind: DownloadStatusKind.waitingNetwork,
      label: '等待网络…联网后自动继续',
      shortLabel: '等网络',
      icon: Icons.wifi_off_rounded,
      actionTip: '继续下载',
      actionIcon: Icons.play_arrow_rounded,
    );
  }

  // Done
  if (job?.state == JobState.done || (batch != null && batch.isTerminal && batch.failedCount == 0)) {
    return const DownloadStatusPresentation(
      kind: DownloadStatusKind.done,
      label: '全部完成 ✓',
      shortLabel: '已完成',
      icon: Icons.check_circle_rounded,
      actionTip: '已完成',
      actionIcon: Icons.check_circle_rounded,
    );
  }

  // Queued
  if (job?.state == JobState.queued) {
    return const DownloadStatusPresentation(
      kind: DownloadStatusKind.queued,
      label: '排队中',
      shortLabel: '排队中',
      icon: Icons.hourglass_empty_rounded,
      actionTip: '等待中',
      actionIcon: Icons.hourglass_empty_rounded,
    );
  }

  // Stalled
  if (stalled == true) {
    return const DownloadStatusPresentation(
      kind: DownloadStatusKind.stalled,
      label: '已停滞',
      shortLabel: '已停滞',
      icon: Icons.refresh,
      actionTip: '重试',
      actionIcon: Icons.refresh,
    );
  }

  // Active downloading
  return DownloadStatusPresentation(
    kind: DownloadStatusKind.downloading,
    label: '下载中',
    shortLabel: pct > 0 ? '$pct%' : '下载中',
    icon: Icons.pause_rounded,
    actionTip: '暂停下载',
    actionIcon: Icons.pause_rounded,
  );
}

String? _batchTransferState(DownloadBatch? batch) {
  if (batch == null || !batch.usesNewTransferPipeline) return null;
  final states = batch.jobs.map((j) => j.transferState).whereType<String>().toList();
  if (states.isEmpty) return null;
  const priority = [
    'storage_full',
    'paused',
    'interrupted',
    'finishing',
    'waiting_pair',
    'waiting_network',
    'running',
    'queued',
    'failed',
    'done',
  ];
  for (final s in priority) {
    if (states.contains(s)) return s;
  }
  return states.first;
}
