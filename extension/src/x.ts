// Pure-function X (Twitter) post parser.
//
// Runs on a JSON string (or parsed object) plus the page URL, with no DOM
// or browser APIs, so the same code works in content scripts, App JS runtime,
// and in Vitest.
// Implements the X section of spec/parsing.md.

export type XErrorCode =
  | "LOGIN_REQUIRED"
  | "AGE_NOT_SET"
  | "AGE_RESTRICTED"
  | "PROTECTED"
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

/** User-facing copy for each X access outcome; the App shows `zh`. */
export const X_ERROR_COPY: Record<
  "LOGIN_REQUIRED" | "AGE_NOT_SET" | "AGE_RESTRICTED" | "PROTECTED" | "PRIVATE_OR_UNAVAILABLE",
  { zh: string; en: string }
> = {
  LOGIN_REQUIRED: {
    zh: "该内容需要登录 X 才能查看",
    en: "Log in to X to view this post.",
  },
  AGE_NOT_SET: {
    zh: "该内容需要你的 X 账号先设置出生日期（年龄）后才能查看",
    en: "Add your date of birth to your X account to view this post.",
  },
  AGE_RESTRICTED: {
    zh: "该帖子有年龄限制，需要登录已完成年龄验证的 X 账号才能查看",
    en: "This post is age-restricted. Log in with an age-verified X account to view it.",
  },
  PROTECTED: {
    zh: "该帖子来自受保护的账号，只有获准的关注者可以查看",
    en: "This post is from a protected account; only approved followers can view it.",
  },
  PRIVATE_OR_UNAVAILABLE: {
    zh: "帖子不可用：可能已删除、设为私密，或需要登录 X 才能查看",
    en: "Post unavailable: it may be deleted, private, or require logging in to X.",
  },
};

/** Shown when a logged-in session still receives an age restriction. */
export const X_SENSITIVE_MEDIA_HINT = {
  zh: "该帖子有年龄限制。已登录 X 仍无法查看时，请在 X 的“设置 → 隐私和安全 → 你看到的内容”中开启“显示可能包含敏感内容的媒体”，并确认账号已完成年龄验证",
  en: "This post is age-restricted. If it stays unavailable while logged in, turn on \"Display media that may contain sensitive content\" under X Settings → Privacy and safety → Content you see, and confirm your account's age.",
};

/** Shown when X answers as logged out although EasySave holds an X session. */
export const X_SESSION_EXPIRED = {
  zh: "X 登录状态已失效，请在 EasySave 中重新登录 X 后重试",
  en: "Your X session has expired. Log in to X again in EasySave and retry.",
};

function xFailure(code: keyof typeof X_ERROR_COPY): XResult {
  return { ok: false, error: { code, message: X_ERROR_COPY[code].zh } };
}

/**
 * Classify an unavailable tweet result (syndication or GraphQL). Returns
 * undefined when the object is not an unavailable result.
 */
export function classifyXUnavailable(result: Record<string, unknown>): XResult | undefined {
  const typename = result["__typename"];
  const reason = typeof result["reason"] === "string" ? result["reason"] : "";
  if (typename === "TweetUnavailable" || (typename === undefined && reason)) {
    switch (reason) {
      case "NsfwLoggedOut": return xFailure("LOGIN_REQUIRED");
      case "NsfwViewerHasNoStatedAge": return xFailure("AGE_NOT_SET");
      case "NsfwViewerIsUnderage": return xFailure("AGE_RESTRICTED");
      case "Protected": return xFailure("PROTECTED");
    }
    if (/log.?in|sign.?in|authentication/i.test(reason)) return xFailure("LOGIN_REQUIRED");
    if (/age/i.test(reason)) return xFailure("AGE_RESTRICTED");
    return typename === "TweetUnavailable" ? xFailure("PRIVATE_OR_UNAVAILABLE") : undefined;
  }
  if (typename === "TweetTombstone") {
    const text = tombstoneText(result);
    if (/^age.restricted/i.test(text.trim())) return xFailure("AGE_RESTRICTED");
    if (/(?:log|sign)\s*in\b/i.test(text)) return xFailure("LOGIN_REQUIRED");
    return xFailure("PRIVATE_OR_UNAVAILABLE");
  }
  return undefined;
}

function tombstoneText(result: Record<string, unknown>): string {
  const tombstone = result["tombstone"];
  const textObj = isRecord(tombstone) ? tombstone["text"] : undefined;
  return isRecord(textObj) && typeof textObj["text"] === "string" ? textObj["text"] as string : "";
}

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
    if (trimmed.startsWith('<')) {
      const visible = trimmed.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '')
        .replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ');
      if (/(?:sign|log)\s*in\s+to\s+(?:view|see|access)\s+(?:this\s+)?(?:post|content)|(?:age.restricted|verify\s+your\s+age)|登录.{0,8}(?:查看|浏览)(?:此|该)|年龄验证/i.test(visible)) {
        return xFailure("LOGIN_REQUIRED");
      }
    }
    if (trimmed.length === 0) return xFailure("PRIVATE_OR_UNAVAILABLE");
    try {
      root = JSON.parse(trimmed);
    } catch {
      return xFailure("PRIVATE_OR_UNAVAILABLE");
    }
  } else {
    root = input;
  }

  if (!isRecord(root) || Object.keys(root).length === 0) {
    return xFailure("PRIVATE_OR_UNAVAILABLE");
  }

  // Only explicit access-gate evidence is classified as requiring login.
  // A blank syndication response cannot distinguish deletion from restriction.
  const errors = Array.isArray(root['errors']) ? root['errors'] : [];
  const restricted = /nsfwloggedout|age.?restrict|age.?verif|log.?in|sign.?in|authentication/i;
  if (errors.some((error) => isRecord(error) &&
      ([32, 215, 239].includes(Number(error['code'])) ||
       restricted.test(typeof error['message'] === 'string' ? error['message'] : '')))) {
    return xFailure("LOGIN_REQUIRED");
  }

  // Unavailable results: TweetUnavailable reasons and tombstones.
  const unavailable = classifyXUnavailable(root);
  if (unavailable) return unavailable;

  // Error responses from syndication endpoint
  if (Array.isArray(root["errors"]) && (root["errors"] as unknown[]).length > 0) {
    return xFailure("PRIVATE_OR_UNAVAILABLE");
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

/** The focal tweet result in captured TweetResultByRestId / TweetDetail responses. */
function graphqlTweetResult(responses: unknown[], id: string): Record<string, unknown> | undefined {
  for (const response of responses) {
    if (!isRecord(response) || !isRecord(response["data"])) continue;
    const data = response["data"] as Record<string, unknown>;
    const byRestId = isRecord(data["tweetResult"]) ? (data["tweetResult"] as Record<string, unknown>)["result"] : undefined;
    if (isRecord(byRestId)) return byRestId;
    const thread = data["threaded_conversation_with_injections_v2"];
    const instructions = isRecord(thread) && Array.isArray(thread["instructions"]) ? thread["instructions"] as unknown[] : [];
    for (const instruction of instructions) {
      const entries = isRecord(instruction) && Array.isArray(instruction["entries"]) ? instruction["entries"] as unknown[] : [];
      for (const entry of entries) {
        if (!isRecord(entry) || entry["entryId"] !== `tweet-${id}`) continue;
        const content = entry["content"];
        const itemContent = isRecord(content) ? content["itemContent"] : undefined;
        const results = isRecord(itemContent) ? itemContent["tweet_results"] : undefined;
        const result = isRecord(results) ? results["result"] : undefined;
        if (isRecord(result)) return result;
      }
    }
  }
  return undefined;
}

function unwrapVisibility(result: Record<string, unknown>): Record<string, unknown> {
  return result["__typename"] === "TweetWithVisibilityResults" && isRecord(result["tweet"])
    ? result["tweet"] as Record<string, unknown>
    : result;
}

/**
 * Parse the focal post from X web GraphQL responses captured in a logged-in
 * page. The tweet's legacy media carries the same fields as syndication
 * mediaDetails, so it is mapped onto that shape and parsed by [parseX].
 */
export function parseXGraphql(responses: unknown[], pageUrl: string): XResult {
  const id = extractTweetId(pageUrl);
  if (!id) return { ok: false, error: { code: "UNSUPPORTED_URL", message: "Unable to extract tweet ID." } };
  const found = graphqlTweetResult(responses, id);
  if (!found) {
    return { ok: false, error: { code: "INVALID_PAGE", message: "X page returned no post data." } };
  }
  const result = unwrapVisibility(found);
  const unavailable = classifyXUnavailable(result);
  if (unavailable) return unavailable;
  const legacy = isRecord(result["legacy"]) ? result["legacy"] as Record<string, unknown> : undefined;
  if (!legacy) return xFailure("PRIVATE_OR_UNAVAILABLE");
  const core = isRecord(result["core"]) ? result["core"] as Record<string, unknown> : undefined;
  const userResults = core && isRecord(core["user_results"]) ? core["user_results"] as Record<string, unknown> : undefined;
  const user = userResults && isRecord(userResults["result"]) ? userResults["result"] as Record<string, unknown> : undefined;
  const userLegacy = user && isRecord(user["legacy"]) ? user["legacy"] as Record<string, unknown> : {};
  const userCore = user && isRecord(user["core"]) ? user["core"] as Record<string, unknown> : {};
  const pick = (key: string) => typeof userLegacy[key] === "string" ? userLegacy[key] as string
    : typeof userCore[key] === "string" ? userCore[key] as string : undefined;
  const entities = isRecord(legacy["extended_entities"]) ? legacy["extended_entities"] as Record<string, unknown>
    : isRecord(legacy["entities"]) ? legacy["entities"] as Record<string, unknown> : {};
  const media = Array.isArray(entities["media"]) ? entities["media"] as unknown[] : [];
  const noteTweet = isRecord(result["note_tweet"]) ? result["note_tweet"] as Record<string, unknown> : undefined;
  const noteResults = noteTweet && isRecord(noteTweet["note_tweet_results"]) ? noteTweet["note_tweet_results"] as Record<string, unknown> : undefined;
  const noteResult = noteResults && isRecord(noteResults["result"]) ? noteResults["result"] as Record<string, unknown> : undefined;
  let text = typeof noteResult?.["text"] === "string" ? noteResult["text"] as string
    : typeof legacy["full_text"] === "string" ? legacy["full_text"] as string : "";
  // The trailing t.co link of attached media is not part of the caption.
  for (const item of media) {
    const link = isRecord(item) && typeof item["url"] === "string" ? item["url"] as string : "";
    if (link && text.endsWith(link)) text = text.slice(0, -link.length).trimEnd();
  }
  const restId = typeof result["rest_id"] === "string" ? result["rest_id"] as string : id;
  return parseX({
    id_str: restId,
    user: { screen_name: pick("screen_name"), name: pick("name") },
    text,
    created_at: legacy["created_at"],
    mediaDetails: media,
  }, pageUrl);
}

export interface XProbe {
  source: "syndication" | "graphql";
  shape: "tweet" | "tombstone" | "unavailable" | "errors" | "empty" | "none" | "unknown";
  typename?: string;
  wrapped?: boolean;
  reason?: string;
  tombstone?: string;
  fields: string[];
  mediaCount?: number;
}

const SHORT_TOKEN = /^[A-Za-z0-9_]{1,48}$/;

function shortToken(value: unknown): string | undefined {
  return typeof value === "string" && SHORT_TOKEN.test(value) ? value : undefined;
}

/** Data shape of an X response: category, type names and field names only. */
export function xProbe(input: unknown, source: XProbe["source"], pageUrl: string): XProbe {
  let root: unknown = input;
  if (source === "syndication") {
    if (typeof input !== "string" || input.trim() === "") return { source, shape: "empty", fields: [] };
    try { root = JSON.parse(input); } catch { return { source, shape: "unknown", fields: [] }; }
  }
  let result: Record<string, unknown> | undefined;
  let fields: string[] = [];
  if (source === "graphql") {
    const responses = Array.isArray(root) ? root : [];
    const id = extractTweetId(pageUrl) ?? "";
    result = graphqlTweetResult(responses, id);
    if (!result) return { source, shape: "none", fields: [] };
  } else {
    if (!isRecord(root)) return { source, shape: "unknown", fields: [] };
    if (Object.keys(root).length === 0) return { source, shape: "empty", fields: [] };
    result = root;
  }
  fields = Object.keys(result).filter((key) => SHORT_TOKEN.test(key)).sort().slice(0, 24);
  const wrapped = result["__typename"] === "TweetWithVisibilityResults";
  const inner = unwrapVisibility(result);
  const typename = shortToken(inner["__typename"]);
  const probe: XProbe = { source, shape: "unknown", fields };
  if (typename) probe.typename = typename;
  if (wrapped) probe.wrapped = true;
  const reason = shortToken(inner["reason"]);
  if (reason) probe.reason = reason;
  if (typename === "TweetTombstone") {
    probe.shape = "tombstone";
    probe.tombstone = tombstoneText(inner).slice(0, 40);
  } else if (typename === "TweetUnavailable" || (!typename && reason)) {
    probe.shape = "unavailable";
  } else if (Array.isArray(inner["errors"]) && !isRecord(inner["legacy"]) && !inner["id_str"]) {
    probe.shape = "errors";
  } else if (isRecord(inner["legacy"]) || inner["id_str"] !== undefined) {
    probe.shape = "tweet";
    const legacy = isRecord(inner["legacy"]) ? inner["legacy"] as Record<string, unknown> : undefined;
    const entities = legacy && isRecord(legacy["extended_entities"]) ? legacy["extended_entities"] as Record<string, unknown> : undefined;
    const media = entities ? entities["media"] : inner["mediaDetails"];
    probe.mediaCount = Array.isArray(media) ? media.length : 0;
  }
  return probe;
}
