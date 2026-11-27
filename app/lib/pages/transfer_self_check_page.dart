import 'dart:async';
import 'package:flutter/material.dart';
import '../services/transfer_client.dart';

/// 开发者选项：传输服务骨架自检页面
class TransferSelfCheckPage extends StatefulWidget {
  const TransferSelfCheckPage({super.key});

  @override
  State<TransferSelfCheckPage> createState() => _TransferSelfCheckPageState();
}

class _TransferSelfCheckPageState extends State<TransferSelfCheckPage> {
  final TransferClient _client = TransferClient();
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();

  StreamSubscription<TransferEvent>? _subscription;

  bool _isRunning = false;
  bool _isFinished = false;

  final Set<String> _completedJobs = {};

  String? _job1Id;
  String? _job2Id;
  String? _job3Id;

  @override
  void initState() {
    super.initState();
    _subscription = _client.events.listen((event) {
      if (!mounted) return;
      if (event is TransferStateChangeEvent) {
        final line = event.toLogString();
        setState(() {
          _logs.add(line);
          if (event.to == 'done') {
            _completedJobs.add(event.jobId);
          }
          if (_job1Id != null && _job2Id != null && _job3Id != null) {
            if (_completedJobs.contains(_job1Id) &&
                _completedJobs.contains(_job2Id) &&
                _completedJobs.contains(_job3Id)) {
              _isFinished = true;
              _isRunning = false;
            }
          }
        });

        // 任务 2 出现网络错误等待网络时，模拟网络恢复
        if (event.jobId == _job2Id && event.to == 'waiting_network') {
          Future.delayed(const Duration(milliseconds: 500), () {
            _client.simulateNetwork(true);
          });
        }

        _scrollToBottom();
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _startSelfCheck() async {
    if (_isRunning) return;
    setState(() {
      _isRunning = true;
      _isFinished = false;
      _logs.clear();
      _completedJobs.clear();
      _logs.add('[XFER] ====== 开始传输服务骨架自检 ======');
    });

    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);

    // 1. 任务 1：成功（图片类）
    _job1Id = 'job1_ok_$ts';
    // 2. 任务 2：先网络错误后成功（图片类）
    _job2Id = 'job2_net_$ts';
    // 3. 任务 3：其他错误 2 次后成功（大文件类）
    _job3Id = 'job3_ret_$ts';

    await _client.enqueue(
      jobId: _job1Id,
      direction: 'download',
      category: 'image',
      batchId: 'self_check_batch',
      fakePlan: 'success',
    );

    await _client.enqueue(
      jobId: _job2Id,
      direction: 'download',
      category: 'image',
      batchId: 'self_check_batch',
      fakePlan: 'network_once',
    );

    await _client.enqueue(
      jobId: _job3Id,
      direction: 'download',
      category: 'large_file',
      batchId: 'self_check_batch',
      fakePlan: 'other_twice',
    );
  }

  Future<void> _clearSelfCheckJobs() async {
    await _client.clearSelfCheckJobs();
    setState(() {
      _isRunning = false;
      _isFinished = false;
      _logs.clear();
      _completedJobs.clear();
      _job1Id = null;
      _job2Id = null;
      _job3Id = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('传输服务自检'),
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '自检任务规格：',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text('• 任务 1：图片类 · 一次成功 (FakeWorker)'),
                  const Text('• 任务 2：图片类 · 先网络错误等待网络，恢复后成功'),
                  const Text('• 任务 3：大文件 · 其他错误重试 2 次后成功 (5s / 15s)'),
                  const SizedBox(height: 8),
                  const Text(
                    '说明：通知栏常驻单一前台通知；全部任务结束 60 秒后服务自行停止。',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        key: const Key('start_self_check_button'),
                        onPressed: _isRunning ? null : _startSelfCheck,
                        icon: _isRunning
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.play_arrow),
                        label: Text(_isRunning ? '自检运行中...' : '开始自检'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        key: const Key('clear_self_check_button'),
                        onPressed: _isRunning ? null : _clearSelfCheckJobs,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('清空自检任务'),
                      ),
                      const SizedBox(width: 12),
                      if (_isFinished)
                        const Chip(
                          label: Text('自检通过 (3/3 成功)'),
                          backgroundColor: Colors.greenAccent,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text(
                  '[XFER] 状态转移实时日志：',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0x0A000000),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: _logs.isEmpty
                  ? const Center(
                      child: Text(
                        '点击「开始自检」入队 3 个任务',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: SelectableText(
                            _logs[index],
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

