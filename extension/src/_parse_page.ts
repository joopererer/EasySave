import { parseXhs, findNoteInStates, buildNoteFromRecord } from './xhs';
import { parseInstagram, buildPostFromProduct } from './instagram';
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

  // 3. Fallback to OpenGraph meta tags
  if (items.length === 0) {
    const ogVideo = doc.querySelector('meta[property="og:video"]')?.getAttribute('content');
    const ogImage = doc.querySelector('meta[property="og:image"]')?.getAttribute('content');
    if (ogVideo) {
      items.push({
        type: 'video',
        url: ogImage || ogVideo,
        videoUrl: ogVideo,
      });
    } else if (ogImage) {
      items.push({
        type: 'image',
        url: ogImage,
      });
    }
  }

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
  const url = window.location.href;
  const moduleId = isTiktokLink(url) ? 'tiktok' : isXhsHost(url) ? 'xhs' :
    isInstagramHost(url) ? 'instagram' : isXHost(url) ? 'x' : '';
  return parsePageForModule(moduleId);
}

// The App selects this entry point using the verified manifest, not host guessing.
export function parsePageForModule(moduleId: string, thumbnailScenes: string[] = [], smallThumbnail = false): string {
  const url = window.location.href;
  const html = document.documentElement.outerHTML;
  if (moduleId === 'tiktok') {
    const result = parseTiktok(html, url);
    if (result.ok) return JSON.stringify(result);
    const state = (window as any).__UNIVERSAL_DATA_FOR_REHYDRATION__;
    if (state && typeof state === 'object') {
      return JSON.stringify(parseTiktok(JSON.stringify(state), url));
    }
    return JSON.stringify(result);
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
            return JSON.stringify(buildNoteFromRecord(note, noteId, url, thumbnailScenes));
          }
        }
      } catch (_) {
        // fall through to regular parsing
      }
    }
    return JSON.stringify(parseXhs(html, url, thumbnailScenes));
  }
  if (moduleId === 'instagram') {
    const shortcode = shortcodeFromUrl(url);
    if (shortcode && (window as any).__easysaveIgProducts?.[shortcode]) {
      return JSON.stringify(
        buildPostFromProduct((window as any).__easysaveIgProducts[shortcode], shortcode, smallThumbnail)
      );
    }
    const res = parseInstagram(html, url, smallThumbnail);
    if (res.ok) return JSON.stringify(res);
    const domRes = parseInstagramFromDom(document, url);
    if (domRes && domRes.ok) return JSON.stringify(domRes);
    return JSON.stringify(res);
  }
  if (moduleId === 'x') {
    return JSON.stringify({
      ok: false,
      error: { code: 'UNSUPPORTED_URL', message: 'X posts require syndication JSON input to parse(input, pageUrl)' }
    });
  }
  return JSON.stringify({ ok: false, error: { code: 'UNSUPPORTED_URL', message: `Unsupported host: ${url}` } });
}

export function parse(input: string, pageUrl: string, moduleId?: string, thumbnailScenes: string[] = [], smallThumbnail = false): string {
  if (moduleId ? moduleId === 'tiktok' : isTiktokLink(pageUrl)) return JSON.stringify(parseTiktok(input, pageUrl));
  const host = hostnameOf(pageUrl);
  if (!host) {
    return JSON.stringify({ ok: false, error: { code: 'UNSUPPORTED_URL', message: `Cannot parse URL: ${pageUrl}` } });
  }
  if (moduleId ? moduleId === 'xhs' : isXhsHost(host)) {
    return JSON.stringify(parseXhs(input, pageUrl, thumbnailScenes));
  }
  if (moduleId ? moduleId === 'instagram' : isInstagramHost(host)) {
    return JSON.stringify(parseInstagram(input, pageUrl, smallThumbnail));
  }
  if (moduleId ? moduleId === 'x' : isXHost(host)) {
    return JSON.stringify(parseX(input, pageUrl));
  }
  return JSON.stringify({ ok: false, error: { code: 'UNSUPPORTED_URL', message: `Unsupported host: ${host}` } });
}

export { parseXhs, parseInstagram, parseX, calculateToken, extractTweetId };

export { moduleCall } from './parser-modules';
