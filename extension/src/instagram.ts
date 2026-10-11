// Pure-function Instagram post parser.
//
// Runs on an HTML string plus the page URL, with no DOM or browser APIs,
// so the same code works in content scripts and in Vitest.
// Implements the Instagram section of spec/parsing.md.

export type InstagramErrorCode =
  | "LOGIN_REQUIRED"
  | "PRIVATE_OR_UNAVAILABLE"
  | "BLOCKED"
  | "INVALID_PAGE";

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
  width?: number;
  height?: number;
}

export interface InstagramPost {
  platform: "instagram";
  id: string;
  url: string;
  author: InstagramAuthor;
  caption: string;
  publishedAt?: string;
  items: InstagramItem[];
}

export type InstagramResult =
  | { ok: true; data: InstagramPost }
  | { ok: false; error: InstagramError };

const SHORTCODE_PATTERN = /\/(?:p|reels?|tv)\/([A-Za-z0-9-_]+)/;
const SHORTCODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const DATA_SJS_PATTERN = /<script\b[^>]*\bdata-sjs[^>]*>(\{.+?\})<\/script>/gs;

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

/** A candidate product object: carries media payload under a matching id/pk. */
function isProductShaped(obj: Record<string, unknown>, mediaId: string): boolean {
  const matchesId = String(obj["id"] ?? "") === mediaId || String(obj["pk"] ?? "") === mediaId;
  if (!matchesId) return false;
  return (
    "video_versions" in obj || "carousel_media" in obj || "image_versions2" in obj
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
  if (nonBlank(media["display_url"])) return { url: media["display_url"] as string, width: 0, height: 0 };
  return undefined;
}

function bestVideoUrl(media: Record<string, unknown>): Rendition | undefined {
  return bestRendition(media["video_versions"]);
}

function mediaItem(media: Record<string, unknown>): InstagramItem | undefined {
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
export function parseInstagram(html: string, pageUrl: string): InstagramResult {
  const shortcodeMatch = SHORTCODE_PATTERN.exec(pageUrl);
  const shortcode = shortcodeMatch ? shortcodeMatch[1] : undefined;
  const mediaId = shortcode ? shortcodeToMediaId(shortcode) : undefined;

  let product: Record<string, unknown> | undefined;
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
      if (product) break;
    }
  }

  const looksLikeInstagram =
    /instagram\.com|instagr\.am/.test(pageUrl) ||
    /instagram\.com|instagr\.am|data-sjs/.test(html.slice(0, 20000));
  if (!product || !shortcode) {
    if (looksLikeInstagram) {
      return {
        ok: false,
        error: {
          code: "LOGIN_REQUIRED",
          message: "Instagram returned a login-gated shell without post data.",
        },
      };
    }
    return {
      ok: false,
      error: { code: "INVALID_PAGE", message: "Not an Instagram post page." },
    };
  }

  return buildPostFromProduct(product, shortcode);
}

/**
 * Build the unified post output from an already-located product object.
 * Shared by parseInstagram (HTML input) and the network-sniffing fast path.
 */
export function buildPostFromProduct(
  product: Record<string, unknown>,
  shortcode: string,
): InstagramResult {
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

  const captionRaw = product["caption"];
  const caption =
    typeof captionRaw === "string"
      ? captionRaw
      : isRecord(captionRaw) && typeof captionRaw["text"] === "string"
        ? (captionRaw["text"] as string)
        : "";

  const takenAt = product["taken_at"];
  const publishedAt =
    typeof takenAt === "number" && Number.isFinite(takenAt) ? toIsoUtcSeconds(takenAt) : "";

  const items: InstagramItem[] = [];
  const carousel = product["carousel_media"];
  if (Array.isArray(carousel)) {
    for (const child of carousel) {
      if (!isRecord(child)) continue;
      const item = mediaItem(child);
      if (item) items.push(item);
    }
  } else {
    const item = mediaItem(product);
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
  return { ok: true, data };
}
