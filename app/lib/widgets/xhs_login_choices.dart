import 'package:flutter/material.dart';

import '../services/auth.dart';

const xhsQrLoginHint = '扫码登录：截屏后用小红书 App 的“扫一扫 → 从相册选择”完成登录。';

/// Shared by the account tab's dialog and the generic login route.
class XhsLoginChoices extends StatelessWidget {
  const XhsLoginChoices({super.key, required this.onSelected});

  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final probe in xhsProbeUrls())
        ListTile(
          title: Text(
            xhsDomain(Uri.parse(probe).host) == 'rednote.com'
                ? 'rednote（海外账号）'
                : '小红书（中国大陆账号）',
          ),
          subtitle: xhsDomain(Uri.parse(probe).host) == 'xiaohongshu.com'
              ? const Text(xhsQrLoginHint)
              : null,
          onTap: () => onSelected(
            xhsDomain(Uri.parse(probe).host) == 'xiaohongshu.com'
                ? loginEntryUrl('xhs')
                : probe,
          ),
        ),
    ],
  );
}
