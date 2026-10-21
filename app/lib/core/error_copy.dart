// Single source of error copy for the App. Content follows the
// code -> message -> action table in spec/parsing.md, which is shared
// with the browser extension.

import 'models.dart';

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
      return const ErrorCopy(
        message: '需要先登录小红书/Instagram',
        action: ErrorAction.goLogin,
      );
    case ParseErrorCode.privateOrUnavailable:
      return const ErrorCopy(
        message: '该帖子不存在、私密或已删除',
        action: ErrorAction.backHome,
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
      return const ErrorCopy(
        message: '不支持的链接，请粘贴小红书/Instagram 帖子链接',
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
