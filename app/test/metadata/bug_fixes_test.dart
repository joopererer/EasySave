// Copyright 2026 EasySave. All rights reserved.
// Tests for platform identifier mapping and timezone formatting fixes.

import 'package:flutter_test/flutter_test.dart';
import 'package:easysave/metadata/url_normalizer.dart';
import 'package:easysave/metadata/date_formatter.dart';
import 'package:easysave/metadata/metadata_service.dart';
import 'package:easysave/metadata/xmp_model.dart';

void main() {
  group('Platform Identifier Mapping', () {
    test('appPlatformToSpecPlatform maps xhs to xiaohongshu', () {
      expect(toSpecPlatform('xhs'), 'xiaohongshu');
    });

    test('appPlatformToSpecPlatform maps instagram correctly', () {
      expect(toSpecPlatform('instagram'), 'instagram');
    });

    test('appPlatformToSpecPlatform maps x correctly', () {
      expect(toSpecPlatform('x'), 'x');
    });

    test('toSpecPlatform handles spec names as input (idempotent)', () {
      expect(toSpecPlatform('xiaohongshu'), 'xiaohongshu');
      expect(toSpecPlatform('instagram'), 'instagram');
    });

    test('appPlatformToDisplayName maps xhs to 小红书', () {
      expect(platformDisplayName('xhs'), '小红书');
    });

    test('appPlatformToDisplayName maps xiaohongshu to 小红书', () {
      expect(platformDisplayName('xiaohongshu'), '小红书');
    });

    test('appPlatformToDisplayName maps instagram to Instagram', () {
      expect(platformDisplayName('instagram'), 'Instagram');
    });

    test('appPlatformToDisplayName maps x to X', () {
      expect(platformDisplayName('x'), 'X');
    });

    test('unknown platform returns itself', () {
      expect(toSpecPlatform('unknown'), 'unknown');
      expect(platformDisplayName('unknown'), 'unknown');
    });
  });

  group('ProvenanceBuilder with App Platform Identifiers', () {
    test('platform xhs is converted to xiaohongshu in XMP', () {
      final builder = ProvenanceBuilder(
        platform: 'xhs',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        authorName: '测试用户',
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.platform, 'xiaohongshu');
    });

    test('photoshop:Credit uses display name with xhs input', () {
      final builder = ProvenanceBuilder(
        platform: 'xhs',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        authorName: '测试用户',
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.credit, '测试用户 / 小红书');
    });

    test('platform instagram credit displays correctly', () {
      final builder = ProvenanceBuilder(
        platform: 'instagram',
        postId: 'abc123',
        postUrl: 'https://www.instagram.com/p/abc123',
        authorName: 'Test User',
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.credit, 'Test User / Instagram');
    });

    test('platform x credit displays correctly', () {
      final builder = ProvenanceBuilder(
        platform: 'x',
        postId: '1234567890',
        postUrl: 'https://x.com/user/status/1234567890',
        authorName: 'X User',
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.credit, 'X User / X');
    });
  });

  group('URL Normalization', () {
    test('xiaohongshu /discovery/item URLs normalized to /explore/', () {
      final builder = ProvenanceBuilder(
        platform: 'xhs',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/discovery/item/abc123?type=normal',
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.sourceUrl, 'https://www.xiaohongshu.com/explore/abc123');
    });

    test('X username/status URLs normalized to /i/status/', () {
      final builder = ProvenanceBuilder(
        platform: 'x',
        postId: '1234567890',
        postUrl: 'https://x.com/username/status/1234567890',
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.sourceUrl, 'https://x.com/i/status/1234567890');
    });

    test('tracking parameters are stripped', () {
      final builder = ProvenanceBuilder(
        platform: 'xhs',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123?utm_source=test&fbclid=abc&igsh=xyz',
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.sourceUrl, isNot(contains('utm_source')));
      expect(xmp.sourceUrl, isNot(contains('fbclid')));
      expect(xmp.sourceUrl, isNot(contains('igsh')));
    });
  });

  group('DateTime Timezone Formatting', () {
    test('formatDateTimeWithTimezone includes timezone offset', () {
      final dt = DateTime(2026, 10, 21, 2, 12, 48);
      final formatted = formatDateTimeWithTimezone(dt);

      // Should include timezone offset like +02:00 or -05:00
      expect(formatted, matches(RegExp(r'2026-10-21T02:12:48[+-]\d{2}:\d{2}')));
    });

    test('formatDateTimeUtc uses Z suffix for UTC', () {
      final dt = DateTime.utc(2026, 10, 21, 0, 0, 0);
      final formatted = formatDateTimeUtc(dt);

      expect(formatted, '2026-10-21T00:00:00Z');
    });

    test('XmpProvenance dates include timezone in toJson', () {
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'test',
        capturedAt: DateTime(2026, 10, 21, 2, 12, 48),
        capturedBy: 'EasySave/1.7.0',
        metadataDate: DateTime(2026, 10, 21, 2, 12, 49),
        publishedAt: DateTime(2026, 10, 20, 10, 30, 45),
      );

      final json = xmp.toJson();

      // capturedAt should have timezone
      expect(json['capturedAt'], matches(RegExp(r'2026-10-21T02:12:48[+-]\d{2}:\d{2}')));
      // metadataDate should have timezone
      expect(json['metadataDate'], matches(RegExp(r'2026-10-21T02:12:49[+-]\d{2}:\d{2}')));
      // publishedAt in source should have timezone
      final source = json['source'] as Map<String, dynamic>;
      expect(source['publishedAt'], matches(RegExp(r'2026-10-20T10:30:45[+-]\d{2}:\d{2}')));
    });

    test('XmpProvenance dates include timezone in toXmpJson', () {
      final xmp = XmpProvenance(
        schema: '0.1',
        assetId: 'test',
        capturedAt: DateTime(2026, 10, 21, 2, 12, 48),
        capturedBy: 'EasySave/1.7.0',
        metadataDate: DateTime(2026, 10, 21, 2, 12, 49),
      );

      final json = xmp.toXmpJson();

      // All prov:*Date fields should have timezone
      expect(json['prov:capturedAt'], matches(RegExp(r'2026-10-21T02:12:48[+-]\d{2}:\d{2}')));
      expect(json['xmp:MetadataDate'], matches(RegExp(r'2026-10-21T02:12:49[+-]\d{2}:\d{2}')));
    });
  });

  group('ProvenanceBuilder with authorId and publishedAt', () {
    test('authorId is passed through to XmpProvenance for non-X platforms', () {
      final builder = ProvenanceBuilder(
        platform: 'xhs',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        authorId: 'author123',
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.authorId, 'author123');
    });

    test('publishedAt is passed through to XmpProvenance', () {
      final publishedAt = DateTime(2026, 10, 20, 10, 30, 45);
      final builder = ProvenanceBuilder(
        platform: 'xhs',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        publishedAt: publishedAt,
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.publishedAt, publishedAt);
    });

    test('publishedAt in XMP output has timezone', () {
      final publishedAt = DateTime(2026, 10, 20, 10, 30, 45);
      final builder = ProvenanceBuilder(
        platform: 'xhs',
        postId: 'abc123',
        postUrl: 'https://www.xiaohongshu.com/explore/abc123',
        publishedAt: publishedAt,
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();
      final json = xmp.toXmpJson();

      expect(json['prov:publishedAt'], matches(RegExp(r'2026-10-20T10:30:45[+-]\d{2}:\d{2}')));
    });

    test('X platform skips non-numeric authorId (username)', () {
      final builder = ProvenanceBuilder(
        platform: 'x',
        postId: '123',
        postUrl: 'https://x.com/i/status/123',
        authorId: 'n8_AIart', // Username, not stable ID
        itemIndex: 1, // 1-based
        itemCount: 1,
      );

      final xmp = builder.build();

      expect(xmp.authorId, isNull, reason: 'X username should not be written as authorId');
    });
  });
}
