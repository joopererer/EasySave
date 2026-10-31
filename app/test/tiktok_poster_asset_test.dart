// Copyright 2026 EasySave. All rights reserved.
//
// The TikTok preview cover is produced by the parser bundle, so the App-side
// guard is: the shipped bundle really declares a poster, the generated version
// matches spec/PARSER_VERSION, and a poster URL survives into MediaItem for the
// preview/request policy to use.

import 'dart:io';

import 'package:easysave/core/models.dart';
import 'package:easysave/generated/parser_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the bundled parser declares a TikTok poster', () {
    final bundle = File('assets/parser/parser.js').readAsStringSync();
    expect(bundle, contains('selectTiktokPoster'));
    expect(bundle, contains('posterUrl'));
    // The cover fields seen in the real payload must be read by the module.
    expect(bundle, contains('originCover'));
    expect(bundle, contains('dynamicCover'));
  });

  test('generated parser version matches spec/PARSER_VERSION', () {
    final spec = File('../spec/PARSER_VERSION').readAsStringSync().trim();
    expect(spec, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    expect(ParserVersion.version, spec);
  });

  test('a poster URL round-trips through MediaItem', () {
    const poster = 'https://p16-common-sign.tiktokcdn-eu.com/cover~tplv.jpeg';
    final item = MediaItem.fromJson({
      'type': 'video',
      'url': 'https://v16-webapp.tiktokcdn.com/play.mp4',
      'videoUrl': 'https://v16-webapp.tiktokcdn.com/play.mp4',
      'posterUrl': poster,
    });
    expect(item.posterUrl, poster);
    expect(item.toJson()['posterUrl'], poster);
    // The poster never replaces the media address.
    expect(item.url, contains('play.mp4'));
  });
}
