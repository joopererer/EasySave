// Batch queue page: resolve a list of links one by one, reusing the
// single-post parse outcome. Each success opens the standard PreviewPage
// (its own download batch); failures show the error copy inline.

import 'package:easysave/generated/parser_version.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/error_copy.dart';
import '../core/models.dart';
import '../services/links.dart';
import '../services/parse_service.dart';
import '../services/seal.dart';
import '../widgets/shared.dart';
import 'preview_page.dart';

enum BatchItemState { queued, active, done, failed, skipped }

class BatchItem {
  BatchItem(this.link);

  final String link;
  BatchItemState state = BatchItemState.queued;
  ParsedPost? post;
  List<RawImageEntry> rawImages = const [];
  String? errorCode;
}

class BatchPage extends StatefulWidget {
  const BatchPage({super.key, required this.links});

  final List<String> links;

  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> {
  late final List<BatchItem> _items = [
    for (final link in widget.links) BatchItem(link),
  ];
  bool _running = false;
  bool _cancelRequested = false;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  String _platformOf(String link) {
    final host = Uri.tryParse(link)?.host.toLowerCase() ?? '';
    if (host.contains('instagram.com') || host.contains('instagr.am')) {
      return 'instagram';
    }
    return 'xhs';
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    for (final item in _items) {
      if (_cancelRequested || !mounted) break;
      if (item.state != BatchItemState.queued) continue;
      if (isYouTubeLink(item.link)) {
        setState(() => item.state = BatchItemState.skipped);
        continue;
      }
      setState(() => item.state = BatchItemState.active);
      try {
        final resolved = await resolveShortLink(item.link);
        final outcome = await parsePostOutcome(resolved);
        if (!mounted || _cancelRequested) break;
        setState(() {
          item.state = BatchItemState.done;
          item.post = outcome.data;
          item.rawImages = outcome.rawImages;
        });
      } on ParseFailure catch (e) {
        if (!mounted) break;
        setState(() {
          item.state = BatchItemState.failed;
          item.errorCode = e.code;
        });
      } catch (_) {
        if (!mounted) break;
        setState(() {
          item.state = BatchItemState.failed;
          item.errorCode = ParseErrorCode.invalidPage;
        });
      }
    }
    if (mounted) setState(() => _running = false);
  }

  int get _doneCount =>
      _items.where((i) => i.state == BatchItemState.done).length;

  Future<void> _open(BatchItem item) async {
    if (_opening || item.post == null) return;
    _opening = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PreviewPage(post: item.post!, rawImages: item.rawImages),
      ),
    );
    _opening = false;
  }

  Future<void> _sendToSeal(BatchItem item) async {
    try {
      await sendToSeal(item.link);
    } on SealMissing {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未安装 Seal，请先按指引安装')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('跳转失败，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _items.length;
    return Scaffold(
      appBar: AppBar(title: Text('批量解析 $_doneCount/$total')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _items.length,
              itemBuilder: (context, i) => _row(_items[i]),
            ),
          ),
          if (_running)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: OutlinedButton(
                onPressed: () => setState(() => _cancelRequested = true),
                child: const Text('取消'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BatchItem item) {
    return Card(
      child: ListTile(
        leading: PlatformTag(platform: _platformOf(item.link)),
        title: Text(
          item.post?.title?.isNotEmpty == true ? item.post!.title! : item.link,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: _subtitle(item),
        trailing: _trailing(item),
        onTap: item.state == BatchItemState.done ? () => _open(item) : null,
      ),
    );
  }

  Widget? _subtitle(BatchItem item) {
    switch (item.state) {
      case BatchItemState.queued:
        return const Text('等待中');
      case BatchItemState.active:
        return const Text('解析中…');
      case BatchItemState.done:
        final post = item.post!;
        return Text('${post.author.name ?? ''} · ${post.items.length} 个文件');
      case BatchItemState.failed:
        final copy = errorCopyFor(item.errorCode ?? ParseErrorCode.invalidPage);
        return Text(
          copy.message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        );
      case BatchItemState.skipped:
        return const Text('YouTube 视频由 Seal 下载');
    }
  }

  Widget? _trailing(BatchItem item) {
    switch (item.state) {
      case BatchItemState.active:
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case BatchItemState.done:
        return const Icon(Icons.chevron_right);
      case BatchItemState.failed:
        return IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: '复制诊断信息',
          onPressed: () {
            Clipboard.setData(
              ClipboardData(
                text:
                    'platform=${_platformOf(item.link)}, '
                    'code=${item.errorCode}, url=${item.link}, '
                    'parser=${ParserVersion.version}',
              ),
            );
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('诊断信息已复制')));
          },
        );
      case BatchItemState.skipped:
        return TextButton(
          onPressed: () => _sendToSeal(item),
          child: const Text('去 Seal'),
        );
      case BatchItemState.queued:
        return null;
    }
  }
}
