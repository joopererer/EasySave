import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { moduleCall } from '../src/_parse_page';
import { gateMediaUnavailable, parseInstagram } from '../src/instagram';
import sites from '../../config/sites.json';

const fixtureDir = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  '..',
  'spec',
  'fixtures',
  'instagram',
);
const fixture = (name: string) => readFileSync(join(fixtureDir, `${name}.html`), 'utf-8');
const site = sites.find((entry) => entry.id === 'instagram')!;

/** The App executes parsePage on the loaded document, not on a fetched string. */
function stubOgOnlyPage(url: string, html: string) {
  vi.stubGlobal('window', { location: { href: url } });
  vi.stubGlobal('document', {
    documentElement: { outerHTML: html },
    querySelectorAll: () => [],
    querySelector: () => null,
  });
}

const call = (hook: string, url: string, extra: Record<string, unknown> = {}) =>
  JSON.parse(moduleCall('instagram', hook, { url, site, ...extra })).value;

afterEach(() => vi.unstubAllGlobals());

describe('MEDIA_UNAVAILABLE capability gate', () => {
  it('keeps the code for a client that declared the capability', () => {
    const error = { code: 'MEDIA_UNAVAILABLE', message: '未能获取视频' };
    const result = { ok: false, error };
    expect(gateMediaUnavailable(result, ['media_unavailable'])).toEqual(result);
  });

  it('downgrades to login guidance for a client that declared nothing', () => {
    const gated = gateMediaUnavailable(
      { ok: false, error: { code: 'MEDIA_UNAVAILABLE', message: '未能获取视频' } },
      undefined,
    );
    expect(gated.ok).toBe(false);
    expect(gated.error.code).toBe('LOGIN_REQUIRED');
    expect(gated.error.message).toContain('登录 Instagram');
  });

  it('ignores an unrelated or malformed capability list', () => {
    for (const caps of [[], ['registry_v2'], 'media_unavailable', {}, null]) {
      expect(
        gateMediaUnavailable({ ok: false, error: { code: 'MEDIA_UNAVAILABLE' } }, caps)
          .error.code,
      ).toBe('LOGIN_REQUIRED');
    }
  });

  it('leaves other codes and successful results alone', () => {
    const blocked = { ok: false, error: { code: 'BLOCKED', message: 'x' } };
    const ok = { ok: true, data: { id: 'a', items: [] } };
    expect(gateMediaUnavailable(blocked, undefined)).toEqual(blocked);
    expect(gateMediaUnavailable(ok, undefined)).toEqual(ok);
  });
});

describe('Instagram OpenGraph cover is never the result', () => {
  it('fails a reel whose page only carries an og:image', () => {
    const html = fixture('ig_og_only_reel');
    const result = parseInstagram(html, 'https://www.instagram.com/reel/DflxolxpdHT/');
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.code).toBe('MEDIA_UNAVAILABLE');
    expect(JSON.stringify(result)).not.toContain('cover-with-play-button');
  });

  it('fails a public single-image post that only carries an og:image', () => {
    const html = fixture('ig_og_only_post');
    const result = parseInstagram(html, 'https://www.instagram.com/p/ig_og_only_post/');
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.error.code).toBe('MEDIA_UNAVAILABLE');
    expect(JSON.stringify(result)).not.toContain('single-post-cover');
  });

  it('never emits the og:image as a media item through the App page hook', () => {
    const url = 'https://www.instagram.com/p/ig_og_only_post/';
    stubOgOnlyPage(url, fixture('ig_og_only_post'));
    const result = call('parsePage', url, { caps: ['media_unavailable'] });
    expect(result.ok).toBe(false);
    expect(JSON.stringify(result)).not.toContain('single-post-cover');
  });
});

describe('App without the capability gets login guidance instead', () => {
  const reelUrl = 'https://www.instagram.com/reel/DflxolxpdHT/';
  const postUrl = 'https://www.instagram.com/p/ig_og_only_post/';

  it('answers LOGIN_REQUIRED on the parsePage hook used by v1.10.2', () => {
    stubOgOnlyPage(reelUrl, fixture('ig_og_only_reel'));
    const result = call('parsePage', reelUrl);
    expect(result.ok).toBe(false);
    expect(result.error.code).toBe('LOGIN_REQUIRED');
    expect(result.error.message).toContain('登录 Instagram');
  });

  it('answers LOGIN_REQUIRED on the fetched-HTML parse hook too', () => {
    const result = call('parse', postUrl, { input: fixture('ig_og_only_post') });
    expect(result.ok).toBe(false);
    expect(result.error.code).toBe('LOGIN_REQUIRED');
  });

  it('answers MEDIA_UNAVAILABLE once the capability is declared', () => {
    stubOgOnlyPage(reelUrl, fixture('ig_og_only_reel'));
    const result = call('parsePage', reelUrl, { caps: ['media_unavailable'] });
    expect(result.ok).toBe(false);
    expect(result.error.code).toBe('MEDIA_UNAVAILABLE');
  });

  it('keeps a real login wall on LOGIN_REQUIRED for either client', () => {
    const html = fixture('ig_login_wall');
    stubOgOnlyPage(postUrl, html);
    for (const caps of [undefined, ['media_unavailable']]) {
      const result = call('parsePage', postUrl, caps ? { caps } : {});
      expect(result.ok).toBe(false);
      expect(result.error.code).toBe('LOGIN_REQUIRED');
    }
  });

  it('does not downgrade an unrelated failure code', () => {
    const result = gateMediaUnavailable(
      { ok: false, error: { code: 'PRIVATE_OR_UNAVAILABLE', message: 'x' } },
      undefined,
    );
    expect(result.error.code).toBe('PRIVATE_OR_UNAVAILABLE');
  });
});
