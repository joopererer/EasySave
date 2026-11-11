import { describe, it, expect } from 'vitest';
import { tiktokExpiresAt } from '../src/tiktok';
import { withMediaResources } from '../src/media-resources';
import { moduleCall } from '../src/_parse_page';
import sites from '../../config/sites.json';
import { readFileSync } from 'node:fs';

const site = sites.find(s => s.id === 'tiktok')!;
describe('v2 per-resource request declarations', () => {
  it('keeps known expiry parsing in the TikTok module, including duplicate fields', () => {
    expect(tiktokExpiresAt('https://v.tiktok.com/a?expire=3000&X-Expires=2000&expire=4000'))
      .toBe('1970-01-01T00:33:20.000Z');
    expect(tiktokExpiresAt('https://v.tiktok.com/a?expire=0')).toBe('1970-01-01T00:00:00.000Z');
    for (const query of ['expire=FAKE', 'expires=1', 'expire=-1', 'expire=1.2', 'expire=999999999999999999999']) {
      expect(tiktokExpiresAt('https://v.tiktok.com/a?' + query)).toBeUndefined();
    }
    expect(tiktokExpiresAt('bad URL')).toBeUndefined();
  });
  it('declares image, motion, poster and each fallback independently', () => {
    const before = { ok: true, data: { items: [{
      type: 'image', url: 'https://p.tiktokcdn.com/a?x-expires=3000',
      videoUrl: 'https://v.tiktok.com/m?expire=2000',
      posterUrl: 'https://p.tiktokcdn.com/poster',
      fallbacks: ['https://p.tiktokcdn-eu.com/b?x-expires=4000'],
    }] } };
    const result = withMediaResources(before, site, tiktokExpiresAt);
    const r = result.data.items[0].resources;
    expect(r.map((v: any) => v.role)).toEqual(['image', 'motion', 'poster', 'fallback']);
    expect(r.map((v: any) => v.request.expiresAt)).toEqual([
      '1970-01-01T00:50:00.000Z', '1970-01-01T00:33:20.000Z',
      undefined, '1970-01-01T01:06:40.000Z',
    ]);
    expect(r[0].request).toMatchObject({ cookieDomains: [], transport: 'background', resumable: true });
    expect(r[1].request).toMatchObject({ cookieDomains: ['tiktok.com'], transport: 'session', resumable: false });
    expect(r[3].fallbackFor).toBe('image');
    expect(before.data.items[0]).not.toHaveProperty('resources');
    expect(JSON.stringify(r)).not.toContain('"Cookie"');
  });
  it('maps cover-in-url video items and duplicate videoUrl without losing candidates', () => {
    const items = [
      { type: 'video', url: 'https://cdn/cover', videoUrl: 'https://cdn/video', fallbacks: ['https://cdn/backup'] },
      { type: 'video', url: 'https://cdn/video', videoUrl: 'https://cdn/video' },
    ];
    const result = withMediaResources({ ok: true, data: { items } }, site);
    expect(result.data.items[0].resources.map((r: any) => r.role)).toEqual(['poster', 'video', 'fallback']);
    expect(result.data.items[1].resources.map((r: any) => r.role)).toEqual(['video']);
    // Other modules do not interpret arbitrary query fields.
    expect(withMediaResources({ ok: true, data: { items: [{ type: 'image', url: 'https://cdn/a?expire=1' }] } }, site)
      .data.items[0].resources[0].request.expiresAt).toBeUndefined();
  });
  it('attaches requirements to the actual signed-module parse result', () => {
    const input = readFileSync(new URL('../../spec/fixtures/tiktok/video.html', import.meta.url), 'utf8');
    const struct = JSON.parse(/<script[^>]*>([\s\S]*?)<\/script>/.exec(input)![1])
      .__DEFAULT_SCOPE__['webapp.video-detail'].itemInfo.itemStruct;
    const result = JSON.parse(moduleCall('tiktok', 'parse', {
      input, url: 'https://www.tiktok.com/@/video/' + struct.id, site,
    })).value;
    for (const item of result.data.items) {
      expect(item.resources.length).toBeGreaterThan(0);
      for (const r of item.resources) expect(r.request).toHaveProperty('headers');
    }
  });
});
