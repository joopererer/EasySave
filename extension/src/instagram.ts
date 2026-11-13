// Pure-function Instagram post parser.
//
// Runs on an HTML string plus the page URL, with no DOM or browser APIs,
// so the same code works in content scripts and in Vitest.
// Implements the Instagram section of spec/parsing.md.

import { instagramAiLabel, type AiLabel } from './ai-label';

export type InstagramErrorCode =
  | "LOGIN_REQUIRED"
  | "PRIVATE_OR_UNAVAILABLE"
  | "BLOCKED"
  | "INVALID_PAGE"
  | "MEDIA_UNAVAILABLE";

export interface InstagramError {
  code: InstagramErrorCode;
  message: string;
}

export interface InstagramAuthor {
  name?: string;
  id?: string;
}

export type InstagramItemType = "image" | "video" | "live";

export interface InstagramItem {
  type: InstagramItemType;
  url: string;
  videoUrl?: string;
  thumbnailUrl?: string;
  width?: number;
  height?: number;
  /** Video length in seconds, from `video_duration`. Absent when unknown. */
  duration?: number;
}

export interface InstagramPost {
  platform: "instagram";
  id: string;
  url: string;
  author: InstagramAuthor;
  caption: string;
  publishedAt?: string;
  items: InstagramItem[];
  aiLabel?: AiLabel;
}

export type InstagramResult =
  | { ok: true; data: InstagramPost }
  | { ok: false; error: InstagramError };

const SHORTCODE_PATTERN = /\/(?:p|reels?|tv)\/([A-Za-z0-9-_]+)/;
const SHORTCODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const DATA_SJS_PATTERN = /<script\b[^>]*\bdata-sjs[^>]*>(\{.+?\})<\/script>/gs;

interface OgMeta {
  type?: string;
  image?: string;
  video?: string;
}

function ogMetaOf(html: string): OgMeta {
  const og: OgMeta = {};
  const re = /<meta\b[^>]*\bproperty=["']og:([a-z_]+)["'][^>]*\bcontent=["']([^"']*)["']/gi;
  let match: RegExpExecArray | null;
  while ((match = re.exec(html)) !== null) {
    const key = match[1];
    const value = match[2];
    if (key === "type") og.type = value;
    else if (key === "image") og.image = value;
    else if (key === "video") og.video = value;
  }
  return og;
}

function hasLoginWall(html: string): boolean {
  return /age-restricted|sensitive content|see post|查看帖子|了解详情|成人内容|log in to|登入以继续|请先登录/i.test(html);
}

function videoPage(pageUrl: string, og: OgMeta): boolean {
  try {
    const { pathname } = new URL(pageUrl);
    if (/(^|\/)(reels?|tv)(\/|$)/i.test(pathname)) return true;
  } catch {}
  return (og.type ?? "").includes("video") || og.video != null;
}

/** One media item is enough to fail the "whole reel is one cover" trap; nothing else counts. */
function mediaTypeOf(items: InstagramItem[]): "image" | "video" | "carousel" {
  if (items.some((item) => item.type === "video")) return "video";
  if (items.length > 1) return "carousel";
  return "image";
}

function igParseSourceOfProduct(product: Record<string, unknown>): "api" | "graphql" {
  const typename = typeof product["__typename"] === "string" ? (product["__typename"] as string) : "";
  return /^Graph(I|Video|Sidecar)/.test(typename) ? "graphql" : "api";
}

export { ogMetaOf, hasLoginWall, videoPage, mediaTypeOf, igParseLogLine, igParseSourceOfProduct };
export type { IgParseLog };

interface IgParseLog {
  source: "api" | "graphql" | "embedded_json" | "og_meta";
  mediaType: "image" | "video" | "carousel";
  items: number;
  loginWall: 0 | 1;
}

function igParseLogLine(log: IgParseLog): string {
  return `[IgParse] source=${log.source} mediaType=${log.mediaType} items=${log.items} loginWall=${log.loginWall}`;
}

/**
 * A page that only exposes an OpenGraph cover image is never a complete result:
 * reels and TV pages would hand out the play-button cover as the media, and
 * /p/ pages would hand out a single cover as a carousel. Both fail instead.
 */
function ogImageOnlyFailure(html: string, pageUrl: string): InstagramError | undefined {
  const og = ogMetaOf(html);
  if (!og.image || og.video) return undefined;
  const wall = hasLoginWall(html);
  if (videoPage(pageUrl, og)) {
    return wall
      ? { code: "LOGIN_REQUIRED", message: "该视频需要登录 Instagram 后才能查看。" }
      : {
          code: "MEDIA_UNAVAILABLE",
          message: "未能获取视频，请检查 Instagram 登录后重试。",
        };
  }
  if (/\/p\//i.test(pageUrl)) {
    return wall
      ? { code: "LOGIN_REQUIRED", message: "该帖子需要登录 Instagram 后才能查看。" }
      : {
          code: "MEDIA_UNAVAILABLE",
          message: "未能获取图片，请检查 Instagram 登录后重试。",
        };
  }
  return undefined;
}

/** Capability an App declares in the hook context when it renders MEDIA_UNAVAILABLE. */
const MEDIA_UNAVAILABLE_CAPABILITY = "media_unavailable";

/** Login guidance shown to an App that only knows the v1 error vocabulary. */
const MEDIA_UNAVAILABLE_LOGIN_FALLBACK: InstagramError = {
  code: "LOGIN_REQUIRED",
  message: "需要登录 Instagram 后才能查看该内容，请在“我的”页登录后重试。",
};

/**
 * Keep MEDIA_UNAVAILABLE only for a client that declared the capability.
 *
 * The App renders an unknown code as a bare retry prompt with no way to reach
 * the Instagram login, which leaves the user stuck; an App that sends no
 * capability therefore gets LOGIN_REQUIRED and its login button instead. The
 * browser extension runs the parser it was built with and always declares it.
 */
export function gateMediaUnavailable<T>(result: T, caps: unknown): T {
  if (!isRecord(result) || result["ok"] !== false) return result;
  const error = result["error"];
  if (!isRecord(error) || error["code"] !== "MEDIA_UNAVAILABLE") return result;
  if (declaresMediaUnavailable(caps)) return result;
  return { ...result, error: { ...MEDIA_UNAVAILABLE_LOGIN_FALLBACK } } as T;
}

export function declaresMediaUnavailable(caps: unknown): boolean {
  return (
    Array.isArray(caps) &&
    caps.some((capability) => capability === MEDIA_UNAVAILABLE_CAPABILITY)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function nonBlank(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function toIsoUtcSeconds(seconds: number): string {
  return new Date(seconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/**
 * Convert an Instagram shortcode to its numeric media id.
 * Uses BigInt because the value exceeds 64-bit float precision.
 * Returns undefined for empty input or characters outside the alphabet.
 */
export function shortcodeToMediaId(shortcode: string): string | undefined {
  if (!shortcode) return undefined;
  let id = 0n;
  for (const ch of shortcode) {
    const digit = SHORTCODE_ALPHABET.indexOf(ch);
    if (digit < 0) return undefined;
    id = id * 64n + BigInt(digit);
  }
  return id.toString(10);
}

/** A candidate product object: carries media payload under a matching id/pk/shortcode. */
function isProductShaped(obj: Record<string, unknown>, mediaId: string): boolean {
  const matchesId =
    String(obj["id"] ?? "") === mediaId ||
    String(obj["pk"] ?? "") === mediaId ||
    (nonBlank(obj["code"]) && shortcodeToMediaId(obj["code"] as string) === mediaId) ||
    (nonBlank(obj["shortcode"]) && shortcodeToMediaId(obj["shortcode"] as string) === mediaId);
  if (!matchesId) return false;
  return (
    "video_versions" in obj ||
    "carousel_media" in obj ||
    "image_versions2" in obj ||
    "display_url" in obj ||
    "video_url" in obj ||
    "edge_sidecar_to_children" in obj
  );
}

function findProduct(root: unknown, mediaId: string): Record<string, unknown> | undefined {
  const seen = new Set<object>();
  const visit = (node: unknown): Record<string, unknown> | undefined => {
    if (!isRecord(node) && !Array.isArray(node)) return undefined;
    if (seen.has(node as object)) return undefined;
    seen.add(node as object);
    if (isRecord(node)) {
      if (isProductShaped(node, mediaId)) return node;
      for (const value of Object.values(node)) {
        const found = visit(value);
        if (found) return found;
      }
      return undefined;
    }
    for (const value of node as unknown[]) {
      const found = visit(value);
      if (found) return found;
    }
    return undefined;
  };
  return visit(root);
}

interface Rendition {
  url: string;
  width: number;
  height: number;
}

function bestRendition(list: unknown): Rendition | undefined {
  if (!Array.isArray(list)) return undefined;
  let best: Rendition | undefined;
  for (const entry of list) {
    if (!isRecord(entry) || !nonBlank(entry["url"])) continue;
    const width = typeof entry["width"] === "number" ? (entry["width"] as number) : 0;
    const height = typeof entry["height"] === "number" ? (entry["height"] as number) : 0;
    if (!best || width * height > best.width * best.height) {
      best = { url: entry["url"] as string, width, height };
    }
  }
  return best;
}

function bestImage(media: Record<string, unknown>): Rendition | undefined {
  const versions = isRecord(media["image_versions2"])
    ? (media["image_versions2"] as Record<string, unknown>)["candidates"]
    : undefined;
  const best = bestRendition(versions);
  if (best) return best;
  if (nonBlank(media["display_url"])) {
    const dim = isRecord(media["dimensions"]) ? (media["dimensions"] as Record<string, unknown>) : {};
    const width = typeof dim["width"] === "number" ? (dim["width"] as number) : 0;
    const height = typeof dim["height"] === "number" ? (dim["height"] as number) : 0;
    return { url: media["display_url"] as string, width, height };
  }
  return undefined;
}

function bestVideoUrl(media: Record<string, unknown>): Rendition | undefined {
  const best = bestRendition(media["video_versions"]);
  if (best) return best;
  if (nonBlank(media["video_url"])) {
    const dim = isRecord(media["dimensions"]) ? (media["dimensions"] as Record<string, unknown>) : {};
    const width = typeof dim["width"] === "number" ? (dim["width"] as number) : 0;
    const height = typeof dim["height"] === "number" ? (dim["height"] as number) : 0;
    return { url: media["video_url"] as string, width, height };
  }
  return undefined;
}

function originalMediaItem(media: Record<string, unknown>): InstagramItem | undefined {
  const image = bestImage(media);
  const video = bestVideoUrl(media);
  if (video) {
    const item: InstagramItem = {
      type: "video",
      url: image ? image.url : video.url,
      width: video.width,
      height: video.height,
    };
    if (image) item.videoUrl = video.url;
    const rawDuration = media["video_duration"];
    if (typeof rawDuration === "number" && Number.isFinite(rawDuration)) {
      item.duration = rawDuration;
    }
    return item;
  }
  if (image) return { type: "image", url: image.url, width: image.width, height: image.height };
  return undefined;
}

/**
 * Parse an Instagram post/reel page.
 * @param html Full page HTML source.
 * @param pageUrl The URL the HTML was fetched from (used to find the shortcode).
 */
export function parseInstagram(html: string, pageUrl: string, smallThumbnail = false): InstagramResult {
  const shortcodeMatch = SHORTCODE_PATTERN.exec(pageUrl);
  const shortcode = shortcodeMatch ? shortcodeMatch[1] : undefined;
  const mediaId = shortcode ? shortcodeToMediaId(shortcode) : undefined;

  let product: Record<string, unknown> | undefined;
  let source: "api" | "graphql" | "embedded_json" = "api";
  if (mediaId) {
    DATA_SJS_PATTERN.lastIndex = 0;
    let match: RegExpExecArray | null;
    while ((match = DATA_SJS_PATTERN.exec(html)) !== null) {
      let parsed: unknown;
      try {
        parsed = JSON.parse(match[1]) as unknown;
      } catch {
        continue;
      }
      product = findProduct(parsed, mediaId);
      if (product) {
        source = "embedded_json";
        break;
      }
    }
  }

  if (!product && shortcode) {
    try {
      const g = (typeof globalThis !== "undefined"
        ? globalThis
        : typeof window !== "undefined"
          ? window
          : null) as Record<string, unknown> | null;
      const cached = g?.["__easysaveIgProducts"] as Record<string, unknown> | undefined;
      if (cached && isRecord(cached[shortcode])) {
        product = cached[shortcode] as Record<string, unknown>;
        source = igParseSourceOfProduct(product);
      }
    } catch (_) {}
  }

  const looksLikeInstagram =
    /instagram\.com|instagr\.am/.test(pageUrl) ||
    /instagram\.com|instagr\.am|data-sjs/.test(html.slice(0, 20000));
  const loginWall = hasLoginWall(html) ? 1 : 0;
  if (!product || !shortcode) {
    if (looksLikeInstagram) {
      const ogOnly = ogImageOnlyFailure(html, pageUrl);
      if (ogOnly) {
        const og = ogMetaOf(html);
        console.info?.(
          igParseLogLine({
            source: "og_meta",
            mediaType: videoPage(pageUrl, og) ? "video" : "image",
            items: 0,
            loginWall,
          }),
        );
        return { ok: false, error: ogOnly };
      }
      const isAgeGated =
        /sensitive content|age-restricted|查看帖子|了解详情|see post|成人内容|sensitive_content/i.test(html);
      return {
        ok: false,
        error: {
          code: "LOGIN_REQUIRED",
          message: isAgeGated
            ? "该帖子包含敏感内容或年龄限制，需要通过网页授权或点击查看。"
            : "Instagram returned a login-gated shell without post data.",
        },
      };
    }
    return {
      ok: false,
      error: { code: "INVALID_PAGE", message: "Not an Instagram post page." },
    };
  }

  const result = buildPostFromProduct(product, shortcode, smallThumbnail);
  if (result.ok) {
    console.info?.(
      igParseLogLine({
        source,
        mediaType: mediaTypeOf(result.data.items),
        items: result.data.items.length,
        loginWall,
      }),
    );
  }
  return result;
}

/**
 * Build the unified post output from an already-located product object.
 * Shared by parseInstagram (HTML input), DOM extraction, and the network-sniffing fast path.
 */
export function buildPostFromProduct(
  product: Record<string, unknown>,
  shortcode: string,
  smallThumbnail = false,
): InstagramResult {
  for (const line of probeInstagramAiFields(product)) console.info?.('EasySaveIgAiProbe:' + line);
  const user = isRecord(product["user"])
    ? (product["user"] as Record<string, unknown>)
    : isRecord(product["owner"])
      ? (product["owner"] as Record<string, unknown>)
      : {};
  const author: InstagramAuthor = {};
  if (nonBlank(user["username"])) author.name = user["username"] as string;
  const authorId = user["pk"] ?? user["id"];
  if (authorId !== undefined && authorId !== null && String(authorId).length > 0) {
    author.id = String(authorId);
  }

  let caption = "";
  const captionRaw = product["caption"];
  if (typeof captionRaw === "string") {
    caption = captionRaw;
  } else if (isRecord(captionRaw) && typeof captionRaw["text"] === "string") {
    caption = captionRaw["text"] as string;
  } else if (isRecord(product["edge_media_to_caption"])) {
    const edges = (product["edge_media_to_caption"] as Record<string, unknown>)["edges"];
    if (Array.isArray(edges) && edges.length > 0 && isRecord(edges[0]["node"])) {
      const text = (edges[0]["node"] as Record<string, unknown>)["text"];
      if (typeof text === "string") caption = text;
    }
  }

  const takenAt = product["taken_at"] ?? product["taken_at_timestamp"];
  const publishedAt =
    typeof takenAt === "number" && Number.isFinite(takenAt) ? toIsoUtcSeconds(takenAt) : "";

  const items: InstagramItem[] = [];
  const carousel = product["carousel_media"];
  const sidecar = isRecord(product["edge_sidecar_to_children"])
    ? (product["edge_sidecar_to_children"] as Record<string, unknown>)["edges"]
    : undefined;

  if (Array.isArray(carousel) && carousel.length > 0) {
    for (const child of carousel) {
      if (!isRecord(child)) continue;
      const item = mediaItem(child, smallThumbnail);
      if (item) items.push(item);
    }
  } else if (Array.isArray(sidecar) && sidecar.length > 0) {
    for (const edge of sidecar) {
      if (!isRecord(edge) || !isRecord(edge["node"])) continue;
      const item = mediaItem(edge["node"] as Record<string, unknown>, smallThumbnail);
      if (item) items.push(item);
    }
  } else {
    const item = mediaItem(product, smallThumbnail);
    if (item) items.push(item);
  }

  if (items.length === 0) {
    return {
      ok: false,
      error: {
        code: "LOGIN_REQUIRED",
        message: "Instagram post has no extractable media.",
      },
    };
  }

  const data: InstagramPost = {
    platform: "instagram",
    id: shortcode,
    url: `https://www.instagram.com/p/${shortcode}/`,
    author,
    caption,
    items,
  };
  if (publishedAt) data.publishedAt = publishedAt;
  const aiLabel = instagramAiLabel(product.ai_label_info);
  if (aiLabel) data.aiLabel = aiLabel;
  return { ok: true, data };
}

/** Only root platform-generated label and subtitle have bounded prose exceptions. */
export function probeInstagramAiFields(product: unknown): string[] {
  const lines: string[] = [];
  const seen = new Set<object>();
  let visited = 0;
  const visit = (node: unknown, path: string, privateTree = false, depth = 0): void => {
    if (!node || typeof node !== 'object' || seen.has(node) || depth > 24 || visited++ > 10000) return;
    seen.add(node);
    if (Array.isArray(node)) {
      node.forEach((value, i) => visit(value, `${path}[${i}]`, privateTree, depth + 1));
      return;
    }
    for (const [name, value] of Object.entries(node)) {
      if (!/^[A-Za-z_][A-Za-z0-9_]{0,79}$/.test(name)) continue;
      const next = path + '.' + name;
      const sensitive = privateTree || /user|owner|author|caption|text|url|email|phone|account|cookie|token|session|password|secret|authorization/i.test(name);
      if ((next.startsWith('$.ai_label_info.') || /ai|gen_ai|genai|label|disclosure|c2pa/i.test(name)) && lines.length < 256) {
        const type = value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value;
        const record: Record<string, unknown> = { path: next, name, type };
        if ((next === '$.ai_label_info.attribution_label_text' || next === '$.ai_label_info.subtitle_text') && typeof value === 'string') {
          const text = value.replace(/[\u0000-\u001f\u007f-\u009f]/g, '');
          if (!/https?:\/\/|[?&][^\s=]+=/i.test(text)) record.value = Array.from(text).slice(0, name === 'subtitle_text' ? 120 : 60).join('');
        } else if (!sensitive && (typeof value === 'boolean' ||
            typeof value === 'number' && Number.isFinite(value) ||
            typeof value === 'string' && /^[A-Za-z0-9_]{1,40}$/.test(value))) record.value = value;
        lines.push(JSON.stringify(record));
      }
      visit(value, next, sensitive, depth + 1);
    }
  };
  visit(product, '$');
  return lines;
}

function mediaItem(media: Record<string, unknown>, smallThumbnail: boolean): InstagramItem | undefined {
  const item = originalMediaItem(media);
  const versions = isRecord(media.image_versions2) ? media.image_versions2.candidates : undefined;
  if (item && smallThumbnail && Array.isArray(versions)) {
    const candidates = versions.filter(e => isRecord(e) && nonBlank(e.url) &&
      typeof e.width === 'number' && typeof e.height === 'number' && e.width > 0 && e.height > 0);
    candidates.sort((a,b) => a.width * a.height - b.width * b.height);
    if (candidates[0]) item.thumbnailUrl = candidates[0].url;
  }
  return item;
}
