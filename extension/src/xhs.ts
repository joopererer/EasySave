// Pure-function Xiaohongshu note parser.
//
// Runs on an HTML string plus the page URL, with no DOM or browser APIs,
// so the same code works in content scripts and in Vitest.
// Implements the XHS section of spec/parsing.md.

export type XhsErrorCode =
  | "LOGIN_REQUIRED"
  | "PRIVATE_OR_UNAVAILABLE"
  | "BLOCKED"
  | "INVALID_PAGE";

export interface XhsError {
  code: XhsErrorCode;
  message: string;
}

export interface XhsAuthor {
  name?: string;
  id?: string;
}

export type XhsItemType = "image" | "video" | "live";

export interface XhsItem {
  type: XhsItemType;
  url: string;
  videoUrl?: string;
  width?: number;
  height?: number;
}

export interface XhsNote {
  platform: "xhs";
  id: string;
  url: string;
  author: XhsAuthor;
  title?: string;
  caption?: string;
  publishedAt?: string;
  items: XhsItem[];
}

export type XhsResult =
  | { ok: true; data: XhsNote }
  | { ok: false; error: XhsError };

export interface ResolvedVideo {
  url: string;
  width?: number;
  height?: number;
}

interface VideoCandidate extends ResolvedVideo {
  watermarked: boolean;
}

const NOTE_ID_PATTERN = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-f0-9]{24})/i;
const STATE_MARKERS = ["__INITIAL_STATE__", "__NEXT_DATA__", "__NUXT__"];
const XHS_CDN_SUFFIX = ".xhscdn.com";
const XIAOHONGSHU_SUFFIX = ".xiaohongshu.com";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function nonBlank(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function pickString(obj: Record<string, unknown>, keys: string[]): string | undefined {
  for (const key of keys) {
    const value = obj[key];
    if (nonBlank(value)) return value;
  }
  return undefined;
}

function toIsoUtc(ms: number): string {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function toHttps(url: string): string {
  return url.startsWith("http://") ? `https://${url.slice("http://".length)}` : url;
}

/**
 * Rewrite an XHS CDN image URL to its canonical original form:
 * strip the `!style` suffix and serve through ci.xiaohongshu.com.
 * Non-XHS hosts are returned with only the scheme upgraded to https.
 */
export function transformImageUrl(url: string): string {
  const https = toHttps(url);
  let host = "";
  let path = "";
  try {
    const parsed = new URL(https);
    host = parsed.hostname.toLowerCase();
    path = parsed.pathname;
  } catch {
    return https;
  }
  if (!host.endsWith(XHS_CDN_SUFFIX) && !host.endsWith(XIAOHONGSHU_SUFFIX)) return https;
  const withoutStyle = path.split("!")[0];
  const parts = withoutStyle.split("/").filter((part) => part.length > 0);
  const token =
    parts.length > 2 && /^[a-fA-F0-9]{32}$/.test(parts[1])
      ? parts.slice(2).join("/")
      : parts.join("/");
  if (!token) return https;
  return `https://ci.xiaohongshu.com/${token}`;
}

/** Scan a balanced `{...}` object starting at the first `{` at/after `from`. */
function scanBalancedObject(html: string, from: number): { start: number; end: number } | undefined {
  const start = html.indexOf("{", from);
  if (start < 0) return undefined;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < html.length; i++) {
    const c = html[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === '"') inString = false;
    } else if (c === '"') {
      inString = true;
    } else if (c === "{") {
      depth++;
    } else if (c === "}") {
      depth--;
      if (depth === 0) return { start, end: i };
    }
  }
  return undefined;
}

/**
 * Replace JS `undefined` literals that appear outside string literals with
 * `null`, so embedded state containing non-JSON JS can still be parsed.
 * Text inside string literals (including the word "undefined") is untouched.
 */
export function sanitizeJsUndefined(source: string): string {
  let out = "";
  let i = 0;
  let inString = false;
  let escaped = false;
  const isIdChar = (c: string): boolean => /[A-Za-z0-9_$]/.test(c);
  while (i < source.length) {
    const c = source[i];
    if (inString) {
      out += c;
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === '"') inString = false;
      i++;
      continue;
    }
    if (c === '"') {
      inString = true;
      out += c;
      i++;
      continue;
    }
    if (
      source.startsWith("undefined", i) &&
      (i === 0 || !isIdChar(source[i - 1])) &&
      (i + "undefined".length >= source.length || !isIdChar(source[i + "undefined".length]))
    ) {
      out += "null";
      i += "undefined".length;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

function tryParseJson(text: string): unknown | undefined {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
}

/** Extract the first balanced `{...}` JSON object after a marker string. */
function extractJsonAfter(html: string, marker: string): unknown | undefined {
  let from = 0;
  for (;;) {
    const at = html.indexOf(marker, from);
    if (at < 0) return undefined;
    const scanned = scanBalancedObject(html, at + marker.length);
    if (!scanned) return undefined;
    const raw = html.slice(scanned.start, scanned.end + 1);
    const parsed = tryParseJson(raw) ?? tryParseJson(sanitizeJsUndefined(raw));
    if (parsed !== undefined) return parsed;
    from = scanned.end + 1;
  }
}

/**
 * Targeted fallback for pages whose embedded state cannot be parsed even
 * after sanitizing. Extracts just the `noteDetailMap` subtree.
 */
function extractNoteDetailEntry(html: string, wantedId: string | undefined): Record<string, unknown> | undefined {
  let from = 0;
  for (;;) {
    const at = html.indexOf('"noteDetailMap"', from);
    if (at < 0) return undefined;
    const colon = html.indexOf(":", at + '"noteDetailMap"'.length);
    if (colon < 0) return undefined;
    const scanned = scanBalancedObject(html, colon + 1);
    if (!scanned) return undefined;
    const raw = html.slice(scanned.start, scanned.end + 1);
    const map = tryParseJson(raw) ?? tryParseJson(sanitizeJsUndefined(raw));
    if (isRecord(map)) {
      if (wantedId && isRecord(map[wantedId])) {
        const entry = map[wantedId] as Record<string, unknown>;
        return isRecord(entry["note"]) ? (entry["note"] as Record<string, unknown>) : entry;
      }
      if (!wantedId) {
        for (const entry of Object.values(map)) {
          if (!isRecord(entry)) continue;
          const note = isRecord(entry["note"])
            ? (entry["note"] as Record<string, unknown>)
            : entry;
          if (isNoteShaped(note)) return note;
        }
      }
    }
    from = scanned.end + 1;
  }
}

function isNoteShaped(obj: Record<string, unknown>): boolean {
  if (nonBlank(obj["noteId"])) {
    if (
      nonBlank(obj["title"]) ||
      nonBlank(obj["desc"]) ||
      nonBlank(obj["description"]) ||
      Array.isArray(obj["imageList"]) ||
      Array.isArray(obj["images"]) ||
      isRecord(obj["video"])
    ) {
      return true;
    }
  }
  const list = obj["imageList"] ?? obj["images"];
  if (Array.isArray(list) && list.length > 0) {
    const first = list[0];
    if (isRecord(first) && ("urlDefault" in first || "url" in first || "traceId" in first || "infoList" in first)) {
      return true;
    }
  }
  const video = obj["video"];
  if (isRecord(video) && ("consumer" in video || "media" in video || "mediaV2" in video || "stream" in video || "originVideoKey" in video)) {
    return true;
  }
  return false;
}

/** Depth-first search with cycle protection for a note object. */
function deepFindNote(root: unknown, wantedId: string | undefined): Record<string, unknown> | undefined {
  const seen = new Set<object>();
  let fallback: Record<string, unknown> | undefined;
  const visit = (node: unknown, depth: number): void => {
    if (!isRecord(node) && !Array.isArray(node)) return;
    const obj = node as Record<string, unknown> | unknown[];
    if (seen.has(obj as object) || depth > 24) return;
    seen.add(obj as object);
    if (isRecord(node)) {
      if (nonBlank(node["noteId"]) && node["noteId"] === wantedId) {
        fallback = undefined;
        throw { found: node };
      }
      if (!fallback && !wantedId && isNoteShaped(node)) fallback = node;
      else if (!fallback && wantedId && isNoteShaped(node) && !nonBlank(node["noteId"])) fallback = node;
      for (const value of Object.values(node)) visit(value, depth + 1);
    } else {
      for (const value of node as unknown[]) visit(value, depth + 1);
    }
  };
  try {
    visit(root, 0);
  } catch (e) {
    if (isRecord(e) && "found" in e) return e["found"] as Record<string, unknown>;
    throw e;
  }
  return fallback;
}

function streamEntries(stream: unknown): Array<Record<string, unknown>> {
  if (!isRecord(stream)) return [];
  const out: Array<Record<string, unknown>> = [];
  for (const arr of Object.values(stream)) {
    if (Array.isArray(arr)) {
      for (const entry of arr) {
        if (isRecord(entry)) out.push(entry);
      }
    }
  }
  return out;
}

function candidateFromEntry(entry: Record<string, unknown>): VideoCandidate | undefined {
  const type = entry["streamType"] ?? entry["stream_type"];
  const desc = entry["streamDesc"] ?? entry["stream_desc"];
  const watermarked =
    type === 259 ||
    type === 309 ||
    (typeof desc === "string" && desc.toUpperCase() === "WEB_LIVEPHOTO_19");
  const urls = [
    entry["masterUrl"],
    entry["master_url"],
    ...(Array.isArray(entry["backupUrls"])
      ? (entry["backupUrls"] as unknown[])
      : Array.isArray(entry["backup_urls"])
        ? (entry["backup_urls"] as unknown[])
        : []),
    entry["url"],
  ].filter(nonBlank);
  if (urls.length === 0) return undefined;
  const width = typeof entry["width"] === "number" ? (entry["width"] as number) : 0;
  const height = typeof entry["height"] === "number" ? (entry["height"] as number) : 0;
  return { url: toHttps(urls[0]), watermarked, width, height };
}

function collectStreamCandidates(container: unknown): VideoCandidate[] {
  if (!isRecord(container)) return [];
  const streamObj =
    container["stream"] !== undefined && isRecord(container) ? container["stream"] : container;
  return streamEntries(streamObj)
    .map(candidateFromEntry)
    .filter((c): c is VideoCandidate => c !== undefined);
}

/**
 * Resolve the original video file. An explicitly supplied originVideoKey
 * (consumer.originVideoKey or top-level originVideoKey) wins; otherwise the
 * best non-watermarked stream rendition is used.
 */
export function resolveVideoUrl(video: unknown): ResolvedVideo | undefined {
  if (!isRecord(video)) return undefined;
  const key =
    (isRecord(video["consumer"]) ? pickString(video["consumer"] as Record<string, unknown>, ["originVideoKey"]) : undefined) ??
    pickString(video, ["originVideoKey"]);
  if (key) {
    if (/^https?:\/\//i.test(key)) return { url: toHttps(key) };
    return { url: `https://sns-video-bd.xhscdn.com/${key.replace(/^\/+/, "")}` };
  }
  const candidates: VideoCandidate[] = [];
  if (isRecord(video["media"])) {
    const media = video["media"] as Record<string, unknown>;
    if (media["stream"] !== undefined) candidates.push(...collectStreamCandidates(media["stream"]));
  }
  if (video["stream"] !== undefined) candidates.push(...collectStreamCandidates(video["stream"]));
  if (typeof video["mediaV2"] === "string") {
    try {
      const parsed = JSON.parse(video["mediaV2"] as string) as Record<string, unknown>;
      if (isRecord(parsed) && parsed["stream"] !== undefined) {
        candidates.push(...collectStreamCandidates(parsed["stream"]));
      }
    } catch {
      // Ignore unparseable app-media payloads; other buckets may still apply.
    }
  }
  const best = bestVideo(candidates);
  if (!best) return undefined;
  const resolved: ResolvedVideo = { url: best.url };
  if (best.width > 0) resolved.width = best.width;
  if (best.height > 0) resolved.height = best.height;
  return resolved;
}

/** Highest resolution wins; watermarked renditions lose to clean ones. */
function bestVideo(candidates: VideoCandidate[]): VideoCandidate | undefined {
  return [...candidates].sort((a, b) => {
    if (a.watermarked !== b.watermarked) return a.watermarked ? 1 : -1;
    return b.width * b.height - a.width * a.height;
  })[0];
}

function imageUrlOf(entry: Record<string, unknown>): string | undefined {
  const direct = pickString(entry, ["urlDefault", "url"]);
  if (direct) return transformImageUrl(direct);
  const traceId = pickString(entry, ["traceId"]);
  if (traceId) return `https://sns-img-qc.xhscdn.com/${traceId}`;
  return undefined;
}

function num(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/**
 * Parse a Xiaohongshu note page.
 * @param html Full page HTML source.
 * @param pageUrl The URL the HTML was fetched from (used to find the note id).
 */
export function parseXhs(html: string, pageUrl: string): XhsResult {
  const idMatch = NOTE_ID_PATTERN.exec(pageUrl);
  const wantedId = idMatch ? idMatch[1].toLowerCase() : undefined;

  const states: unknown[] = [];
  for (const marker of STATE_MARKERS) {
    const parsed = extractJsonAfter(html, marker);
    if (parsed !== undefined) states.push(parsed);
  }

  let note: Record<string, unknown> | undefined;
  for (const state of states) {
    if (!isRecord(state)) continue;
    const byMap =
      isRecord(state["note"]) &&
      isRecord((state["note"] as Record<string, unknown>)["noteDetailMap"])
        ? ((state["note"] as Record<string, unknown>)["noteDetailMap"] as Record<string, unknown>)[
            wantedId ?? ""
          ]
        : undefined;
    const fromMap = isRecord(byMap) && isRecord(byMap["note"])
      ? (byMap["note"] as Record<string, unknown>)
      : isRecord(byMap)
        ? byMap
        : undefined;
    if (fromMap && (!wantedId || !nonBlank(fromMap["noteId"]) || fromMap["noteId"] === wantedId)) {
      note = fromMap;
      break;
    }
    const mobile =
      isRecord(state["noteData"]) &&
      isRecord((state["noteData"] as Record<string, unknown>)["data"])
        ? ((state["noteData"] as Record<string, unknown>)["data"] as Record<string, unknown>)["noteData"]
        : undefined;
    const mobileNote = isRecord(mobile) && isRecord(mobile["note"])
      ? (mobile["note"] as Record<string, unknown>)
      : isRecord(mobile)
        ? mobile
        : undefined;
    if (
      mobileNote &&
      (!wantedId || !nonBlank(mobileNote["noteId"]) || mobileNote["noteId"] === wantedId)
    ) {
      note = mobileNote;
      break;
    }
  }
  if (!note) {
    for (const state of states) {
      note = deepFindNote(state, wantedId);
      if (note && (!wantedId || !nonBlank(note["noteId"]) || note["noteId"] === wantedId)) break;
      note = undefined;
    }
  }
  if (!note) {
    note = extractNoteDetailEntry(html, wantedId);
  }

  const looksLikeXhs =
    /xiaohongshu\.com|xhslink/.test(pageUrl) ||
    /xiaohongshu\.com|xhslink|__INITIAL_STATE__/.test(html.slice(0, 20000));
  if (!note) {
    if (looksLikeXhs) {
      return {
        ok: false,
        error: {
          code: "LOGIN_REQUIRED",
          message: "Xiaohongshu returned an authenticated-only shell without note data.",
        },
      };
    }
    return {
      ok: false,
      error: { code: "INVALID_PAGE", message: "Not a Xiaohongshu note page." },
    };
  }

  const noteId = nonBlank(note["noteId"]) ? (note["noteId"] as string) : (wantedId ?? "");
  if (!noteId) {
    return {
      ok: false,
      error: { code: "INVALID_PAGE", message: "Could not determine the note id." },
    };
  }

  const user = isRecord(note["user"])
    ? (note["user"] as Record<string, unknown>)
    : isRecord(note["author"])
      ? (note["author"] as Record<string, unknown>)
      : {};
  const author: XhsAuthor = {};
  const authorName = pickString(user, ["nickname", "nickName", "name", "userName"]);
  const authorId = pickString(user, ["userId", "user_id", "id", "redId"]);
  if (authorName) author.name = authorName;
  if (authorId) author.id = authorId;

  const rawImages = (Array.isArray(note["imageList"]) ? note["imageList"] : (note["images"] ?? [])) as unknown[];
  const images = rawImages.filter(isRecord);

  const noteType = typeof note["type"] === "string" ? (note["type"] as string) : "";
  const firstHasStream =
    images.length > 0 && (images[0]["stream"] !== undefined || images[0]["livePhoto"] !== undefined);
  const hasMainVideo =
    isRecord(note["video"]) &&
    (nonBlank((note["video"] as Record<string, unknown>)["originVideoKey"]) ||
      (isRecord((note["video"] as Record<string, unknown>)["consumer"]) &&
        nonBlank(
          ((note["video"] as Record<string, unknown>)["consumer"] as Record<string, unknown>)[
            "originVideoKey"
          ],
        )) ||
      collectStreamCandidates((note["video"] as Record<string, unknown>)["media"]).length > 0 ||
      collectStreamCandidates((note["video"] as Record<string, unknown>)["stream"]).length > 0 ||
      (typeof (note["video"] as Record<string, unknown>)["mediaV2"] === "string" &&
        (((note["video"] as Record<string, unknown>)["mediaV2"] as string).includes("master_url") ||
          ((note["video"] as Record<string, unknown>)["mediaV2"] as string).includes("masterUrl"))));
  const isVideoNote =
    noteType === "video" || (noteType === "" && hasMainVideo && images.length <= 1 && !firstHasStream);

  const items: XhsItem[] = [];

  if (isVideoNote) {
    const resolved = resolveVideoUrl(note["video"]);
    if (resolved) {
      const item: XhsItem = { type: "video", url: resolved.url };
      if (resolved.width !== undefined) item.width = resolved.width;
      if (resolved.height !== undefined) item.height = resolved.height;
      items.push(item);
    } else if (images.length === 1) {
      const img = imageUrlOf(images[0]);
      if (img) {
        const item: XhsItem = { type: "image", url: img };
        const w = num(images[0]["width"]);
        const h = num(images[0]["height"]);
        if (w !== undefined) item.width = w;
        if (h !== undefined) item.height = h;
        items.push(item);
      }
    }
  } else {
    const noteVideo = resolveVideoUrl(note["video"]);
    let noteVideoEmitted = false;
    images.forEach((entry) => {
      const img = imageUrlOf(entry);
      const livePhoto = entry["livePhoto"];
      const entryKey =
        pickString(entry, ["originVideoKey"]) ??
        (isRecord(livePhoto) ? pickString(livePhoto, ["originVideoKey"]) : undefined);
      const entryKeyUrl = entryKey
        ? /^https?:\/\//i.test(entryKey)
          ? toHttps(entryKey)
          : `https://sns-video-bd.xhscdn.com/${entryKey.replace(/^\/+/, "")}`
        : undefined;
      const ownCandidates = [
        ...collectStreamCandidates(entry["stream"]),
        ...(isRecord(livePhoto) && livePhoto["stream"] !== undefined
          ? collectStreamCandidates(livePhoto["stream"])
          : []),
      ];
      const own = entryKeyUrl
        ? { url: entryKeyUrl, watermarked: false, width: 0, height: 0 }
        : bestVideo(ownCandidates);
      if (own && img) {
        const item: XhsItem = { type: "live", url: img, videoUrl: own.url };
        const w = num(entry["width"]);
        const h = num(entry["height"]);
        if (w !== undefined) item.width = w;
        if (h !== undefined) item.height = h;
        items.push(item);
        return;
      }
      if (own && !img) {
        items.push({ type: "video", url: own.url });
        return;
      }
      if (img) {
        const item: XhsItem = { type: "image", url: img };
        const w = num(entry["width"]);
        const h = num(entry["height"]);
        if (w !== undefined) item.width = w;
        if (h !== undefined) item.height = h;
        items.push(item);
      }
    });
    if (noteVideo && !noteVideoEmitted && images.length !== 1) {
      noteVideoEmitted = true;
      const item: XhsItem = { type: "video", url: noteVideo.url };
      if (noteVideo.width !== undefined) item.width = noteVideo.width;
      if (noteVideo.height !== undefined) item.height = noteVideo.height;
      items.push(item);
    }
  }

  if (items.length === 0) {
    return {
      ok: false,
      error: {
        code: "LOGIN_REQUIRED",
        message: "Xiaohongshu note has no extractable media.",
      },
    };
  }

  const data: XhsNote = {
    platform: "xhs",
    id: noteId,
    url: `https://www.xiaohongshu.com/explore/${noteId}`,
    author,
  };
  if (nonBlank(note["title"])) data.title = note["title"] as string;
  const caption = pickString(note, ["desc", "description"]);
  if (caption !== undefined) data.caption = caption;
  if (typeof note["time"] === "number" && Number.isFinite(note["time"])) {
    data.publishedAt = toIsoUtc(note["time"] as number);
  }
  data.items = items;
  return { ok: true, data };
}
