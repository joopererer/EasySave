import 'dart:async';
import 'package:flutter/material.dart';
import '../metadata/site_provenance.dart';
import '../services/download_manager.dart';
import '../services/media_content_type.dart';
import '../services/media_request_policy.dart';
import '../services/parse_service.dart';
import '../services/settings.dart';
import '../services/site_registry.dart';
import '../services/transfer_client.dart';

/// 开发者选项：新链路下载测试页（OkHttp + 续传协议 + 请求策略）
class TransferNewPipelinePage extends StatefulWidget {
  const TransferNewPipelinePage({super.key});

  @override
  State<TransferNewPipelinePage> createState() => _TransferNewPipelinePageState();
}

class _TransferNewPipelinePageState extends State<TransferNewPipelinePage> {
  final TextEditingController _urlController = TextEditingController();
  final TransferClient _client = TransferClient();
  final List<String> _logs = [];

  StreamSubscription<TransferEvent>? _subscription;

  bool _isParsing = false;
  String? _jobId;
  String _state = 'idle';
  int _bytesRead = 0;
  int _totalBytes = 0;
  double _speedBps = 0;
  int _lastBytes = 0;
  DateTime _lastTime = DateTime.now();

  Map<String, dynamic>? _fileInfo;
  String? _computedSha256;
  bool _isComputingSha256 = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _subscription = _client.events.listen((event) {
      if (!mounted) return;
      if (event.jobId != _jobId) return;

      if (event is TransferStateChangeEvent) {
        final line = event.toLogString();
        setState(() {
          _state = event.to;
          _logs.add(line);
          if (_logs.length > 50) {
            _logs.removeAt(0);
          }
        });
        if (event.to == 'done') {
          _fetchFileInfo();
        }
      } else if (event is TransferProgressEvent) {
        final now = DateTime.now();
        final dt = now.difference(_lastTime).inMilliseconds;
        double speed = _speedBps;
        if (dt >= 500) {
          final db = event.bytesRead - _lastBytes;
          if (db >= 0) {
            speed = (db * 1000.0) / dt;
          }
          _lastBytes = event.bytesRead;
          _lastTime = now;
        }
        setState(() {
          _bytesRead = event.bytesRead;
          _totalBytes = event.totalBytes;
          _speedBps = speed;
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

  Future<void> _fetchFileInfo() async {
    final jid = _jobId;
    if (jid == null) return;
    final info = await _client.getJobFileInfo(jid);
    if (!mounted) return;
    setState(() {
      _fileInfo = info;
      _computedSha256 = info['partSha256'] as String?;
    });
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
      _fileInfo = null;
      _computedSha256 = null;
      _isComputingSha256 = false;
      _logs.clear();
      _bytesRead = 0;
      _totalBytes = 0;
      _speedBps = 0;
      _state = 'parsing';
    });

    try {
      final outcome = await parsePostOutcome(rawUrl, source: 'transfer_pipeline_test');
      final post = outcome.data;
      if (post.items.isEmpty) {
        throw Exception('未解析到任何媒体项');
      }

      final site = SiteRegistry.current.byId(post.platform) ??
          SiteRegistry.current.match(rawUrl) ??
          SiteRegistry.builtinById('xhs');

      if (site == null) {
        throw Exception('无法找到对应平台的请求策略配置: ${post.platform}');
      }

      final policy = MediaRequestPolicy(site);

      // 复用旧链路候选选择与请求头构造逻辑 (Requirement 5)
      final settings = await AppSettings.load();
      final formatPref = settings.imageFormat;

      final plannedFiles = planFiles(
        post,
        List.generate(post.items.length, (i) => i),
        (label, seq, ext) => 'test_${post.platform}_$seq',
        formatPref: formatPref,
      );

      if (plannedFiles.isEmpty) {
        throw Exception('未规划出任何下载文件');
      }

      // 找最大的视频；若无视频则取第一张图
      final plannedVideos = plannedFiles.where((f) => !f.isImage).toList();
      final PlannedFile targetPlanned;
      if (plannedVideos.isNotEmpty) {
        targetPlanned = plannedVideos.first;
      } else {
        targetPlanned = plannedFiles.first;
      }

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

      // 预期类型和分类必须来自所选候选本身 (Requirement 7)
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

      final downloadConfig = (site.data['download'] as Map?) ?? {};
      final mediaHosts = ((downloadConfig['mediaHosts'] as List?) ?? [])
          .cast<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
      final cookieDomains = ((downloadConfig['cookieDomains'] as List?) ?? [])
          .cast<String>();

      final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
      final jobId = 'pipe_${post.platform}_$ts';

      _jobId = jobId;
      _lastBytes = 0;
      _lastTime = DateTime.now();

      setState(() {
        _isParsing = false;
        _state = 'queued';
        _logs.add('[XFER] 准备入队 jobId=$jobId candidate=$candidateLabel format_pref=${formatPref.logToken} category=$category mime=$mime');
      });

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
      );

      await _client.enqueue(
        jobId: jobId,
        direction: 'download',
        category: category,
        batchId: 'pipeline_test_batch',
        url: authorized.uri.toString(),
        headers: authorized.headers,
        cookie: authorized.cookie,
        allowedCookieDomains: cookieDomains,
        policyHosts: mediaHosts,
        mime: mime,
        policyKey: site.data['id'] as String?,
        provenance: prov.toJson(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isParsing = false;
        _state = 'error';
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

  List<String> get _recent5Logs {
    if (_logs.length <= 5) return _logs;
    return _logs.sublist(_logs.length - 5);
  }

  @override
  Widget build(BuildContext context) {
    final isDone = _state == 'done';
    final isRunning = _state == 'running';
    final isPaused = _state == 'paused';

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
              hintText: '粘贴小红书或 Instagram 分享链接',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.link),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            key: const Key('pipeline_start_btn'),
            onPressed: (_isParsing || isRunning) ? null : _startDownload,
            icon: _isParsing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download),
            label: Text(_isParsing ? '解析中...' : '解析并下载到 transfers/'),
          ),
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
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '任务状态: ',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: isDone
                              ? Colors.green.withValues(alpha: 0.2)
                              : isRunning
                                  ? Colors.blue.withValues(alpha: 0.2)
                                  : Colors.grey.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _state,
                          style: TextStyle(
                            color: isDone
                                ? Colors.green[800]
                                : isRunning
                                    ? Colors.blue[800]
                                    : Colors.black87,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text('速度: ${_formatSpeed(_speedBps)}'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('进度: ${_formatBytes(_bytesRead)} / ${_totalBytes > 0 ? _formatBytes(_totalBytes) : '未知'}'),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: _totalBytes > 0 ? (_bytesRead / _totalBytes).clamp(0.0, 1.0) : (isRunning ? null : 0.0),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('pipeline_pause_btn'),
                        onPressed: (_jobId != null && isRunning)
                            ? () => _client.pause(_jobId!)
                            : null,
                        icon: const Icon(Icons.pause),
                        label: const Text('暂停'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('pipeline_resume_btn'),
                        onPressed: (_jobId != null && isPaused)
                            ? () => _client.resume(_jobId!)
                            : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('继续'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('pipeline_cancel_btn'),
                        onPressed: (_jobId != null && !isDone && _state != 'canceled')
                            ? () => _client.cancel(_jobId!)
                            : null,
                        icon: const Icon(Icons.cancel),
                        label: const Text('取消'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_fileInfo != null && _fileInfo!['exists'] == true) ...[
            const SizedBox(height: 16),
            Card(
              color: Colors.green.withValues(alpha: 0.05),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '下载完成文件信息',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const Divider(),
                    if (_fileInfo!['title'] != null) ...[
                      Text('相册文件名: ${_fileInfo!['title']}'),
                      const SizedBox(height: 4),
                    ],
                    Text('文件大小: ${_formatBytes((_fileInfo!['size'] as num?)?.toInt() ?? 0)} (${_fileInfo!['size']} 字节)'),
                    const SizedBox(height: 4),
                    if (_fileInfo!['md5'] != null) ...[
                      SelectableText('MD5: ${_fileInfo!['md5']}'),
                      const SizedBox(height: 4),
                    ],
                    if (_computedSha256 != null && _computedSha256!.isNotEmpty) ...[
                      SelectableText('SHA-256: $_computedSha256'),
                      const SizedBox(height: 4),
                    ] else ...[
                      Row(
                        children: [
                          Text('SHA-256: ${_isComputingSha256 ? "计算中..." : "未计算"}'),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            key: const Key('pipeline_compute_sha256_btn'),
                            onPressed: _isComputingSha256
                                ? null
                                : () async {
                                    setState(() {
                                      _isComputingSha256 = true;
                                    });
                                    final sha = await _client.computeMediaSha256(
                                      jobId: _jobId,
                                      mediaId: _fileInfo?['mediaId'] as String?,
                                    );
                                    if (mounted) {
                                      setState(() {
                                        _computedSha256 = sha.isNotEmpty ? sha : '计算失败';
                                        _isComputingSha256 = false;
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
                      '来源信息回读结果: ${_fileInfo!['readbackMatch'] == true ? '字段一致 (embedded and verified)' : (_fileInfo!['provenanceStatus'] == 'skipped_unsupported' ? '跳过不支持格式 (skipped_unsupported)' : '未注入 / 不一致')}',
                      style: TextStyle(
                        color: _fileInfo!['readbackMatch'] == true
                            ? Colors.green[800]
                            : Colors.black87,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (_fileInfo!['mediaId'] != null)
                          ElevatedButton.icon(
                            key: const Key('pipeline_open_gallery_btn'),
                            onPressed: () async {
                              final mid = _fileInfo!['mediaId'].toString();
                              await _client.openInGallery(mid);
                            },
                            icon: const Icon(Icons.photo_library),
                            label: const Text('在相册中打开'),
                          ),
                        ElevatedButton.icon(
                          key: const Key('pipeline_delete_file_btn'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red[50],
                            foregroundColor: Colors.red,
                          ),
                          onPressed: () async {
                            final jid = _jobId;
                            if (jid != null) {
                              final messenger = ScaffoldMessenger.of(context);
                              await _client.deleteJobFile(jid);
                              await _fetchFileInfo();
                              messenger.showSnackBar(
                                const SnackBar(content: Text('已删除测试文件')),
                              );
                            }
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
          ],
          const SizedBox(height: 16),
          const Text(
            '最近 5 行 [XFER] 转移日志：',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
            ),
            child: _recent5Logs.isEmpty
                ? const Text(
                    '暂无日志',
                    style: TextStyle(color: Colors.white60, fontFamily: 'monospace'),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final line in _recent5Logs)
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
}

