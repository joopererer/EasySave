import 'package:easysave/core/error_copy.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('errorCopyFor', () {
    test('covers every spec error code with message and action', () {
      expect(
        errorCopyFor(ParseErrorCode.loginRequired).action,
        ErrorAction.goLogin,
      );
      expect(
        errorCopyFor(ParseErrorCode.loginRequired).message,
        '需要先登录小红书/Instagram',
      );
      expect(
        errorCopyFor(ParseErrorCode.privateOrUnavailable).action,
        ErrorAction.backHome,
      );
      expect(errorCopyFor(ParseErrorCode.blocked).action, ErrorAction.retry);
      expect(
        errorCopyFor(ParseErrorCode.invalidPage).action,
        ErrorAction.retry,
      );
      expect(
        errorCopyFor(ParseErrorCode.unsupportedUrl).action,
        ErrorAction.repaste,
      );
      expect(errorCopyFor(ParseErrorCode.timeout).action, ErrorAction.retry);
    });

    test('falls back to retry on unknown codes', () {
      final copy = errorCopyFor('SOMETHING_NEW');
      expect(copy.action, ErrorAction.retry);
      expect(copy.message.isNotEmpty, isTrue);
    });
  });

  group('AppSettings.fileName', () {
    test('expands known tokens', () {
      final settings = AppSettings()
        ..namePattern = '{date}_{author}_{id}_{seq}';
      final name = settings.fileName(postId: 'abc', seq: 3, author: 'momo');
      expect(name.endsWith('_momo_abc_3'), isTrue);
      expect(name.length, greaterThan('_momo_abc_3'.length));
    });

    test('leaves unknown tokens untouched', () {
      final settings = AppSettings()..namePattern = '{id}-{foo}';
      expect(settings.fileName(postId: 'abc', seq: 1, author: ''), 'abc-{foo}');
    });
  });
}
