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

interface VideoCandidate {
  url: string;
  watermarked: boolean;
  width: number;
  height: number;
}

const NOTE_ID_PATTERN = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-f0-9]{24})/i;
const STATE_MARKERS = ["__INITIAL_STATE__", "__NEXT_DATA__", "__NUXT__"];

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

/** Extract the first balanced `{...}` JSON object after a marker string. */
function extractJsonAfter(html: string, marker: string): unknown | undefined {
  let from = 0;
  for (;;) {
    const at = html.indexOf(marker, from);
    if (at < 0) return undefined;
    const scanned = scanBalancedObject(html, at + marker.length);
    if (!scanned) return undefined;
    try {
      return JSON.parse(html.slice(scanned.start, scanned.end + 1)) as unknown;
    } catch {
      from = scanned.end + 1;
    }
  }
}

/**
 * Targeted fallback for pages whose full embedded state is not strict JSON
 * (e.g. it contains JS `undefined`). Extracts just the `noteDetailMap`
 * subtree and reads the wanted entry from it.
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
    try {
      const map = JSON.parse(html.slice(scanned.start, scanned.end + 1)) as Record<string, unknown>;
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
    } catch {
      // Unparseable map; keep scanning for another occurrence.
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

function collectVideoCandidates(video: unknown): VideoCandidate[] {
  if (!isRecord(video)) return [];
  const out: VideoCandidate[] = [];
  const buckets: unknown[] = [video["media"], video["stream"]].filter((v) => v !== undefined);
  if (typeof video["mediaV2"] === "string") {
    try {
      const parsed = JSON.parse(video["mediaV2"] as string) as Record<string, unknown>;
      if (isRecord(parsed) && parsed["stream"] !== undefined) buckets.push(parsed["stream"]);
    } catch {
      // Ignore unparseable app-media payloads; other buckets may still apply.
    }
  }
  for (const bucket of buckets) {
    const streamObj = isRecord(bucket) && bucket["stream"] !== undefined ? bucket["stream"] : bucket;
    for (const entry of streamEntries(streamObj)) {
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
      if (urls.length === 0) continue;
      const width = typeof entry["width"] === "number" ? (entry["width"] as number) : 0;
      const height = typeof entry["height"] === "number" ? (entry["height"] as number) : 0;
      out.push({ url: urls[0], watermarked, width, height });
    }
  }
  return out;
}

/** Highest resolution wins; watermarked renditions lose ties and lose to clean ones. */
function bestVideo(candidates: VideoCandidate[]): VideoCandidate | undefined {
  return [...candidates].sort((a, b) => {
    if (a.watermarked !== b.watermarked) return a.watermarked ? 1 : -1;
    return b.width * b.height - a.width * a.height;
  })[0];
}

function imageUrlOf(entry: Record<string, unknown>): string | undefined {
  const direct = pickString(entry, ["urlDefault", "url"]);
  if (direct) return direct;
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
    /xiaohongshu\.com|xhslink|__INITIAL_STATE__/.test(pageUrl) ||
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

  const images = (Array.isArray(note["imageList"]) ? note["imageList"] : note["images"] ?? []) as unknown[];
  const noteVideoCandidates = collectVideoCandidates(note["video"]);

  const items: XhsItem[] = [];
  let noteVideoEmitted = false;
  const emitNoteVideo = (): void => {
    if (noteVideoEmitted) return;
    const best = bestVideo(noteVideoCandidates);
    if (!best) return;
    noteVideoEmitted = true;
    const item: XhsItem = { type: "video", url: best.url };
    if (best.width > 0) item.width = best.width;
    if (best.height > 0) item.height = best.height;
    items.push(item);
  };

  images.forEach((raw) => {
    if (!isRecord(raw)) return;
    const entry = raw as Record<string, unknown>;
    const img = imageUrlOf(entry);
    const livePhoto = entry["livePhoto"];
    const ownCandidates = [
      ...streamEntries(entry["stream"]),
      ...(isRecord(livePhoto) && livePhoto["stream"] !== undefined
        ? streamEntries(livePhoto["stream"])
        : []),
    ]
      .map((e) => collectVideoCandidates({ stream: { x: [e] } }))
      .flat();
    const own = bestVideo(ownCandidates);
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
    if (img && noteVideoCandidates.length > 0 && images.length === 1) {
      const best = bestVideo(noteVideoCandidates);
      if (best) {
        noteVideoEmitted = true;
        const item: XhsItem = { type: "live", url: img, videoUrl: best.url };
        if (best.width > 0) item.width = best.width;
        if (best.height > 0) item.height = best.height;
        items.push(item);
        return;
      }
    }
    if (img) {
      const item: XhsItem = { type: "image", url: img };
      const w = num(entry["width"]);
      const h = num(entry["height"]);
      if (w !== undefined) item.width = w;
      if (h !== undefined) item.height = h;
      items.push(item);
      return;
    }
  });

  if (items.length === 0 && noteVideoCandidates.length > 0) {
    emitNoteVideo();
  } else if (noteVideoCandidates.length > 0 && !noteVideoEmitted && images.length !== 1) {
    emitNoteVideo();
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
