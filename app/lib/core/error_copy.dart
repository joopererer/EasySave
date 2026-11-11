// Single source of error copy for the App. Content follows the
// code -> message -> action table in spec/parsing.md, which is shared
// with the browser extension.

import 'models.dart';
import '../services/site_registry.dart';

/// UI action attached to an error code.
enum ErrorAction { goLogin, backHome, retry, repaste }

class ErrorCopy {
  const ErrorCopy({required this.message, required this.action});

  final String message;
  final ErrorAction action;
}

/// Text shown for a parse error: the engine's own message when it has one,
/// otherwise the spec copy for [code].
String displayErrorMessage(String code, String? message) =>
    (message != null && message.isNotEmpty)
    ? message
    : errorCopyFor(code).message;

/// Copy for parse error codes. Unknown codes fall back to a retry prompt.
ErrorCopy errorCopyFor(String code) {
  switch (code) {
    case ParseErrorCode.loginRequired:
      final names = SiteRegistry.current.sites
          .where(
            (s) =>
                s.enabled && {'optional', 'required'}.contains(s.auth['mode']),
          )
          .map((s) => s.displayName)
          .join('/');
      return ErrorCopy(
        message: names.isEmpty ? '需要先登录' : '需要先登录$names',
        action: ErrorAction.goLogin,
      );
    case ParseErrorCode.ageNotSet:
      return const ErrorCopy(
        message: '该内容需要你的 X 账号先设置出生日期（年龄）后才能查看',
        action: ErrorAction.backHome,
      );
    case ParseErrorCode.ageRestricted:
      return const ErrorCopy(
        message: '该帖子有年龄限制，需要登录已完成年龄验证的 X 账号才能查看',
        action: ErrorAction.goLogin,
      );
    case ParseErrorCode.protectedAccount:
      return const ErrorCopy(
        message: '该帖子来自受保护的账号，只有获准的关注者可以查看',
        action: ErrorAction.backHome,
      );
    case ParseErrorCode.privateOrUnavailable:
      return const ErrorCopy(
        message: '该帖子不存在、私密或已删除',
        action: ErrorAction.backHome,
      );
    case ParseErrorCode.postNotFound:
      return const ErrorCopy(
        message: '帖子不存在，或链接已失效',
        action: ErrorAction.backHome,
      );
    case ParseErrorCode.tokenRequired:
      return const ErrorCopy(
        message: '链接缺少访问令牌，请使用小红书 App 内“分享”得到的链接，或登录后重试',
        action: ErrorAction.repaste,
      );
    case ParseErrorCode.blocked:
      return const ErrorCopy(
        message: '请求被对方限制，请稍后再试',
        action: ErrorAction.retry,
      );
    case ParseErrorCode.invalidPage:
      return const ErrorCopy(
        message: '页面内容无法识别，可能已改版',
        action: ErrorAction.retry,
      );
    case ParseErrorCode.unsupportedUrl:
      final names = SiteRegistry.current.sites
          .where((s) => s.enabled)
          .map((s) => s.displayName)
          .join('/');
      return ErrorCopy(
        message: names.isEmpty ? '不支持的链接，请粘贴帖子链接' : '不支持的链接，请粘贴$names 帖子链接',
        action: ErrorAction.repaste,
      );
    case ParseErrorCode.timeout:
      return const ErrorCopy(
        message: '网络超时，请检查网络后重试',
        action: ErrorAction.retry,
      );
    default:
      return const ErrorCopy(message: '解析失败，请重试', action: ErrorAction.retry);
  }
}
