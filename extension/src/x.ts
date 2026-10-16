// Pure-function X (Twitter) post parser.
//
// Runs on a JSON string (or parsed object) plus the page URL, with no DOM
// or browser APIs, so the same code works in content scripts, App JS runtime,
// and in Vitest.
// Implements the X section of spec/parsing.md.

export type XErrorCode =
  | "LOGIN_REQUIRED"
  | "PRIVATE_OR_UNAVAILABLE"
  | "BLOCKED"
  | "INVALID_PAGE"
  | "UNSUPPORTED_URL";

export interface XError {
  code: XErrorCode;
  message: string;
}

export interface XAuthor {
  name?: string;
  id?: string;
}

export type XItemType = "image" | "video";

export interface XItem {
  type: XItemType;
  url: string;
  isGif?: boolean;
  videoUrl?: string;
  posterUrl?: string;
  width?: number;
  height?: number;
  duration?: number;
}


export interface XPost {
  platform: "x";
  id: string;
  url: string;
  author: XAuthor;
  caption: string;
  publishedAt?: string;
  items: XItem[];
}

export type XResult =
  | { ok: true; data: XPost }
  | { ok: false; error: XError };

const TWEET_ID_PATTERN = /(?:x|twitter)\.com\/(?:[^/]+)\/status\/(\d+)/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeImageUrl(url: string): string {
  try {
    const u = new URL(url);
    u.searchParams.set("name", "orig");
    return u.toString();
  } catch {
    if (url.includes("?")) {
      return url.replace(/([?&])name=[^&]+/, "$1name=orig") + (url.includes("name=") ? "" : "&name=orig");
    }
    return `${url}?name=orig`;
  }
}

function formatUtc(dateStr: string): string | undefined {
  try {
    const d = new Date(dateStr);
    if (isNaN(d.getTime())) return undefined;
    return d.toISOString().replace(/\.\d{3}Z$/, "Z");
  } catch {
    return undefined;
  }
}

export function extractTweetId(url: string): string | undefined {
  const m = TWEET_ID_PATTERN.exec(url);
  return m ? m[1] : undefined;
}

export function calculateToken(id: string): string {
  return ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, "");
}

/**
 * Parse an X post from its syndication API JSON response.
 */
export function parseX(
  input: string | Record<string, unknown>,
  pageUrl: string,
): XResult {
  let root: unknown;
  if (typeof input === "string") {
    const trimmed = input.trim();
    if (trimmed.length === 0) {
      return {
        ok: false,
        error: {
          code: "PRIVATE_OR_UNAVAILABLE",
          message: "This post is private, deleted, or unavailable.",
        },
      };
    }
    try {
      root = JSON.parse(trimmed);
    } catch {
      return {
        ok: false,
        error: {
          code: "PRIVATE_OR_UNAVAILABLE",
          message: "This post is private, deleted, or unavailable.",
        },
      };
    }
  } else {
    root = input;
  }

  if (!isRecord(root) || Object.keys(root).length === 0) {
    return {
      ok: false,
      error: {
        code: "PRIVATE_OR_UNAVAILABLE",
        message: "This post is private, deleted, or unavailable.",
      },
    };
  }

  // Tombstone handling (deleted, sensitive, or age-gated/viewer-restricted)
  if (root["__typename"] === "TweetTombstone") {
    const tombstone = root["tombstone"];
    const textObj = isRecord(tombstone) ? tombstone["text"] : undefined;
    const tombstoneText = isRecord(textObj) && typeof textObj["text"] === "string"
      ? (textObj["text"] as string).toLowerCase()
      : "";

    if (
      tombstoneText.includes("limit") ||
      tombstoneText.includes("view") ||
      tombstoneText.includes("age") ||
      tombstoneText.includes("sensitive") ||
      tombstoneText.includes("login")
    ) {
      return {
        ok: false,
        error: {
          code: "LOGIN_REQUIRED",
          message: "This post requires authentication or has viewer restrictions.",
        },
      };
    }

    return {
      ok: false,
      error: {
        code: "PRIVATE_OR_UNAVAILABLE",
        message: "This post is private, deleted, or unavailable.",
      },
    };
  }

  // Error responses from syndication endpoint
  if (Array.isArray(root["errors"]) && (root["errors"] as unknown[]).length > 0) {
    return {
      ok: false,
      error: {
        code: "PRIVATE_OR_UNAVAILABLE",
        message: "This post is private, deleted, or unavailable.",
      },
    };
  }

  // Identify tweet ID
  const idStr = typeof root["id_str"] === "string"
    ? (root["id_str"] as string)
    : (typeof root["id"] === "number" || typeof root["id"] === "string" ? String(root["id"]) : extractTweetId(pageUrl));

  if (!idStr) {
    return {
      ok: false,
      error: {
        code: "INVALID_PAGE",
        message: "Unable to extract tweet ID.",
      },
    };
  }

  const user = isRecord(root["user"]) ? root["user"] : undefined;
  const screenName = typeof user?.["screen_name"] === "string" ? (user["screen_name"] as string) : "";
  const name = typeof user?.["name"] === "string" ? (user["name"] as string) : undefined;
  const canonicalUrl = screenName
    ? `https://x.com/${screenName}/status/${idStr}`
    : `https://x.com/i/status/${idStr}`;

  const caption = typeof root["text"] === "string" ? (root["text"] as string) : "";
  const publishedAt = typeof root["created_at"] === "string" ? formatUtc(root["created_at"] as string) : undefined;

  const items: XItem[] = [];
  const mediaDetails = Array.isArray(root["mediaDetails"]) ? root["mediaDetails"] : [];

  for (const media of mediaDetails) {
    if (!isRecord(media)) continue;
    const mediaType = media["type"];
    const originalInfo = isRecord(media["original_info"]) ? media["original_info"] : undefined;
    const width = typeof originalInfo?.["width"] === "number" ? originalInfo["width"] : undefined;
    const height = typeof originalInfo?.["height"] === "number" ? originalInfo["height"] : undefined;
    const mediaUrlHttps = typeof media["media_url_https"] === "string" ? (media["media_url_https"] as string) : "";

    if (mediaType === "photo") {
      if (mediaUrlHttps) {
        items.push({
          type: "image",
          url: normalizeImageUrl(mediaUrlHttps),
          width,
          height,
        });
      }
    } else if (mediaType === "video") {
      const videoInfo = isRecord(media["video_info"]) ? media["video_info"] : undefined;
      const variants = Array.isArray(videoInfo?.["variants"]) ? (videoInfo!["variants"] as unknown[]) : [];
      const mp4Variants = variants
        .filter((v): v is Record<string, unknown> => isRecord(v) && v["content_type"] === "video/mp4" && typeof v["url"] === "string")
        .sort((a, b) => ((Number(b["bitrate"]) || 0) - (Number(a["bitrate"]) || 0)));

      const best = mp4Variants[0];
      if (best && typeof best["url"] === "string") {
        const item: XItem = {
          type: "video",
          url: best["url"] as string,
          posterUrl: mediaUrlHttps ? normalizeImageUrl(mediaUrlHttps) : undefined,
          width,
          height,
        };
        const durationMillis = typeof videoInfo?.["duration_millis"] === "number" ? (videoInfo["duration_millis"] as number) : 0;
        if (durationMillis > 0) {
          item.duration = Math.round((durationMillis / 1000) * 1000) / 1000;
        }
        items.push(item);
      }
    } else if (mediaType === "animated_gif") {
      const videoInfo = isRecord(media["video_info"]) ? media["video_info"] : undefined;
      const variants = Array.isArray(videoInfo?.["variants"]) ? (videoInfo!["variants"] as unknown[]) : [];
      const mp4Variants = variants
        .filter((v): v is Record<string, unknown> => isRecord(v) && v["content_type"] === "video/mp4" && typeof v["url"] === "string")
        .sort((a, b) => ((Number(b["bitrate"]) || 0) - (Number(a["bitrate"]) || 0)));

      const best = mp4Variants[0];
      if (best && typeof best["url"] === "string") {
        items.push({
          type: "video",
          isGif: true,
          url: best["url"] as string,
          posterUrl: mediaUrlHttps ? normalizeImageUrl(mediaUrlHttps) : undefined,
          width,
          height,
        });
      }
    }
  }

  const post: XPost = {
    platform: "x",
    id: idStr,
    url: canonicalUrl,
    author: {
      name,
      id: screenName || undefined,
    },
    caption,
    publishedAt,
    items,
  };

  return { ok: true, data: post };
}
