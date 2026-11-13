// Copyright 2026 EasySave. All rights reserved.
// v1.11 batch 1: the `candidate=` field of the V16DL log lines.
//
// Build 48 logged impossible values such as `candidate=3/1` and
// `candidate=11/4`: the numerator was the retry counter (which keeps growing
// across backoff retries) over the number of candidates. The numerator is now
// the candidate's own position, and a shared helper keeps the four log sites
// from drifting apart again.

import 'package:easysave/services/download_manager.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadJob _job(int urls) => DownloadJob(
      key: 'job',
      label: 'job',
      filename: 'file.jpg',
      urls: [for (var i = 0; i < urls; i++) 'https://example.com/$i.jpg'],
      isImage: true,
      itemIndex: 0,
    );

void main() {
  group('candidate position', () {
    test('a single candidate never exceeds its total', () {
      final job = _job(1)..attempts = 11;
      expect(DownloadManager.candidateProgressLabel(job), '1/1');
      expect(job.attempts, 11, reason: 'attempts stay a separate counter');
    });

    test('backoff retries do not move the candidate forward', () {
      final job = _job(4)
        ..attempts = 3
        ..candidateRetryCount = 2;
      expect(DownloadManager.candidateProgressLabel(job), '1/4');
    });

    test('a candidate switch advances the position', () {
      final job = _job(4)..candidateIndex = 2;
      expect(DownloadManager.candidateProgressLabel(job), '3/4');
    });

    test('a stale candidate index is clamped to the last candidate', () {
      final job = _job(4)
        ..candidateIndex = 9
        ..attempts = 11;
      expect(DownloadManager.candidateIndexOf(job), 3);
      expect(DownloadManager.candidateProgressLabel(job), '4/4');
    });

    test('a negative index falls back to the first candidate', () {
      final job = _job(3)..candidateIndex = -1;
      expect(DownloadManager.candidateIndexOf(job), 0);
      expect(DownloadManager.candidateProgressLabel(job), '1/3');
    });

    test('the label can never show a numerator larger than the total', () {
      for (var urls = 1; urls <= 5; urls++) {
        for (final index in [-2, 0, 1, 3, 7]) {
          for (final attempts in [0, 1, 3, 11]) {
            final job = _job(urls)
              ..candidateIndex = index
              ..attempts = attempts;
            final label = DownloadManager.candidateProgressLabel(job);
            final parts = label.split('/');
            expect(parts, hasLength(2));
            final numerator = int.parse(parts.first);
            final total = int.parse(parts.last);
            expect(numerator, inInclusiveRange(1, total));
            expect(total, urls);
          }
        }
      }
    });
  });
}
