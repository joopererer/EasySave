import 'package:easysave/core/dev_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DevLog.scrub', () {
    test('keeps only host and path of a url', () {
      final out = DevLog.scrub(
        'parse https://www.xiaohongshu.com/explore/abc123?xsec_token=SECRET',
      );
      expect(out, contains('www.xiaohongshu.com/explore/abc123'));
      expect(out, isNot(contains('xsec_token')));
      expect(out, isNot(contains('SECRET')));
    });

    test('redacts cookie values', () {
      final out = DevLog.scrub('Cookie: web_session=abc123; other=1');
      expect(out, isNot(contains('abc123')));
      expect(out, contains('<redacted>'));
    });

    test('redacts authorization headers and bearer tokens', () {
      final out = DevLog.scrub('authorization: Bearer eyJhbGciOi.J9.sig');
      expect(out, isNot(contains('eyJhbGciOi')));
      expect(out, contains('<redacted>'));
    });

    test('redacts token-ish key=value pairs', () {
      // Only the names on the sensitive-key list (see DevLog._sensitiveKey)
      // are scrubbed. `share_id` is intentionally NOT on the list — when it
      // appears inside log messages as a diagnostic id, callers want to see it.
      // The URL-scrubbing pass strips it from logged *URLs*; that's the privacy
      // guarantee for share_id, not a blanket replacement in free text.
      final out = DevLog.scrub('xsec_token=abc share_id=def');
      expect(out, isNot(contains('abc')));
      expect(out, contains('<redacted>'));
      expect(out, contains('share_id=def'));
    });

    test('keeps harmless diagnostics untouched', () {
      const msg = 'batch start id=background-123 source=background post=abc123';
      expect(DevLog.scrub(msg), msg);
    });

    test('redacts a url inside an exception message', () {
      final out = DevLog.scrub(
        'failed: java.io.IOException: https://cdn.example.com/a.jpg?token=zzz',
      );
      expect(out, contains('cdn.example.com/a.jpg'));
      expect(out, isNot(contains('token=zzz')));
    });
  });
}
