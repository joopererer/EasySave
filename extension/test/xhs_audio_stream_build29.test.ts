import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { moduleCall } from '../src/_parse_page';
import { audioStateOf, parseXhs, resolveVideoUrl, xhsStreamProbe } from '../src/xhs';
import sites from '../../config/sites.json';

afterEach(() => vi.unstubAllGlobals());

const entry = (codec: string, width: number, audio: Record<string, unknown>, path: string, streamType = 114) => ({
  videoCodec: codec, width, height: width * 16 / 9, streamType, avgBitrate: width * 1000,
  masterUrl: `http://sns-video-bd.xhscdn.com/stream/${path}.mp4`, ...audio,
});
const aac = { audioCodec: 'aac', audioChannels: 2, audioBitrate: 128000 };
const silent = { audioCodec: '', audioChannels: 0, audioBitrate: 0 };

describe('XHS audio-aware stream selection', () => {
  it('reads audio fields as yes / no / unknown', () => {
    expect(audioStateOf(aac)).toBe('yes');
    expect(audioStateOf({ audioChannels: 1 })).toBe('yes');
    expect(audioStateOf(silent)).toBe('no');
    expect(audioStateOf({ audioCodec: 'none' })).toBe('no');
    expect(audioStateOf({ videoCodec: 'h264' })).toBe('unknown');
  });

  it('picks the stream with audio when the highest quality has none', () => {
    const video = { media: { stream: {
      h265: [entry('hevc', 1080, silent, 'high-silent')],
      h264: [entry('h264', 720, aac, 'mid-aac')],
    } } };
    const resolved = resolveVideoUrl(video)!;
    expect(resolved.url).toBe('https://sns-video-bd.xhscdn.com/stream/mid-aac.mp4');
    expect(resolved.width).toBe(720);
    expect(resolved.alternates).toBeUndefined();
  });

  it('ranks a stream with declared audio above the original upload', () => {
    const video = { consumer: { originVideoKey: 'pre_post/origin' }, media: { stream: {
      h264: [entry('h264', 720, aac, 'mid-aac')],
    } } };
    expect(resolveVideoUrl(video)).toEqual({
      url: 'https://sns-video-bd.xhscdn.com/stream/mid-aac.mp4', width: 720, height: 1280,
      alternates: ['https://sns-video-bd.xhscdn.com/pre_post/origin'],
    });
  });

  it('keeps the original upload first when no stream declares audio', () => {
    const video = { consumer: { originVideoKey: 'pre_post/origin' }, media: { stream: {
      h265: [entry('hevc', 1080, {}, 'high-unknown')],
      h264: [entry('h264', 720, silent, 'mid-silent')],
    } } };
    expect(resolveVideoUrl(video)).toEqual({
      url: 'https://sns-video-bd.xhscdn.com/pre_post/origin',
      alternates: ['https://sns-video-bd.xhscdn.com/stream/high-unknown.mp4'],
    });
  });

  it('never prefers a watermarked rendition for its audio', () => {
    const video = { media: { stream: {
      h264: [entry('h264', 1080, aac, 'watermarked', 259), entry('h264', 720, {}, 'clean')],
    } } };
    expect(resolveVideoUrl(video)!.url).toBe('https://sns-video-bd.xhscdn.com/stream/clean.mp4');
  });

  it('parses the additive fixture with an audio-bearing primary', () => {
    const html = readFileSync(new URL('../../spec/fixtures/xhs/build29_video_audio_stream.html', import.meta.url), 'utf8');
    const expected = JSON.parse(readFileSync(new URL('../../spec/fixtures/xhs/build29_video_audio_stream.expected.json', import.meta.url), 'utf8'));
    expect(parseXhs(html, `https://www.xiaohongshu.com/explore/${expected.id}`)).toEqual({ ok: true, data: expected });
  });
});

describe('XhsStreamProbe', () => {
  it('lists codec, size, bitrate and audio field names of each candidate', () => {
    const video = { consumer: { originVideoKey: 'pre_post/origin' }, media: { stream: {
      h265: [entry('hevc', 1080, silent, 'high-silent')],
      h264: [entry('h264', 720, aac, 'mid-aac')],
    } } };
    expect(xhsStreamProbe(video)).toEqual([
      { bucket: 'origin', width: 0, height: 0, bitrate: 0, audio: 'unknown', audioFields: [], watermarked: false, selected: false },
      { bucket: 'media.h265', streamType: 114, codec: 'hevc', width: 1080, height: 1920, bitrate: 1080000,
        audio: 'no', audioCodec: '', audioChannels: 0, audioBitrate: 0,
        audioFields: ['audioBitrate', 'audioChannels', 'audioCodec'], watermarked: false, selected: false },
      { bucket: 'media.h264', streamType: 114, codec: 'h264', width: 720, height: 1280, bitrate: 720000,
        audio: 'yes', audioCodec: 'aac', audioChannels: 2, audioBitrate: 128000,
        audioFields: ['audioBitrate', 'audioChannels', 'audioCodec'], watermarked: false, selected: true },
    ]);
    expect(JSON.stringify(xhsStreamProbe(video))).not.toContain('http');
  });

  it('is exposed as the xhs probe hook over the page state', () => {
    const html = readFileSync(new URL('../../spec/fixtures/xhs/build29_video_audio_stream.html', import.meta.url), 'utf8');
    const state = JSON.parse(/__INITIAL_STATE__=(.*)<\/script>/.exec(html)![1]);
    vi.stubGlobal('window', { __INITIAL_STATE__: state });
    const site = sites.find((s) => s.id === 'xhs');
    const value = JSON.parse(moduleCall('xhs', 'probe', {
      url: 'https://www.xiaohongshu.com/explore/6720aa0b000000001b0299a1', site,
    })).value;
    expect(value.tag).toBe('XhsStreamProbe');
    expect(value.streams.filter((s: any) => s.selected).map((s: any) => s.bucket)).toEqual(['media.h264']);
  });
});
