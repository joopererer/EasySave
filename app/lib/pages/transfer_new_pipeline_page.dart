import 'dart:async';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../metadata/site_provenance.dart';
import '../services/download_manager.dart';
import '../services/media_content_type.dart';
import '../services/media_request_policy.dart';
import '../services/parse_service.dart';
import '../services/settings.dart';
import '../services/site_registry.dart';
import '../services/transfer_client.dart';

class _TrackedPipelineJob {
  _TrackedPipelineJob({
    required this.jobId,
    required this.label,
    required this.isImage,
    this.pairId,
  });

  final String jobId;
  final String label;
  final bool isImage;
  final String? pairId;

  String state = 'queued';
  int bytesRead = 0;
  int totalBytes = 0;
  double speedBps = 0;
  int lastBytes = 0;
  DateTime lastTime = DateTime.now();
  Map<String, dynamic>? fileInfo;
  String? computedSha256;
  bool isComputingSha256 = false;
}

/// 开发者选项：新链路下载测试页（OkHttp + 续传协议 + 请求策略 + Live 图成对收尾）
class TransferNewPipelinePage extends StatefulWidget {
  const TransferNewPipelinePage({super.key});

  @override
  State<TransferNewPipelinePage> createState() => _TransferNewPipelinePageState();
}

class _TransferNewPipelinePageState extends State<TransferNewPipelinePage> {
  final TextEditingController _urlController = TextEditingController();
  final TransferClient _client = TransferClient();
  final List<String> _logs = [];
  final List<_TrackedPipelineJob> _jobs = [];

  StreamSubscription<TransferEvent>? _subscription;

  bool _isParsing = false;
  String? _errorMessage;
  String? _parsedUrl;
  ParsedPost? _parsedPost;
  int _selectedItemIndex = 0; // 0-based index into _parsedPost!.items

  @override
  void initState() {
    super.initState();
    _subscription = _client.events.listen((event) {
      if (!mounted) return;
      final idx = _jobs.indexWhere((j) => j.jobId == event.jobId);
      if (idx < 0) return;
      final tracked = _jobs[idx];

      if (event is TransferStateChangeEvent) {
        final line = event.toLogString();
        setState(() {
          tracked.state = event.to;
          _logs.add(line);
          if (_logs.length > 50) {
            _logs.removeAt(0);
          }
        });
        if (event.to == 'done') {
          _fetchFileInfo(tracked);
        }
      } else if (event is TransferProgressEvent) {
        final now = DateTime.now();
        final dt = now.difference(tracked.lastTime).inMilliseconds;
        double speed = tracked.speedBps;
        if (dt >= 500) {
          final db = event.bytesRead - tracked.lastBytes;
          if (db >= 0) {
            speed = (db * 1000.0) / dt;
          }
          tracked.lastBytes = event.bytesRead;
          tracked.lastTime = now;
        }
        setState(() {
          tracked.bytesRead = event.bytesRead;
          tracked.totalBytes = event.totalBytes;
          tracked.speedBps = speed;
        });
      } else if (event is TransferReresolveRequiredEvent) {
        setState(() {
          _logs.add('[XFER] job=${event.jobId} reresolve_required received');
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _fetchFileInfo(_TrackedPipelineJob tracked) async {
    final info = await _client.getJobFileInfo(tracked.jobId);
    if (!mounted) return;
    setState(() {
      tracked.fileInfo = info;
      tracked.computedSha256 = info['partSha256'] as String?;
    });
  }

  Future<void> _parseOnly() async {
    final rawUrl = _urlController.text.trim();
    if (rawUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效链接')),
      );
      return;
    }

    setState(() {
      _isParsing = true;
      _errorMessage = null;
      _parsedPost = null;
      _parsedUrl = null;
    });

    try {
      final outcome = await parsePostOutcome(rawUrl, source: 'transfer_pipeline_test');
      final post = outcome.data;
      if (post.items.isEmpty) {
        throw Exception('未解析到任何媒体项');
      }
      final preferredIdx = _pickDefaultItemIndex(post);
      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _parsedUrl = rawUrl;
        _parsedPost = post;
        _selectedItemIndex = preferredIdx;
        _logs.add('[XFER] 解析完成 platform=${post.platform} items=${post.items.length} default=#${preferredIdx + 1}(${post.items[preferredIdx].type})');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _errorMessage = '$e';
        _logs.add('[XFER] 解析失败: $e');
      });
    }
  }

  int _pickDefaultItemIndex(ParsedPost post) {
    final liveIdx = post.items.indexWhere((it) => it.type == 'live' && it.videoUrl != null);
    if (liveIdx >= 0) return liveIdx;
    final vidIdx = post.items.indexWhere((it) => it.type == 'video');
    if (vidIdx >= 0) return vidIdx;
    return 0;
  }

  Future<void> _startDownload() async {
    final rawUrl = _urlController.text.trim();
    if (rawUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效链接')),
      );
      return;
    }

    setState(() {
      _isParsing = true;
      _errorMessage = null;
      _jobs.clear();
      _logs.clear();
    });

    try {
      final ParsedPost post;
      final int itemIdx;
      if (_parsedPost != null && _parsedUrl == rawUrl) {
        post = _parsedPost!;
        itemIdx = _selectedItemIndex.clamp(0, post.items.length - 1);
      } else {
        final outcome = await parsePostOutcome(rawUrl, source: 'transfer_pipeline_test');
        post = outcome.data;
        if (post.items.isEmpty) {
          throw Exception('未解析到任何媒体项');
        }
        itemIdx = _pickDefaultItemIndex(post);
        _parsedUrl = rawUrl;
        _parsedPost = post;
        _selectedItemIndex = itemIdx;
      }

      final site = SiteRegistry.current.byId(post.platform) ??
          SiteRegistry.current.match(rawUrl) ??
          SiteRegistry.builtinById('xhs');

      if (site == null) {
        throw Exception('无法找到对应平台的请求策略配置: ${post.platform}');
      }

      final policy = MediaRequestPolicy(site);
      final settings = await AppSettings.load();
      final formatPref = settings.imageFormat;

      final plannedFiles = planFiles(
        post,
        [itemIdx],
        (label, seq, ext) => 'test_${post.platform}_$seq',
        formatPref: formatPref,
      );

      if (plannedFiles.isEmpty) {
        throw Exception('未规划出任何下载文件');
      }

      final downloadConfig = (site.data['download'] as Map?) ?? {};
      final mediaHosts = ((downloadConfig['mediaHosts'] as List?) ?? [])
          .cast<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
      final cookieDomains = ((downloadConfig['cookieDomains'] as List?) ?? [])
          .cast<String>();

      final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
      final isLive = plannedFiles.length == 2 && plannedFiles.every((f) => f.isLivePhoto);
      final pairId = isLive ? '${post.id}#${itemIdx + 1}' : null;

      final List<_TrackedPipelineJob> createdJobs = [];
      final List<Future<void> Function()> enqueueFns = [];

      for (var i = 0; i < plannedFiles.length; i++) {
        final targetPlanned = plannedFiles[i];
        if (targetPlanned.urls.isEmpty) {
          throw Exception('未生成媒体资源候选');
        }

        final targetCandidateUrl = targetPlanned.urls.first;
        final targetItem = post.items[targetPlanned.itemIndex - 1];
        final declaredResources = policy.resourcesFor(targetItem);
        final resource = resourceForCandidate(policy, declaredResources, targetCandidateUrl);
        final authorized = await policy.authorize(resource);

        final candidateLabel = candidateLabelOf(targetCandidateUrl);
        final isVideo = !targetPlanned.isImage;
        final category = isVideo ? 'large_file' : 'image';

        final String mime;
        if (isVideo) {
          mime = targetCandidateUrl.toLowerCase().contains('.mov') ? 'video/quicktime' : 'video/mp4';
        } else {
          final token = candidateLabel.contains(':') ? candidateLabel.split(':').last : '';
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

        final suffix = isLive ? (isVideo ? '_vid' : '_img') : '';
        final jobId = 'pipe_${post.platform}_$ts$suffix';
        final label = isLive ? (isVideo ? '实况视频' : '实况图片') : (isVideo ? '视频' : '图片');

        final tracked = _TrackedPipelineJob(
          jobId: jobId,
          label: label,
          isImage: targetPlanned.isImage,
          pairId: pairId,
        );
        createdJobs.add(tracked);

        final prov = buildSiteProvenance(
          platform: post.platform,
          capturedBy: 'EasySave/1.13.0',
          sourceId: post.id,
          sourceUrl: rawUrl,
          authorName: post.author.name,
          title: post.title,
          caption: post.caption,
          aiLabel: post.aiLabel?.text,
          aiLabelSource: post.aiLabel?.source,
          itemIndex: targetPlanned.itemIndex,
          itemCount: post.items.isNotEmpty ? post.items.length : 1,
        ).copyWith(pairId: pairId);

        enqueueFns.add(() async {
          if (mounted) {
            setState(() {
              _logs.add('[XFER] 入队 jobId=$jobId pairId=${pairId ?? "-"} candidate=$candidateLabel format_pref=${formatPref.logToken} category=$category mime=$mime');
            });
          }
          await _client.enqueue(
            jobId: jobId,
            direction: 'download',
            category: category,
            batchId: 'pipeline_test_batch',
            pairId: pairId,
            url: authorized.uri.toString(),
            headers: authorized.headers,
            cookie: authorized.cookie,
            allowedCookieDomains: cookieDomains,
            policyHosts: mediaHosts,
            mime: mime,
            policyKey: site.data['id'] as String?,
            provenance: prov.toJson(),
          );
        });
      }

      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _jobs.addAll(createdJobs);
      });

      for (final fn in enqueueFns) {
        await fn();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _errorMessage = '$e';
        _logs.add('[XFER] 解析或入队失败: $e');
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatSpeed(double bps) {
    if (bps <= 0) return '0 B/s';
    if (bps < 1024) return '${bps.toStringAsFixed(0)} B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${(bps / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }

  List<String> get _recentLogs {
    if (_logs.length <= 8) return _logs;
    return _logs.sublist(_logs.length - 8);
  }

  bool get _hasRunningJob => _jobs.any((j) => j.state == 'running');

  @override
  Widget build(BuildContext context) {
    final post = _parsedPost;
    final isPair = _jobs.length == 2;

    return Scaffold(
      appBar: AppBar(
        title: const Text('新链路下载测试'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: '帖子链接',
              hintText: '粘贴小红书或 Instagram 分享链接（支持 Live 图）',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('pipeline_parse_btn'),
                  onPressed: _isParsing ? null : _parseOnly,
                  icon: const Icon(Icons.search),
                  label: const Text('解析条目'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  key: const Key('pipeline_start_btn'),
                  onPressed: (_isParsing || _hasRunningJob) ? null : _startDownload,
                  icon: _isParsing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(_isParsing ? '解析中...' : '解析并下载'),
                ),
              ),
            ],
          ),
          if (post != null && post.items.isNotEmpty) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _selectedItemIndex.clamp(0, post.items.length - 1),
              decoration: const InputDecoration(
                labelText: '选择下载项',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (var i = 0; i < post.items.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '#${i + 1} · ${post.items[i].type == 'live' && post.items[i].videoUrl != null ? 'Live 实况图 (照片+视频)' : post.items[i].type}',
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) {
                  setState(() => _selectedItemIndex = v);
                }
              },
            ),
          ],
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
              ),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ],
          if (isPair) ...[
            const SizedBox(height: 12),
            Card(
              color: Colors.blue.withValues(alpha: 0.05),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Live 成对任务 (pairId: ${_jobs.first.pairId ?? "-"})',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '两个文件全部下载完成后再一起写入并发布，当前状态: ${_jobs.map((j) => '${j.label}=${j.state}').join(' | ')}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
          for (final tracked in _jobs) ...[
            const SizedBox(height: 12),
            _buildJobCard(tracked),
            if (tracked.fileInfo != null && tracked.fileInfo!['exists'] == true)
              _buildResultCard(tracked),
          ],
          const SizedBox(height: 16),
          const Text(
            '最近 [XFER] 转移日志：',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: _recentLogs.isEmpty
                ? const Text(
                    '暂无日志',
                    style: TextStyle(color: Colors.white60, fontFamily: 'monospace'),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in _recentLogs)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            line,
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildJobCard(_TrackedPipelineJob tracked) {
    final isDone = tracked.state == 'done';
    final isRunning = tracked.state == 'running';
    final isPaused = tracked.state == 'paused';
    final isWaitingPair = tracked.state == 'waiting_pair';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${tracked.label}: ',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: isDone
                        ? Colors.green.withValues(alpha: 0.2)
                        : isRunning
                            ? Colors.blue.withValues(alpha: 0.2)
                            : isWaitingPair
                                ? Colors.orange.withValues(alpha: 0.2)
                                : Colors.grey.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    tracked.state,
                    style: TextStyle(
                      color: isDone
                          ? Colors.green[800]
                          : isRunning
                              ? Colors.blue[800]
                              : isWaitingPair
                                  ? Colors.orange[800]
                                  : Colors.black87,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Spacer(),
                Text('速度: ${_formatSpeed(tracked.speedBps)}'),
              ],
            ),
            const SizedBox(height: 8),
            Text('进度: ${_formatBytes(tracked.bytesRead)} / ${tracked.totalBytes > 0 ? _formatBytes(tracked.totalBytes) : '未知'}'),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: tracked.totalBytes > 0
                  ? (tracked.bytesRead / tracked.totalBytes).clamp(0.0, 1.0)
                  : (isRunning ? null : 0.0),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                OutlinedButton.icon(
                  onPressed: isRunning ? () => _client.pause(tracked.jobId) : null,
                  icon: const Icon(Icons.pause),
                  label: const Text('暂停'),
                ),
                OutlinedButton.icon(
                  onPressed: isPaused ? () => _client.resume(tracked.jobId) : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('继续'),
                ),
                OutlinedButton.icon(
                  onPressed: (!isDone && tracked.state != 'canceled' && tracked.state != 'failed')
                      ? () => _client.cancel(tracked.jobId)
                      : null,
                  icon: const Icon(Icons.cancel),
                  label: const Text('取消'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(_TrackedPipelineJob tracked) {
    final info = tracked.fileInfo!;
    final pairId = info['pairId'] ?? tracked.pairId;
    final readbackPairId = info['readbackPairId'];
    final readbackSourceId = info['readbackSourceId'];
    final readbackItemIndex = info['readbackItemIndex'];

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        color: Colors.green.withValues(alpha: 0.05),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${tracked.label} · 下载完成文件信息',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const Divider(),
              if (info['title'] != null) ...[
                Text('相册文件名: ${info['title']}'),
                const SizedBox(height: 4),
              ],
              Text('文件大小: ${_formatBytes((info['size'] as num?)?.toInt() ?? 0)} (${info['size']} 字节)'),
              const SizedBox(height: 4),
              if (info['md5'] != null) ...[
                SelectableText('MD5: ${info['md5']}'),
                const SizedBox(height: 4),
              ],
              if (pairId != null || readbackPairId != null) ...[
                Text('配对字段: pairId=${pairId ?? "-"} | 回读 pairId=${readbackPairId ?? "-"} | sourceId=${readbackSourceId ?? "-"} | itemIndex=${readbackItemIndex ?? "-"}'),
                const SizedBox(height: 4),
              ],
              if (tracked.computedSha256 != null && tracked.computedSha256!.isNotEmpty) ...[
                SelectableText('SHA-256: ${tracked.computedSha256}'),
                const SizedBox(height: 4),
              ] else ...[
                Row(
                  children: [
                    Text('SHA-256: ${tracked.isComputingSha256 ? "计算中..." : "未计算"}'),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: tracked.isComputingSha256
                          ? null
                          : () async {
                              setState(() {
                                tracked.isComputingSha256 = true;
                              });
                              final sha = await _client.computeMediaSha256(
                                jobId: tracked.jobId,
                                mediaId: info['mediaId'] as String?,
                              );
                              if (mounted) {
                                setState(() {
                                  tracked.computedSha256 = sha.isNotEmpty ? sha : '计算失败';
                                  tracked.isComputingSha256 = false;
                                });
                              }
                            },
                      child: const Text('计算 SHA-256'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              Text(
                '来源信息回读结果: ${info['readbackMatch'] == true ? '字段一致 (embedded and verified)' : (info['provenanceStatus'] == 'skipped_unsupported' ? '跳过不支持格式 (skipped_unsupported)' : '未注入 / 不一致')}',
                style: TextStyle(
                  color: info['readbackMatch'] == true ? Colors.green[800] : Colors.black87,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (info['mediaId'] != null)
                    ElevatedButton.icon(
                      onPressed: () async {
                        final mid = info['mediaId'].toString();
                        await _client.openInGallery(mid);
                      },
                      icon: const Icon(Icons.photo_library),
                      label: const Text('在相册中打开'),
                    ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[50],
                      foregroundColor: Colors.red,
                    ),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await _client.deleteJobFile(tracked.jobId);
                      await _fetchFileInfo(tracked);
                      messenger.showSnackBar(
                        const SnackBar(content: Text('已删除测试文件')),
                      );
                    },
                    icon: const Icon(Icons.delete_forever),
                    label: const Text('删除测试文件'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
