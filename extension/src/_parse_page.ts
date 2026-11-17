import { parseXhs, findNoteInStates, buildNoteFromRecord, XHS_LOGIN_REQUIRED, xhsLandingPage } from './xhs';
import {
  parseInstagram,
  buildPostFromProduct,
  hasLoginWall,
  mediaTypeOf,
  igParseLogLine,
  igParseSourceOfProduct,
} from './instagram';
import { parseX, calculateToken, extractTweetId } from './x';
import { parseTiktok, isTiktokLink } from './tiktok';
import { hostnameOf, isXhsHost, isInstagramHost, isXHost } from './_utils';

function noteIdFromUrl(url: string): string | undefined {
  const m = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-f0-9]{24})/i.exec(url);
  return m ? m[1].toLowerCase() : undefined;
}

function shortcodeFromUrl(url: string): string | undefined {
  const m = /\/(?:p|reels?|tv)\/([A-Za-z0-9-_]+)/.exec(url);
  return m ? m[1] : undefined;
}

/** The answer used when the page itself cannot be read or understood. */
export function unreadablePage(): { ok: false; error: { code: string; message: string } } {
  return { ok: false, error: { code: 'INVALID_PAGE', message: '页面内容无法识别，可能已改版' } };
}

/**
 * The page's HTML, or `undefined` while the document is being replaced.
 *
 * A WebView can evaluate the hook in the middle of a navigation, where
 * `document.documentElement` is null or being torn down. Reading it must never
 * throw: an exception reaches the App as a null hook result.
 */
function readableDocumentHtml(): string | undefined {
  try {
    const element = document && document.documentElement;
    const html = element ? element.outerHTML : undefined;
    return typeof html === 'string' && html.length > 0 ? html : undefined;
  } catch (_) {
    return undefined;
  }
}

function currentPageUrl(): string {
  try {
    return (window.location && window.location.href) || '';
  } catch (_) {
    return '';
  }
}

export function parseInstagramFromDom(doc: Document, pageUrl: string): { ok: true; data: any } | undefined {
  const shortcodeMatch = /\/(?:p|reels?|tv)\/([A-Za-z0-9-_]+)/.exec(pageUrl);
  const shortcode = shortcodeMatch ? shortcodeMatch[1] : undefined;
  if (!shortcode) return undefined;

  const items: any[] = [];
  const seenUrls = new Set<string>();

  // 1. Check article / main for videos
  const videos = Array.from(doc.querySelectorAll('article video, main video, video'));
  for (const v of videos) {
    const videoEl = v as HTMLVideoElement;
    const videoSrc = videoEl.currentSrc || videoEl.src || videoEl.querySelector('source')?.getAttribute('src');
    if (videoSrc && !seenUrls.has(videoSrc)) {
      seenUrls.add(videoSrc);
      const poster = videoEl.poster || videoEl.getAttribute('poster') || '';
      items.push({
        type: 'video',
        url: poster ? poster : videoSrc,
        videoUrl: videoSrc,
      });
    }
  }

  // 2. Check article / main for images
  const imgs = Array.from(doc.querySelectorAll('article img, main img'));
  for (const img of imgs) {
    const imgEl = img as HTMLImageElement;
    const src = imgEl.currentSrc || imgEl.src;
    if (!src || src.startsWith('data:') || seenUrls.has(src)) continue;
    const rect = imgEl.getBoundingClientRect ? imgEl.getBoundingClientRect() : null;
    if (rect && (rect.width < 120 || rect.height < 120)) continue;
    if (items.some(it => it.url === src)) continue;
    seenUrls.add(src);
    items.push({
      type: 'image',
      url: src,
      width: rect?.width ? Math.round(rect.width) : undefined,
      height: rect?.height ? Math.round(rect.height) : undefined,
    });
  }

  // 3. OpenGraph meta is NOT a fallback: an og:image on a page that returned no
  // post data is the link preview cover (a reel cover even shows a play button).
  // Returning it would present one cover as the whole post, so this returns
  // undefined and the caller keeps parseInstagram's real error instead.
  if (items.length === 0) return undefined;

  let caption = '';
  const captionEl = doc.querySelector('article h1, article span[dir="auto"], meta[property="og:title"]');
  if (captionEl) {
    caption = (captionEl.getAttribute('content') || captionEl.textContent || '').trim();
  }
  const authorName = doc.querySelector('article header a')?.textContent?.trim() || '';

  return {
    ok: true,
    data: {
      platform: 'instagram',
      id: shortcode,
      url: `https://www.instagram.com/p/${shortcode}/`,
      author: { name: authorName },
      caption,
      items,
    },
  };
}

export function parsePage(): string {
  const url = currentPageUrl();
  const moduleId = isTiktokLink(url) ? 'tiktok' : isXhsHost(url) ? 'xhs' :
    isInstagramHost(url) ? 'instagram' : isXHost(url) ? 'x' : '';
  return parsePageForModule(moduleId);
}

// The App selects this entry point using the verified manifest, not host guessing.
export function parsePageForModule(moduleId: string, thumbnailScenes: string[] = [], smallThumbnail = false): string {
  try {
    return JSON.stringify(parsePageObject(moduleId, thumbnailScenes, smallThumbnail));
  } catch (_) {
    return JSON.stringify(unreadablePage());
  }
}

function parsePageObject(moduleId: string, thumbnailScenes: string[], smallThumbnail: boolean): any {
  const url = currentPageUrl();
  // A note request that came back as the home feed means Xiaohongshu would not
  // serve the note at all; that is a sign-in problem, never a parse result.
  if (moduleId === 'xhs' && xhsLandingPage(url)) {
    return { ok: false, error: { code: 'LOGIN_REQUIRED', message: XHS_LOGIN_REQUIRED } };
  }
  const html = readableDocumentHtml();
  if (html === undefined) return unreadablePage();
  if (moduleId === 'tiktok') {
    const result = parseTiktok(html, url);
    if (result.ok) return result;
    const state = (window as any).__UNIVERSAL_DATA_FOR_REHYDRATION__;
    if (state && typeof state === 'object') {
      return parseTiktok(JSON.stringify(state), url);
    }
    return result;
  }
  if (moduleId === 'xhs') {
    const state = (window as any).__INITIAL_STATE__;
    if (state !== undefined) {
      try {
        const wantedId = noteIdFromUrl(url);
        const note = findNoteInStates([state], wantedId);
        if (note) {
          const noteId =
            typeof note["noteId"] === "string" && (note["noteId"] as string).length > 0
              ? (note["noteId"] as string)
              : (wantedId ?? "");
          if (noteId) {
            return buildNoteFromRecord(note, noteId, url, thumbnailScenes);
          }
        }
      } catch (_) {
        // fall through to regular parsing
      }
    }
    return parseXhs(html, url, thumbnailScenes);
  }
  if (moduleId === 'instagram') {
    const shortcode = shortcodeFromUrl(url);
    if (shortcode && (window as any).__easysaveIgProducts?.[shortcode]) {
      const product = (window as any).__easysaveIgProducts[shortcode];
      const result = buildPostFromProduct(product, shortcode, smallThumbnail);
      if (result.ok) {
        console.info?.(
          igParseLogLine({
            source: igParseSourceOfProduct(product),
            mediaType: mediaTypeOf(result.data.items),
            items: result.data.items.length,
            loginWall: hasLoginWall(html) ? 1 : 0,
          }),
        );
      }
      return result;
    }
    const res = parseInstagram(html, url, smallThumbnail);
    if (res.ok) return res;
    const domRes = parseInstagramFromDom(document, url);
    if (domRes && domRes.ok) {
      console.info?.(
        igParseLogLine({
          source: 'og_meta',
          mediaType: mediaTypeOf(domRes.data.items),
          items: domRes.data.items.length,
          loginWall: hasLoginWall(html) ? 1 : 0,
        }),
      );
      return domRes;
    }
    return res;
  }
  if (moduleId === 'x') {
    return {
      ok: false,
      error: { code: 'UNSUPPORTED_URL', message: 'X posts require syndication JSON input to parse(input, pageUrl)' }
    };
  }
  return { ok: false, error: { code: 'UNSUPPORTED_URL', message: `Unsupported host: ${url}` } };
}

export function parse(input: string, pageUrl: string, moduleId?: string, thumbnailScenes: string[] = [], smallThumbnail = false): string {
  try {
    return JSON.stringify(parseObject(input, pageUrl, moduleId, thumbnailScenes, smallThumbnail));
  } catch (_) {
    return JSON.stringify(unreadablePage());
  }
}

function parseObject(input: string, pageUrl: string, moduleId: string | undefined, thumbnailScenes: string[], smallThumbnail: boolean): any {
  if (moduleId ? moduleId === 'tiktok' : isTiktokLink(pageUrl)) return parseTiktok(input || '', pageUrl);
  const host = hostnameOf(pageUrl);
  if (!host) {
    return { ok: false, error: { code: 'UNSUPPORTED_URL', message: `Cannot parse URL: ${pageUrl}` } };
  }
  if (moduleId ? moduleId === 'xhs' : isXhsHost(host)) {
    if (xhsLandingPage(pageUrl)) {
      return { ok: false, error: { code: 'LOGIN_REQUIRED', message: XHS_LOGIN_REQUIRED } };
    }
    // The page's own `loggedIn` is readable even when the document is not, so a
    // signed-out App is told to sign in instead of being shown the platform's
    // untranslated "authenticated-only shell" answer.
    return parseXhs(input || '', pageUrl, thumbnailScenes);
  }
  if (moduleId ? moduleId === 'instagram' : isInstagramHost(host)) {
    return parseInstagram(input || '', pageUrl, smallThumbnail);
  }
  if (moduleId ? moduleId === 'x' : isXHost(host)) {
    return parseX(input || '', pageUrl);
  }
  return { ok: false, error: { code: 'UNSUPPORTED_URL', message: `Unsupported host: ${host}` } };
}

export { parseXhs, parseInstagram, parseX, calculateToken, extractTweetId };

export { moduleCall } from './parser-modules';
