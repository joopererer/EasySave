// Parser 1.4.17.
//
// 1. An App that believes it is signed in no longer turns every unreadable page
//    into PRIVATE_OR_UNAVAILABLE: a login wall means the stored session stopped
//    working and asks for a new login, while the platform's own "gone / private
//    / deleted" notice keeps the old answer.
// 2. Xiaohongshu stills (and a Live photo's still) carry the CDN's
//    full-quality JPEG transcode (`imageView2/format/jpg/q/100`) themselves,
//    ahead of every other JPEG candidate and ahead of the stored original.
import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { moduleCall } from '../src/_parse_page';
import type { XhsItem } from '../src/xhs';
import { parse } from '../src/index';
import {
  fullQualityJpegImageUrl,
  jpegImageUrl,
  originalImageUrl,
  xhsImageDownloadOrder,
  xhsImageVariant,
  xhsPageSignal,
} from '../src/xhs';
import { instagramPageSignal } from '../src/instagram';

afterEach(() => vi.unstubAllGlobals());

const fixture = (path: string) =>
  readFileSync(new URL(`../../spec/fixtures/${path}`, import.meta.url), 'utf8');

const site = (id: string) => ({
  id,
  displayName: id === 'xhs' ? '小红书' : 'Instagram',
  auth: { mode: 'optional' },
  download: { headers: {}, cookieDomains: [] },
});

/** The still items of a successful Xiaohongshu parse. */
function xhsItemsOf(result: ReturnType<typeof parse>): XhsItem[] {
  if (!result.ok) {
    throw new Error(`parse failed: ${(result as { error: { code: string } }).error.code}`);
  }
  return (result.data as { items: XhsItem[] }).items;
}

/** Run a classify hook with the given page as the WebView's document. */
function classify(
  moduleId: string,
  html: string,
  url: string,
  error: { code: string; message: string },
  loggedIn: boolean,
): { code: string; message: string } {
  vi.stubGlobal('document', { documentElement: { outerHTML: html } });
  const output = moduleCall(moduleId, 'classify', {
    url,
    site: site(moduleId),
    error,
    loggedIn,
  } as any);
  return JSON.parse(output).value;
}

const LOGIN_REQUIRED = { code: 'LOGIN_REQUIRED', message: 'Xiaohongshu returned an authenticated-only shell without note data.' };
const IG_LOGIN_REQUIRED = { code: 'LOGIN_REQUIRED', message: '该帖子需要登录 Instagram 后才能查看。' };
const XHS_URL = 'https://www.xiaohongshu.com/explore/6aca089a000000000a01efb4';
const IG_URL = 'https://www.instagram.com/p/ig_session_expired/';

describe('page signals, per platform, from the fixtures', () => {
  it('Xiaohongshu tells a gone note apart from a login wall', () => {
    // The note page prints its own "temporarily unavailable" notice.
    expect(xhsPageSignal(fixture('xhs/xhs_note_deleted.html'), XHS_URL)).toBe('unavailable');
    // The app shell shows the login dialog and reports loggedIn:false.
    expect(xhsPageSignal(fixture('xhs/xhs_session_expired.html'), XHS_URL)).toBe('login_wall');
  });

  it('a healthy Xiaohongshu note page carries no signal at all', () => {
    for (const name of ['xhs_multi', 'xhs_live', 'xhs_video', 'xhs_profile_route']) {
      expect(xhsPageSignal(fixture(`xhs/${name}.html`), XHS_URL), name).toBeUndefined();
    }
  });

  it('a login redirect alone is a login wall on both platforms', () => {
    expect(xhsPageSignal('<html></html>', 'https://www.xiaohongshu.com/login?redirectPath=%2Fexplore%2F1')).toBe('login_wall');
    expect(instagramPageSignal('<html></html>', 'https://www.instagram.com/accounts/login/?next=%2Fp%2Fabc%2F')).toBe('login_wall');
  });

  it('Instagram tells a gone post apart from a login wall', () => {
    expect(instagramPageSignal(fixture('instagram/ig_post_deleted.html'), IG_URL)).toBe('unavailable');
    expect(instagramPageSignal(fixture('instagram/ig_session_expired.html'), IG_URL)).toBe('login_wall');
  });

  it('Instagram age / sensitive-content gates are not login walls', () => {
    // The gate asks for a confirmation, not for a new session, so the old
    // answer stays (see the classify test below).
    expect(instagramPageSignal(fixture('instagram/ig_login_wall.html'), 'https://www.instagram.com/p/ig_login_wall/')).toBeUndefined();
  });

  it('healthy Instagram pages and blocked pages carry no signal at all', () => {
    // These anonymous captures do carry `PolarisLoggedOut` / `USER_ID` 0; that
    // is why neither is a login-wall marker (see instagramPageSignal).
    for (const name of ['ig_carousel', 'ig_reel', 'ig_og_only_post', 'ig_og_only_reel', 'blocked']) {
      expect(instagramPageSignal(fixture(`instagram/${name}.html`), IG_URL), name).toBeUndefined();
    }
  });

  it('the notice wins when one page carries both families', () => {
    const both = fixture('xhs/xhs_note_deleted.html') + '<div id="login-container">扫码登录</div>';
    expect(xhsPageSignal(both, XHS_URL)).toBe('unavailable');
  });
});

describe('classify: an App that believes it is signed in', () => {
  it('a login wall becomes LOGIN_REQUIRED with the re-login prompt (XHS)', () => {
    const error = classify('xhs', fixture('xhs/xhs_session_expired.html'), XHS_URL, LOGIN_REQUIRED, true);
    expect(error).toEqual({ code: 'LOGIN_REQUIRED', message: '登录可能已失效，请重新登录' });
  });

  it('a gone note keeps PRIVATE_OR_UNAVAILABLE and its existing message (XHS)', () => {
    const error = classify('xhs', fixture('xhs/xhs_note_deleted.html'), XHS_URL, LOGIN_REQUIRED, true);
    expect(error).toEqual({
      code: 'PRIVATE_OR_UNAVAILABLE',
      message: '未能读取笔记内容（分享链接可能已过期，请重新粘贴原分享链接再试）',
    });
  });

  it('a page with no signal keeps the pre-1.4.17 answer (XHS)', () => {
    const error = classify('xhs', '<html><body>changed layout</body></html>', XHS_URL, LOGIN_REQUIRED, true);
    expect(error).toEqual({
      code: 'PRIVATE_OR_UNAVAILABLE',
      message: '未能读取笔记内容（分享链接可能已过期，请重新粘贴原分享链接再试）',
    });
  });

  it('a page with no signal keeps the pre-1.4.17 answer (Instagram)', () => {
    const error = classify('instagram', '<html><body>changed layout</body></html>', IG_URL, IG_LOGIN_REQUIRED, true);
    expect(error).toEqual({
      code: 'PRIVATE_OR_UNAVAILABLE',
      message: '未能读取帖子内容（可能包含受限内容或已被删除）',
    });
  });

  it('a login wall becomes LOGIN_REQUIRED with the re-login prompt (Instagram)', () => {
    const error = classify('instagram', fixture('instagram/ig_session_expired.html'), IG_URL, IG_LOGIN_REQUIRED, true);
    expect(error).toEqual({ code: 'LOGIN_REQUIRED', message: '登录可能已失效，请重新登录' });
  });

  it('a gone post keeps PRIVATE_OR_UNAVAILABLE (Instagram)', () => {
    const error = classify('instagram', fixture('instagram/ig_post_deleted.html'), IG_URL, IG_LOGIN_REQUIRED, true);
    expect(error).toEqual({
      code: 'PRIVATE_OR_UNAVAILABLE',
      message: '未能读取帖子内容（可能包含受限内容或已被删除）',
    });
  });

  it('an age gate keeps its own message and the old answer (Instagram)', () => {
    const gated = { code: 'LOGIN_REQUIRED', message: '该帖子包含敏感内容或年龄限制，需要通过网页授权或点击查看。' };
    const error = classify('instagram', fixture('instagram/ig_login_wall.html'), 'https://www.instagram.com/p/ig_login_wall/', gated, true);
    expect(error).toEqual({ code: 'PRIVATE_OR_UNAVAILABLE', message: gated.message });
  });

  it('a signed-out App gets the plain login guidance, never the session prompt', () => {
    expect(classify('xhs', fixture('xhs/xhs_session_expired.html'), XHS_URL, LOGIN_REQUIRED, false))
      .toEqual({ code: 'LOGIN_REQUIRED', message: '需要先登录小红书才能解析该笔记' });
    expect(classify('instagram', fixture('instagram/ig_session_expired.html'), IG_URL, IG_LOGIN_REQUIRED, false))
      .toEqual(IG_LOGIN_REQUIRED);
  });

  it('1.4.17 introduces no new error code', () => {
    const codes = new Set([
      classify('xhs', fixture('xhs/xhs_session_expired.html'), XHS_URL, LOGIN_REQUIRED, true).code,
      classify('xhs', fixture('xhs/xhs_note_deleted.html'), XHS_URL, LOGIN_REQUIRED, true).code,
      classify('instagram', fixture('instagram/ig_session_expired.html'), IG_URL, IG_LOGIN_REQUIRED, true).code,
      classify('instagram', fixture('instagram/ig_post_deleted.html'), IG_URL, IG_LOGIN_REQUIRED, true).code,
    ]);
    expect([...codes].sort()).toEqual(['LOGIN_REQUIRED', 'PRIVATE_OR_UNAVAILABLE']);
  });

  it('the version-gated fallback still applies for a signed-out App', () => {
    // moduleCall downgrades a PRIVATE_OR_UNAVAILABLE answer to LOGIN_REQUIRED
    // when the App is not signed in, and the platform hook then supplies its
    // own sign-in guidance — exactly as before this release.
    vi.stubGlobal('document', { documentElement: { outerHTML: '<html></html>' } });
    const value = JSON.parse(moduleCall('xhs', 'classify', {
      url: XHS_URL,
      site: site('xhs'),
      error: { code: 'PRIVATE_OR_UNAVAILABLE', message: 'x' },
      loggedIn: false,
    } as any)).value;
    expect(value.code).toBe('LOGIN_REQUIRED');
    expect(value.message).toBe('需要先登录小红书才能解析该笔记');
  });
});

describe('the parser hands out the full-quality JPEG candidate itself', () => {
  const token = 'notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208';

  it('builds the candidate from the original-bucket token', () => {
    expect(fullQualityJpegImageUrl(token))
      .toBe(`https://sns-img-bd.xhscdn.com/${token}?imageView2/format/jpg/q/100`);
    // `format/jpeg` and `format/jpg` are byte-identical; only `/q/100` is honoured.
    expect(fullQualityJpegImageUrl(token)).toContain('/q/100');
    expect(jpegImageUrl(token)).toBe(`https://ci.xiaohongshu.com/${token}?imageView2/format/jpg`);
  });

  it('lists it before every other JPEG candidate and before the original', () => {
    const result = parse(fixture('xhs/xhs_multi.html'), 'https://www.xiaohongshu.com/explore/6aca089a000000000a01efb4');
    const items = xhsItemsOf(result);
    expect(items).toHaveLength(14);
    for (const item of items) {
      const fallbacks = item.fallbacks ?? [];
      expect(item.type).toBe('image');
      expect(fallbacks[0]).toBe(`${item.url}?imageView2/format/jpg/q/100`);
      expect(fallbacks[1]).toBe(`https://ci.xiaohongshu.com/${item.url.split('/').slice(3).join('/')}?imageView2/format/jpg`);
      // The stored original stays the primary URL of the item.
      expect(item.url).toBe(originalImageUrl(item.url.split('/').slice(3).join('/')));
      // No URL is offered twice, so one item never spends two attempts on it.
      expect(new Set([item.url, ...fallbacks]).size).toBe(1 + fallbacks.length);
    }
  });

  it('applies to a Live photo still as well, and leaves the clip alone', () => {
    const result = parse(fixture('xhs/xhs_live.html'), 'https://www.xiaohongshu.com/explore/6a342fd20000000021017867');
    const items = xhsItemsOf(result);
    expect(items).toHaveLength(8);
    for (const item of items) {
      expect(item.type).toBe('live');
      expect(item.videoUrl).toContain('sns-video-');
      const fallbacks = item.fallbacks ?? [];
      expect(fallbacks[0]).toBe(`${item.url}?imageView2/format/jpg/q/100`);
      expect(fallbacks.some((url) => url === item.videoUrl)).toBe(false);
    }
  });

  it('leaves a video note untouched', () => {
    const result = parse(fixture('xhs/xhs_video.html'), 'https://www.xiaohongshu.com/explore/6aca33420000000012035198');
    if (!result.ok) throw new Error(`parse failed: ${result.error.code}`);
    const expected = JSON.parse(fixture('xhs/xhs_video.expected.json'));
    expect(result.data).toEqual(expected);
    expect((result.data.items[0] as { downloadOrder?: string[] }).downloadOrder).toBeUndefined();
  });

  it('ranks it first in the download order and never lists a preview', () => {
    const result = parse(fixture('xhs/xhs_multi.html'), 'https://www.xiaohongshu.com/explore/6aca089a000000000a01efb4');
    for (const item of xhsItemsOf(result)) {
      const order = xhsImageDownloadOrder(item.url, item.fallbacks ?? []);
      expect(order[0]).toBe(`${item.url}?imageView2/format/jpg/q/100`);
      expect(xhsImageVariant(order[0])).toBe('jpeg');
      expect(new Set(order).size).toBe(order.length);
      expect(order.some((url) => xhsImageVariant(url) === 'preview')).toBe(false);
    }
  });

  it('classifies the new candidate as a JPEG, not as an unknown shape', () => {
    expect(xhsImageVariant(`https://sns-img-bd.xhscdn.com/${token}?imageView2/format/jpg/q/100`)).toBe('jpeg');
    // A size-pinned transcode is still a preview, never an original.
    expect(xhsImageVariant(`https://sns-img-bd.xhscdn.com/${token}?imageView2/format/jpg/w/720`)).not.toBe('jpeg');
    expect(xhsImageVariant(`https://sns-img-bd.xhscdn.com/${token}?imageView2/format/jpg/thumbnail/720`)).not.toBe('jpeg');
  });

  it('does not change Instagram results', () => {
    for (const [name, url] of [
      ['ig_carousel', 'https://www.instagram.com/p/Ddl1WWnGyCN/'],
    ] as Array<[string, string]>) {
      const result = parse(fixture(`instagram/${name}.html`), url);
      if (!result.ok) throw new Error(`parse failed: ${result.error.code}`);
      expect(result.data).toEqual(JSON.parse(fixture(`instagram/${name}.expected.json`)));
    }
  });
});
