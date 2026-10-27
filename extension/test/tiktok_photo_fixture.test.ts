import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { parse } from '../src/index';
import { parse as parseBundle } from '../src/_parse_page';

const fixture = readFileSync(new URL('../../spec/fixtures/tiktok/photo.html', import.meta.url), 'utf8');
const root = JSON.parse(/<script[^>]*>([\s\S]*?)<\/script>/.exec(fixture)![1]);
const source = root.__DEFAULT_SCOPE__['webapp.video-detail'].itemInfo.itemStruct;
const page = `https://www.tiktok.com/@/video/${source.id}`;

describe('real canonical TikTok photo page', () => {
  it('both shared parser entry points return all seven images and numeric authorId', () => {
    const result = parse(fixture, page);
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error('fixture did not parse');
    expect(result.data.platform).toBe('tiktok');
    expect(result.data.url).toBe(page);
    expect(result.data.author.id).toMatch(/^\d+$/);
    expect(result.data.items).toHaveLength(7);
    expect(JSON.parse(parseBundle(fixture, page))).toEqual(JSON.parse(JSON.stringify(result)));
  });

  it('keeps every urlList in order, without video, cover or background audio', () => {
    const result = parse(fixture, page);
    if (!result.ok || result.data.platform !== 'tiktok') throw new Error('fixture did not parse as TikTok');
    result.data.items.forEach((item, index) => {
      expect(item.type).toBe('image');
      expect(item.videoUrl).toBeUndefined();
      expect([item.url, ...item.fallbacks ?? []]).toEqual(source.imagePost.images[index].imageURL.urlList);
      expect(item.fallbacks).toHaveLength(1);
    });
  });

  it('contains only minimal post JSON and unusable sanitized media addresses', () => {
    expect(Object.keys(root.__DEFAULT_SCOPE__)).toEqual(['webapp.video-detail']);
    expect(fixture).not.toMatch(/cookie|csrfToken|encryptedWebid|downloadAddr|music|cover/i);
    source.imagePost.images.forEach((image: { imageURL: { urlList: string[] } }) => {
      image.imageURL.urlList.forEach(raw => {
        const url = new URL(raw);
        expect(url.hostname).toBe('media.example');
        expect(url.pathname).toMatch(/^\/FAKE_\d+\.jpg$/);
        url.searchParams.forEach(value => expect(value).toBe('FAKE'));
      });
    });
  });
});
