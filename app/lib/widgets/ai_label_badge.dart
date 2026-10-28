import 'package:flutter/material.dart';

class AiLabelBadge extends StatelessWidget {
  const AiLabelBadge({super.key, required this.text, this.source});
  final String? text;
  final String? source;

  @override
  Widget build(BuildContext context) {
    if (text == null || text!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: ActionChip(
        label: const Text('AI'),
        visualDensity: VisualDensity.compact,
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('AI 标注'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(text!),
                const SizedBox(height: 12),
                Text(switch (source) {
                  'platform' => '平台识别',
                  'author' => '作者声明',
                  _ => '来源未知',
                }),
                const SizedBox(height: 8),
                const Text('来自平台标注，仅供参考'),
              ],
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
          ),
        ),
      ),
    );
  }
}
