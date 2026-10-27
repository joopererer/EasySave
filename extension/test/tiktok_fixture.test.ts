import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { parse } from '../src/index';
import { parse as parseBundle } from '../src/_parse_page';

const fixture = readFileSync(new URL('../../spec/fixtures/tiktok/video.html', import.meta.url), 'utf8');
const root = JSON.parse(/<script[^>]*>([\s\S]*?)<\/script>/.exec(fixture)![1]);
const source = root.__DEFAULT_SCOPE__['webapp.video-detail'].itemInfo.itemStruct;
const page = `https://www.tiktok.com/@/video/${source.id}`;

describe('minimal real TikTok video fixture', () => {
  it('dispatches through both public parser entry points', () => {
    const result = parse(fixture, page);
    expect(result).toMatchObject({ ok: true, data: { platform: 'tiktok', id: source.id,
      author: { id: source.author.id, name: source.author.nickname },
      items: [{ type: 'video', width: 1080, height: 1920,
        videoUrl: source.video.bitrateInfo[0].PlayAddr.UrlList[0] }] } });
    expect(JSON.parse(parseBundle(fixture, page))).toEqual(JSON.parse(JSON.stringify(result)));
    expect(JSON.stringify(result)).not.toContain(source.video.downloadAddr);
  });
  it('contains no cookies, session contexts or usable signed addresses', () => {
    expect(fixture).not.toMatch(/cookie|webapp\.app-context|webapp\.biz-context|csrfToken|encryptedWebid/i);
    function check(value: unknown): void {
      if (Array.isArray(value)) value.forEach(check);
      else if (value && typeof value === 'object') Object.values(value).forEach(check);
      else if (typeof value === 'string' && value.startsWith('https://')) {
        const url = new URL(value);
        expect(url.hostname).toBe('media.example');
        expect(url.pathname).toMatch(/^\/FAKE_\d+\.mp4$/);
        url.searchParams.forEach(v => expect(v).toBe('FAKE'));
      }
    }
    check(root);
  });
});
