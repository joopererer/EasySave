// TikTok preview cover (v1.10, build 12 device round).
//
// The module never declared a poster, so the preview had nothing to fetch and
// CoverImage fell through to its error state. These checks pin the cover fields
// that exist in the real payload (video.originCover / cover / dynamicCover and
// imagePost.cover) and that the hosts those URLs come from are authorised by
// the manifest's mediaHosts.

import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { selectTiktokPoster } from '../src/tiktok';
import { moduleCall } from '../src/_parse_page';
import sites from '../../config/sites.json';

const site = sites.find(s => s.id === 'tiktok')!;

function root(file: string): any {
  const html = readFileSync(new URL(`../../spec/fixtures/tiktok/${file}`, import.meta.url), 'utf8');
  return JSON.parse(/<script[^>]*>([\s\S]*?)<\/script>/.exec(html)![1]);
}

/** Hosts observed on a real TikTok detail payload (see spec/fixtures/tiktok). */
const REAL_COVER_HOSTS = [
  'p16-common-sign.tiktokcdn-eu.com',
  'p19-common-sign.tiktokcdn-eu.com',
  'p16-common-sign.tiktokcdn-us.com',
];

function authorised(host: string): boolean {
  return (site.download.mediaHosts as { domain: string; includeSubdomains?: boolean }[])
    .some(rule => host === rule.domain ||
      (rule.includeSubdomains === true && host.endsWith(`.${rule.domain}`)));
}

describe('tiktok preview cover', () => {
  it('keeps the real cover hosts inside the declared mediaHosts', () => {
    for (const host of REAL_COVER_HOSTS) expect(authorised(host)).toBe(true);
    expect(authorised('evil.test')).toBe(false);
  });

  it('prefers originCover for a video item and falls back in player order', () => {
    const struct = root('video.html').__DEFAULT_SCOPE__['webapp.video-detail'].itemInfo.itemStruct;
    expect(selectTiktokPoster({ video: struct.video })).toBe(struct.video.originCover);
    expect(selectTiktokPoster({ video: { ...struct.video, originCover: undefined } }))
      .toBe(struct.video.cover);
    expect(selectTiktokPoster({ video: { originCover: undefined, cover: undefined,
      dynamicCover: struct.video.dynamicCover } })).toBe(struct.video.dynamicCover);
  });

  it('reads imagePost.cover for a photo post', () => {
    const struct = root('photo.html').__DEFAULT_SCOPE__['webapp.video-detail'].itemInfo.itemStruct;
    expect(selectTiktokPoster({ cover: struct.imagePost.cover }))
      .toBe(struct.imagePost.cover.imageURL.urlList[0]);
  });

  it('ignores missing, relative and non-http covers', () => {
    expect(selectTiktokPoster({})).toBeUndefined();
    expect(selectTiktokPoster({ cover: '/relative.jpg' })).toBeUndefined();
    expect(selectTiktokPoster({ cover: 'javascript:alert(1)' })).toBeUndefined();
  });

  it('the real module output declares a poster resource the app can request', () => {
    const html = readFileSync(
      new URL('../../spec/fixtures/tiktok/video.html', import.meta.url), 'utf8');
    const struct = root('video.html').__DEFAULT_SCOPE__['webapp.video-detail'].itemInfo.itemStruct;
    const result = JSON.parse(moduleCall('tiktok', 'parse', {
      input: html, url: 'https://www.tiktok.com/@/video/' + struct.id, site,
    })).value;
    expect(result.ok).toBe(true);
    expect(result.data.items[0].posterUrl).toBe(struct.video.originCover);
    const poster = result.data.items[0].resources.find((r: any) => r.role === 'poster');
    expect(poster).toBeDefined();
    expect(poster.url).toBe(struct.video.originCover);
    expect(poster.request).toMatchObject({ cookieDomains: [], transport: 'background' });
  });
});
