import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/error_copy.dart';
import 'package:easysave/core/models.dart';
import 'package:easysave/services/auth.dart';
import 'package:easysave/services/parse_service.dart';
import 'package:easysave/services/site_registry.dart';
import 'package:flutter_test/flutter_test.dart';

SiteDefinition _site(String id) {
  final config = jsonDecode(File('../config/sites.json').readAsStringSync());
  final sites = (config is Map ? config['sites'] : config) as List;
  return SiteDefinition(
    Map<String, dynamic>.from(sites.firstWhere((site) => site['id'] == id)),
  );
}

Map<String, Object?> _guestError(String code) => {
  'ok': false,
  'error': {'code': code, 'message': 'guest'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const post = 'https://x.com/KPKP996/status/2118566677374022101';

  group('logged-in entry page decision', () {
    final x = _site('x');

    test('restricted guest answers go to the logged-in X post page', () {
      for (final code in [
        ParseErrorCode.loginRequired,
        ParseErrorCode.ageRestricted,
        ParseErrorCode.protectedAccount,
        ParseErrorCode.privateOrUnavailable,
      ]) {
        expect(
          sessionEntryUrl(x, post, _guestError(code)),
          'https://x.com/i/status/2118566677374022101',
          reason: code,
        );
      }
    });

    test('successful or unrelated guest answers keep the guest result', () {
      expect(sessionEntryUrl(x, post, {'ok': true, 'data': {}}), isNull);
      expect(sessionEntryUrl(x, post, _guestError('INVALID_PAGE')), isNull);
      expect(sessionEntryUrl(x, post, _guestError('TIMEOUT')), isNull);
      expect(sessionEntryUrl(x, post, null), isNull);
    });

    test('sites without an entry page and foreign entry hosts never retry', () {
      expect(
        sessionEntryUrl(_site('instagram'), post, _guestError('LOGIN_REQUIRED')),
        isNull,
      );
      final foreign = SiteDefinition({
        ...x.data,
        'load': {...x.load, 'entryTemplate': 'https://evil.example/{id}'},
      });
      expect(sessionEntryUrl(foreign, post, _guestError('LOGIN_REQUIRED')), isNull);
    });
  });

  group('XLogin cookie state', () {
    final x = _site('x');
    tearDown(() => cookieNamesReaderForTesting = null);

    test('valid only when a configured session cookie name is present', () async {
      cookieNamesReaderForTesting = (_) async => ['guest_id', 'auth_token', 'ct0'];
      expect(await sessionCookieState(x, entry: 'test'), SessionStatus.valid);
      cookieNamesReaderForTesting = (_) async => ['guest_id', 'ct0'];
      expect(await sessionCookieState(x, entry: 'test'), SessionStatus.invalid);
      cookieNamesReaderForTesting = (_) async => throw StateError('store');
      expect(await sessionCookieState(x, entry: 'test'), SessionStatus.unknown);
    });
  });

  group('parser probe log lines', () {
    test('XProbe keeps type names, reason and 40 sanitized tombstone chars', () {
      final lines = formatParserProbe({
        'tag': 'XProbe',
        'source': 'graphql',
        'shape': 'tombstone',
        'typename': 'TweetTombstone',
        'tombstone': 'Age-restricted adult content. This conte',
        'fields': ['__typename', 'tombstone'],
      });
      expect(lines, [
        (
          'XProbe',
          'source=graphql shape=tombstone typename=TweetTombstone wrapped=0 '
              'reason=- tombstone="Age-restricted adult content. This conte" '
              'fields=__typename|tombstone mediaCount=-',
        ),
      ]);
    });

    test('free text and URLs never reach the log', () {
      final lines = formatParserProbe({
        'tag': 'XProbe',
        'source': 'syndication',
        'shape': 'tweet',
        'typename': 'https://x.com/a?b=c',
        'tombstone': 'see https://t.co/x?token=secret\nnext',
        'fields': ['ok', 'a b'],
      });
      final line = lines.single.$2;
      expect(line, isNot(contains('https://')));
      expect(line, isNot(contains('token=')));
      expect(line, isNot(contains('\n')));
      expect(line, contains('typename=x'));
      expect(formatParserProbe({'tag': 'Other', 'x': 1}), isEmpty);
    });

    test('XhsStreamProbe lists one line per candidate', () {
      final lines = formatParserProbe({
        'tag': 'XhsStreamProbe',
        'streams': [
          {
            'bucket': 'media.h265', 'streamType': 115, 'codec': 'hevc',
            'width': 1080, 'height': 1920, 'bitrate': 2400000, 'audio': 'no',
            'audioCodec': '', 'audioChannels': 0, 'audioBitrate': 0,
            'audioFields': ['audioBitrate', 'audioChannels', 'audioCodec'],
            'watermarked': false, 'selected': false,
          },
          {
            'bucket': 'media.h264', 'codec': 'h264', 'width': 720,
            'height': 1280, 'bitrate': 1200000, 'audio': 'yes',
            'audioCodec': 'aac', 'audioFields': ['audioCodec'],
            'watermarked': false, 'selected': true,
          },
        ],
      });
      expect(lines.map((line) => line.$1), ['XhsStreamProbe', 'XhsStreamProbe']);
      expect(
        lines.first.$2,
        'candidate=1/2 bucket=media.h265 streamType=115 codec=hevc '
        'size=1080x1920 bitrate=2400000 audio=no audioCodec= audioChannels=0 '
        'audioBitrate=0 audioFields=audioBitrate|audioChannels|audioCodec '
        'watermarked=0 selected=0',
      );
      expect(lines.last.$2, contains('audio=yes audioCodec=aac'));
      expect(lines.last.$2, contains('selected=1'));
      expect(formatParserProbe({'tag': 'XhsStreamProbe', 'streams': []}), isEmpty);
    });
  });

  test('every X access code has App copy and an action', () {
    expect(errorCopyFor(ParseErrorCode.ageNotSet).message, contains('出生日期'));
    expect(errorCopyFor(ParseErrorCode.ageRestricted).action, ErrorAction.goLogin);
    expect(errorCopyFor(ParseErrorCode.protectedAccount).message, contains('受保护'));
  });
}
