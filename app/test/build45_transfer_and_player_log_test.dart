import 'dart:io';

import 'package:easysave/services/media_request_policy.dart';
import 'package:easysave/services/preview_video.dart';
import 'package:easysave/services/transfer_headers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// v1.10.3: every transfer of one media URL sends the same headers, so the
// preflight and the download cannot look like two different clients to the CDN
// (that mismatch is what reset the connection and lost the jpg original).
// Player failures are logged as a type only: the native message carries the URL.

void main() {
  group('one header set for every transfer', () {
    test('a transfer always carries a browser User-Agent and identity encoding',
        () {
      final headers = unifiedTransferHeaders({'Referer': 'https://x.test/'});
      expect(headers['User-Agent'], kTransferUserAgent);
      expect(headers['Accept-Encoding'], 'identity');
      expect(headers['Referer'], 'https://x.test/');
    });

    test('a declared header wins over the default', () {
      final headers = unifiedTransferHeaders({
        'User-Agent': 'test-UA',
        'Accept-Encoding': 'gzip',
      });
      expect(headers['User-Agent'], 'test-UA');
      expect(headers['Accept-Encoding'], 'gzip');
    });

    test('declared casing is kept and no duplicate is added', () {
      final headers = unifiedTransferHeaders({'user-agent': 'declared'});
      expect(headers.length, 2);
      expect(headers['user-agent'], 'declared');
      expect(headers.containsKey('User-Agent'), isFalse);
      expect(headers['Accept-Encoding'], 'identity');
    });

    test('the defaults never carry a credential', () {
      final headers = unifiedTransferHeaders(const {});
      expect(headers.keys, isNot(contains('Cookie')));
      expect(headers.keys, isNot(contains('Authorization')));
    });
  });

  group('playback failures are logged as a type, never as a source', () {
    test('a platform error keeps only its code', () {
      final type = playbackFailureType(
        PlatformException(
          code: 'VideoError',
          message: 'Video player had error: '
              'https://sns-video-v27.xhscdn.com/stream/x.mp4?sign=secret',
        ),
      );
      expect(type, 'platform:VideoError');
      expect(type, isNot(contains('http')));
      expect(type, isNot(contains('secret')));
    });

    test('one of our own transfer codes is kept, a path is not', () {
      expect(
        playbackFailureType(const FileSystemException('PREVIEW_HTTP_FAILED')),
        'file:PREVIEW_HTTP_FAILED',
      );
      final withPath = playbackFailureType(
        const FileSystemException(
          'Cannot open file',
          '/storage/emulated/0/Pictures/EasySave/DflxolxpdHT_1.mp4',
        ),
      );
      expect(withPath, 'file:io');
    });

    test('a policy rejection is named by code and nothing else', () {
      final type = playbackFailureType(
        const MediaPolicyException('REQUEST_HOST_REJECTED', 'cdn.example'),
      );
      expect(type, 'policy:REQUEST_HOST_REJECTED');
      expect(type, isNot(contains('cdn.example')));
    });

    test('unknown errors fall back to the type name', () {
      expect(playbackFailureType(StateError('x')), 'StateError');
      expect(playbackFailureType(null), 'unknown');
    });
  });
}
