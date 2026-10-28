import { readFileSync } from 'node:fs';
import { afterEach, expect, it, vi } from 'vitest';
import { parse } from '../src/index';
import { parsePage } from '../src/_parse_page';

afterEach(() => vi.unstubAllGlobals());
for (const [file, id, count, type] of [
  ['mobile-video.html', '7698442078988061984', 1, 'video'],
  ['mobile-photo.html', '7688352288666045718', 7, 'image'],
] as const) {
  const html = readFileSync(new URL(`../../spec/fixtures/tiktok/${file}`, import.meta.url), 'utf8');
  const root = JSON.parse(/<script[^>]*>([\s\S]*?)<\/script>/.exec(html)![1]);
  const url = `https://www.tiktok.com/@/video/${id}`;
  it(`parses the actual mobile response: ${file}`, () => {
    const result = parse(html, url);
    expect(result.ok).toBe(true);
    if (!result.ok) throw new Error('mobile parse failed');
    expect(result.data.id).toBe(id);
    expect(result.data.items).toHaveLength(count);
    expect(result.data.items.every(item => item.type === type)).toBe(true);
    const download = root.__DEFAULT_SCOPE__['webapp.reflow.video.detail'].itemInfo.itemStruct.video?.downloadAddr;
    if (download) expect(JSON.stringify(result)).not.toContain(download);
    expect(html).not.toMatch(/cookie|csrfToken|encryptedWebid/i);
    for (const match of html.matchAll(/https:\/\/[^"\s]+/g)) {
      const media = new URL(match[0]);
      expect(media.hostname).toBe('media.example');
      media.searchParams.forEach(value => expect(value).toBe('FAKE'));
    }
  });
  it(`reads hydrated window state after script removal: ${file}`, () => {
    vi.stubGlobal('window', { location: { href: url }, __UNIVERSAL_DATA_FOR_REHYDRATION__: root });
    vi.stubGlobal('document', { documentElement: { outerHTML: '<html></html>' } });
    expect(JSON.parse(parsePage())).toEqual(JSON.parse(JSON.stringify(parse(html, url))));
  });
  it(`ignores an empty desktop route when matching mobile state exists: ${file}`, () => {
    const mixed = structuredClone(root);
    mixed.__DEFAULT_SCOPE__['webapp.video-detail'] = { statusCode: 0, itemInfo: {} };
    expect(parse(JSON.stringify(mixed), url)).toEqual(parse(html, url));
  });
}
it('classifies mobile statusMessage without requiring desktop statusMsg', () => {
  expect(parse(JSON.stringify({ __DEFAULT_SCOPE__: { 'webapp.reflow.video.detail': {
    statusCode: 99, statusMessage: 'post deleted',
  } } }), 'https://www.tiktok.com/@/video/123')).toMatchObject({ ok: false, error: { code: 'DELETED' } });
});
