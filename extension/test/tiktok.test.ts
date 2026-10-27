import { describe, expect, it } from 'vitest';
import { extractTiktokPostId, isTiktokLink, parseTiktok, selectTiktokVideo } from '../src/tiktok';

const id = '1234567890123456789';
const page = `https://www.tiktok.com/@user/video/${id}`;
const playback = 'https://media.example/play.mp4';
const watermark = 'https://media.example/watermark.mp4';
function payload(item: Record<string, unknown>, statusCode = 0, statusMsg = '') {
  return JSON.stringify({ __DEFAULT_SCOPE__: { 'webapp.video-detail': {
    statusCode, statusMsg, itemInfo: { itemStruct: item },
  } } });
}
const post = { id, desc: 'caption', createTime: 1700000000,
  author: { nickname: 'Display name', id: '99887766', uniqueId: 'mutable_name' },
  video: { playAddr: playback, downloadAddr: watermark } };

describe('TikTok links and post mapping', () => {
  it.each(['www', 'm'])('accepts %s host and all required paths', host => {
    for (const path of [`/@user/video/${id}`, `/@user/photo/${id}`, `/v/${id}.html`, `/share/video/${id}`]) {
      expect(extractTiktokPostId(`https://${host}.tiktok.com${path}?tracking=FAKE`)).toBe(id);
    }
  });
  it.each(['vm', 'vt'])('recognizes %s short links without inventing an ID', host => {
    const url = `https://${host}.tiktok.com/abc/`;
    expect(isTiktokLink(url)).toBe(true);
    expect(extractTiktokPostId(url)).toBeUndefined();
  });
  it.each(['https://tiktok.com.evil/@user/video/123', 'https://evil/?url=https://www.tiktok.com/@user/video/123',
    'https://www.tiktok.com/@user', 'javascript://www.tiktok.com/@user/video/123'])('rejects %s', url => {
    expect(isTiktokLink(url)).toBe(false);
  });
  it('maps numeric author ID, caption, timestamp and canonical URL from HTML', () => {
    const result = parseTiktok(`<script type="application/json" id="__UNIVERSAL_DATA_FOR_REHYDRATION__">${payload(post)}</script>`, page);
    expect(result).toMatchObject({ ok: true, data: { platform: 'tiktok', id,
      url: `https://www.tiktok.com/@/video/${id}`, author: { name: 'Display name', id: '99887766' },
      caption: 'caption', publishedAt: '2023-11-14T22:13:20Z' } });
  });
  it('never substitutes uniqueId for a missing or nonnumeric author ID', () => {
    const result = parseTiktok(payload({ ...post, author: { uniqueId: 'handle', id: 'handle' } }), page);
    expect(result.ok && result.data.author.id).toBeUndefined();
  });
  it.each([
    [10216, '', 'PRIVATE'], [10222, '', 'PRIVATE'], [10204, '', 'REGION_RESTRICTED'],
    [123, 'post deleted', 'DELETED'], [123, 'not available in your country', 'REGION_RESTRICTED'],
    [123, '', 'UNKNOWN'], [0, '', 'UNKNOWN'],
  ])('classifies status %s / %s', (status, message, code) => {
    expect(parseTiktok(payload({}, Number(status), String(message)), page)).toMatchObject({ ok: false, error: { code } });
  });
  it('rejects a nonzero status even when itemStruct exists', () => {
    expect(parseTiktok(payload(post, 10216), page)).toMatchObject({ ok: false, error: { code: 'PRIVATE' } });
  });
  it('rejects malformed JSON, missing data and a different post', () => {
    for (const input of ['<html></html>', '{', '{}', payload({ ...post, id: '9' })]) {
      expect(parseTiktok(input, page)).toMatchObject({ ok: false, error: { code: 'UNKNOWN' } });
    }
  });
});

describe('TikTok media selection', () => {
  const variant = (width: number, height: number, Bitrate: number, url: string) => ({
    Bitrate, PlayAddr: { Width: width, Height: height, UrlList: [url] },
  });
  it('ranks resolution before bitrate and bitrate when resolutions tie', () => {
    const result = selectTiktokVideo({ bitrateInfo: [
      variant(540, 960, 99999, 'https://media.example/low'),
      variant(1080, 1920, 100, 'https://media.example/high'),
      variant(1080, 1920, 200, 'https://media.example/best'),
    ], playAddr: playback, downloadAddr: watermark });
    expect(result?.videoUrl).toBe('https://media.example/best');
    expect(result?.fallbacks).toEqual(['https://media.example/high', 'https://media.example/low', playback]);
    expect(JSON.stringify(result)).not.toContain(watermark);
  });
  it.each([
    { playAddr: playback },
    { bitrateInfo: [{ PlayAddr: { UrlList: ['invalid'] } }], playAddr: playback },
    { PlayAddrStruct: { UrlList: [playback] } },
    { playAddr: 'javascript:bad', PlayAddrStruct: { UrlList: [playback] } },
  ])('uses playback fallbacks without selecting downloadAddr: %j', video => {
    const result = selectTiktokVideo({ ...video, downloadAddr: watermark });
    expect(result?.videoUrl).toBe(playback);
    expect(JSON.stringify(result)).not.toContain(watermark);
  });
  it('fails when only downloadAddr is available', () => {
    expect(selectTiktokVideo({ downloadAddr: watermark })).toBeUndefined();
    expect(parseTiktok(payload({ ...post, video: { downloadAddr: watermark } }), page).ok).toBe(false);
  });
  it('maps image title and ordered fallback URLs, excluding cover, music and video', () => {
    const result = parseTiktok(payload({ ...post, imagePost: { title: 'Album title',
      cover: { urlList: ['https://media.example/cover'] },
      images: [{ imageURL: { urlList: ['https://media.example/1', 'https://media.example/2'] } }],
    }, music: { playUrl: 'https://media.example/music' } }), page.replace('/video/', '/photo/'));
    expect(result).toMatchObject({ ok: true, data: { title: 'Album title',
      url: `https://www.tiktok.com/@/video/${id}`,
      items: [{ type: 'image', url: 'https://media.example/1', fallbacks: ['https://media.example/2'] }] } });
    expect(JSON.stringify(result)).not.toMatch(/watermark|cover|music|play\.mp4/);
  });
});
