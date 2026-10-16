import 'dart:convert';
import 'dart:io';

import 'package:easysave/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixturesDir = Directory(
    Directory('../spec/fixtures').existsSync()
        ? '../spec/fixtures'
        : 'spec/fixtures',
  );

  group('Parser JSON -> Dart unified model conversion from fixtures', () {
    for (final platform in ['xhs', 'instagram', 'x']) {
      final dir = Directory('${fixturesDir.path}/$platform');

      if (!dir.existsSync()) continue;

      final jsonFiles = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.expected.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      for (final file in jsonFiles) {
        final filename = file.uri.pathSegments.last;
        test('$platform/$filename converts correctly', () {
          final content = file.readAsStringSync();
          final dynamic decoded = jsonDecode(content);
          expect(decoded, isA<Map<String, dynamic>>());
          final map = decoded as Map<String, dynamic>;

          if (map.containsKey('error')) {
            // Failure case fixture
            final result = ParseResult.fromJson({
              'ok': false,
              'error': map['error'],
            });
            expect(result.ok, isFalse);
            expect(result.data, isNull);
            final expectedError = map['error'] as Map<String, dynamic>;
            expect(result.error?.code, equals(expectedError['code']));
          } else {
            // Success case fixture
            final post = ParsedPost.fromJson(map);
            expect(post.toJson(), equals(map));

            final result = ParseResult.fromJson({
              'ok': true,
              'data': map,
            });
            expect(result.ok, isTrue);
            expect(result.error, isNull);
            expect(result.data?.toJson(), equals(map));
          }
        });
      }
    }
  });

  group('Error JSON conversion and edge cases', () {
    test('converts error JSON with code and message', () {
      final json = {
        'ok': false,
        'error': {
          'code': ParseErrorCode.loginRequired,
          'message': 'Need login to view post',
        },
      };
      final result = ParseResult.fromJson(json);
      expect(result.ok, isFalse);
      expect(result.data, isNull);
      expect(result.error?.code, equals(ParseErrorCode.loginRequired));
      expect(result.error?.message, equals('Need login to view post'));
    });

    test('converts error JSON missing code/message gracefully', () {
      final json = {'ok': false, 'error': <String, dynamic>{}};
      final result = ParseResult.fromJson(json);
      expect(result.ok, isFalse);
      expect(result.error?.code, equals(ParseErrorCode.invalidPage));
      expect(result.error?.message, equals('解析失败'));
    });

    test('converts error JSON without error map', () {
      final json = {'ok': false};
      final result = ParseResult.fromJson(json);
      expect(result.ok, isFalse);
      expect(result.error?.code, equals(ParseErrorCode.invalidPage));
    });

    test('converts success JSON with null data', () {
      final json = {'ok': true, 'data': null};
      final result = ParseResult.fromJson(json);
      expect(result.ok, isTrue);
      expect(result.data, isNull);
    });

    test('converts post with minimal fields and optional omissions', () {
      final json = {
        'platform': 'xhs',
        'id': '123',
        'url': 'https://example.com/123',
        'items': <dynamic>[],
      };
      final post = ParsedPost.fromJson(json);
      expect(post.platform, equals('xhs'));
      expect(post.id, equals('123'));
      expect(post.author.name, isNull);
      expect(post.author.id, isNull);
      expect(post.title, isNull);
      expect(post.caption, isNull);
      expect(post.publishedAt, isNull);
      expect(post.items, isEmpty);
    });

    test('converts media item with duration and fallbacks', () {
      final itemJson = {
        'type': 'video',
        'url': 'https://example.com/v.mp4',
        'videoUrl': 'https://example.com/v.mp4',
        'posterUrl': 'https://example.com/poster.jpg',
        'width': 1080,
        'height': 1920,
        'duration': 15.5,
        'fallbacks': ['https://example.com/fb1.mp4'],
      };
      final item = MediaItem.fromJson(itemJson);
      expect(item.type, equals('video'));
      expect(item.duration, equals(15.5));
      expect(item.fallbacks, equals(['https://example.com/fb1.mp4']));
      expect(item.posterUrl, equals('https://example.com/poster.jpg'));
      expect(item.toJson(), equals(itemJson));
    });

    test('MediaItem defaults to image type when omitted', () {
      final item = MediaItem.fromJson({'url': 'https://example.com/i.jpg'});
      expect(item.type, equals('image'));
      expect(item.url, equals('https://example.com/i.jpg'));
      expect(item.fallbacks, isEmpty);
      expect(item.isGif, isNull);
      expect(item.toJson().containsKey('isGif'), isFalse);
    });

    test('MediaItem distinguishes GIF video from normal video', () {
      final normalVideo = MediaItem.fromJson({
        'type': 'video',
        'url': 'https://example.com/v.mp4',
      });
      expect(normalVideo.isGif, isNull);
      expect(normalVideo.toJson().containsKey('isGif'), isFalse);

      final gifVideo = MediaItem.fromJson({
        'type': 'video',
        'isGif': true,
        'url': 'https://example.com/g.mp4',
      });
      expect(gifVideo.isGif, isTrue);
      expect(gifVideo.toJson()['isGif'], isTrue);
    });
  });
}

