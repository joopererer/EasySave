// Pure-function Xiaohongshu note parser.
//
// Runs on an HTML string plus the page URL, with no DOM or browser APIs,
// so the same code works in content scripts and in Vitest.
// Implements the XHS section of spec/parsing.md.

import { xhsAiLabel, type AiLabel, unknownAiLabel } from './ai-label';

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
  fallbacks?: string[];
  /** Still-image cover for a video item (XHS `imageList[0]`). */
  posterUrl?: string;
  thumbnailUrl?: string;
  width?: number;
  height?: number;
  /** Video length in seconds, from `video.capa.duration`. Absent when unknown. */
  duration?: number;
}

export interface XhsNote {
  aiLabel?: AiLabel;
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
  /** Other clean renditions not known to lack audio, best first. */
  alternates?: string[];
}

/** Whether a rendition declares an audio track: yes, no, or no audio fields. */
export type AudioState = "yes" | "no" | "unknown";

interface VideoCandidate {
  url: string;
  watermarked: boolean;
  width: number;
  height: number;
  audio: AudioState;
  bitrate: number;
  origin?: boolean;
}

/** Short, content-free description of one candidate stream. */
export interface XhsStreamProbeEntry {
  bucket: string;
  streamType?: number;
  codec?: string;
  width: number;
  height: number;
  bitrate: number;
  audio: AudioState;
  audioCodec?: string;
  audioChannels?: number;
  audioBitrate?: number;
  audioFields: string[];
  watermarked: boolean;
  selected: boolean;
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
  return bucketedStreamEntries(stream).map(([, entry]) => entry);
}

function bucketedStreamEntries(stream: unknown): Array<[string, Record<string, unknown>]> {
  if (!isRecord(stream)) return [];
  const out: Array<[string, Record<string, unknown>]> = [];
  for (const [bucket, arr] of Object.entries(stream)) {
    if (Array.isArray(arr)) {
      for (const entry of arr) {
        if (isRecord(entry)) out.push([bucket, entry]);
      }
    }
  }
  return out;
}

/**
 * Audio declared by a stream entry. Any positive audio field means a track;
 * audio fields that are all empty or zero mean none; no audio field at all
 * leaves it unknown (the downloader then checks the file).
 */
export function audioStateOf(entry: Record<string, unknown>): AudioState {
  const codec = entry["audioCodec"] ?? entry["audio_codec"];
  const channels = num(entry["audioChannels"] ?? entry["audio_channels"]);
  const bitrate = num(entry["audioBitrate"] ?? entry["audio_bitrate"]);
  if (codec === undefined && channels === undefined && bitrate === undefined) return "unknown";
  const namedCodec = typeof codec === "string" && codec.trim() !== "" &&
    !/^(?:none|null|unknown|0)$/i.test(codec.trim());
  return namedCodec || (channels ?? 0) > 0 || (bitrate ?? 0) > 0 ? "yes" : "no";
}

/**
 * Media kind of a Xiaohongshu CDN URL, read from its host, path shape and any
 * file extension. `undefined` means "cannot tell": every caller keeps such a
 * URL, so a CDN shape this list has not seen yet never costs a real file.
 *
 * A Live photo's still is served from the image bucket (`sns-img-*`,
 * `sns-webpic-*`, `ci.xiaohongshu.com`, or a `.heic` / `.jpg` path), while its
 * motion clip comes from `sns-video-*` or a `/stream/` path.
 */
export function xhsMediaKindOf(url: string): "image" | "video" | undefined {
  let parsed: URL;
  try {
    parsed = new URL(toHttps(url));
  } catch {
    return undefined;
  }
  const host = parsed.hostname.toLowerCase();
  const path = parsed.pathname.toLowerCase();
  if (path.includes("/stream/") || /\.(?:mp4|mov|m4v|webm)$/.test(path)) return "video";
  if (/^sns-video-/.test(host)) return "video";
  if (/\.(?:jpe?g|png|webp|gif|heic|heif|avif)$/.test(path)) return "image";
  if (/^sns-(?:img|webpic)-/.test(host) || host === "ci.xiaohongshu.com") return "image";
  return undefined;
}

/** A still image must never fill a video slot. */
function isImageUrl(url: string): boolean {
  return xhsMediaKindOf(url) === "image";
}

/** A motion clip must never fill a still-image slot. */
function isVideoUrl(url: string): boolean {
  return xhsMediaKindOf(url) === "video";
}

function candidateFromEntry(entry: Record<string, unknown>): VideoCandidate | undefined {
  const type = entry["streamType"] ?? entry["stream_type"];
  const desc = entry["streamDesc"] ?? entry["stream_desc"];
  const watermarked =
    type === 259 ||
    type === 309 ||
    (typeof desc === "string" && desc.toUpperCase() === "WEB_LIVEPHOTO_19");
  // Only motion-clip URLs may become a video candidate: a Live photo's still
  // rendition can sit in the same stream map and must not be downloaded as the
  // clip (it would be saved as an unplayable `.mp4`).
  const urls = [
    entry["masterUrl"],
    entry["master_url"],
    ...(Array.isArray(entry["backupUrls"])
      ? (entry["backupUrls"] as unknown[])
      : Array.isArray(entry["backup_urls"])
        ? (entry["backup_urls"] as unknown[])
        : []),
    entry["url"],
  ].filter((u): u is string => nonBlank(u) && !isImageUrl(u));
  if (urls.length === 0) return undefined;
  const width = typeof entry["width"] === "number" ? (entry["width"] as number) : 0;
  const height = typeof entry["height"] === "number" ? (entry["height"] as number) : 0;
  const bitrate = num(entry["avgBitrate"]) ?? num(entry["videoBitrate"]) ?? 0;
  return { url: toHttps(urls[0]), watermarked, width, height, audio: audioStateOf(entry), bitrate };
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
  const ranked = rankVideoCandidates(videoCandidates(video));
  const best = ranked[0];
  if (!best) return undefined;
  const resolved: ResolvedVideo = { url: best.url };
  if (best.width > 0) resolved.width = best.width;
  if (best.height > 0) resolved.height = best.height;
  const alternates = [...new Set(ranked.slice(1)
    .filter((c) => !c.watermarked && c.audio !== "no")
    .map((c) => c.url))].filter((url) => url !== best.url);
  if (alternates.length > 0) resolved.alternates = alternates;
  return resolved;
}

function originVideoUrl(video: Record<string, unknown>): string | undefined {
  const key =
    (isRecord(video["consumer"]) ? pickString(video["consumer"] as Record<string, unknown>, ["originVideoKey"]) : undefined) ??
    pickString(video, ["originVideoKey"]);
  if (!key) return undefined;
  if (/^https?:\/\//i.test(key)) {
    const url = toHttps(key);
    // An absolute key is only trustworthy when it does not point at a still.
    return isImageUrl(url) ? undefined : url;
  }
  return `https://sns-video-bd.xhscdn.com/${key.replace(/^\/+/, "")}`;
}

/** Stream entries of every bucket a video object may carry, with their bucket. */
function videoStreamEntries(video: Record<string, unknown>): Array<[string, Record<string, unknown>]> {
  const out: Array<[string, Record<string, unknown>]> = [];
  const add = (prefix: string, container: unknown) => {
    if (!isRecord(container)) return;
    const stream = container["stream"] !== undefined ? container["stream"] : container;
    for (const [bucket, entry] of bucketedStreamEntries(stream)) out.push([`${prefix}.${bucket}`, entry]);
  };
  if (isRecord(video["media"]) && (video["media"] as Record<string, unknown>)["stream"] !== undefined) {
    add("media", (video["media"] as Record<string, unknown>)["stream"]);
  }
  if (video["stream"] !== undefined) add("video", video["stream"]);
  if (typeof video["mediaV2"] === "string") {
    try {
      const parsed = JSON.parse(video["mediaV2"] as string) as Record<string, unknown>;
      if (isRecord(parsed) && parsed["stream"] !== undefined) add("mediaV2", parsed["stream"]);
    } catch {
      // Ignore unparseable app-media payloads; other buckets may still apply.
    }
  }
  return out;
}

/**
 * The original upload (originVideoKey) declares no audio fields; transcoded
 * streams do. An editor soundtrack can exist only in the transcoded streams,
 * so a stream that declares audio outranks the original upload.
 */
function videoCandidates(video: unknown): VideoCandidate[] {
  if (!isRecord(video)) return [];
  const candidates: VideoCandidate[] = [];
  const origin = originVideoUrl(video);
  if (origin) {
    candidates.push({ url: origin, watermarked: false, width: 0, height: 0, audio: "unknown", bitrate: 0, origin: true });
  }
  for (const [, entry] of videoStreamEntries(video)) {
    const candidate = candidateFromEntry(entry);
    if (candidate) candidates.push(candidate);
  }
  return candidates;
}

const AUDIO_RANK: Record<AudioState, number> = { yes: 0, unknown: 1, no: 2 };

/**
 * Clean before watermarked, declared audio before unknown before none, the
 * original upload before an equally unknown stream, then resolution, then bitrate.
 */
function rankVideoCandidates(candidates: VideoCandidate[]): VideoCandidate[] {
  return [...candidates].sort((a, b) => {
    if (a.watermarked !== b.watermarked) return a.watermarked ? 1 : -1;
    if (a.audio !== b.audio) return AUDIO_RANK[a.audio] - AUDIO_RANK[b.audio];
    if (!!a.origin !== !!b.origin) return a.origin ? -1 : 1;
    const area = b.width * b.height - a.width * a.height;
    return area !== 0 ? area : b.bitrate - a.bitrate;
  });
}

function bestVideo(candidates: VideoCandidate[]): VideoCandidate | undefined {
  return rankVideoCandidates(candidates)[0];
}

/** Field names and short values of every candidate stream, for diagnostics. */
export function xhsStreamProbe(video: unknown): XhsStreamProbeEntry[] {
  if (!isRecord(video)) return [];
  const selected = resolveVideoUrl(video)?.url;
  const out: XhsStreamProbeEntry[] = [];
  const origin = originVideoUrl(video);
  if (origin) {
    out.push({ bucket: "origin", width: 0, height: 0, bitrate: 0, audio: "unknown",
      audioFields: [], watermarked: false, selected: origin === selected });
  }
  for (const [bucket, entry] of videoStreamEntries(video)) {
    const candidate = candidateFromEntry(entry);
    if (!candidate) continue;
    const codec = entry["videoCodec"] ?? entry["video_codec"];
    const audioCodec = entry["audioCodec"] ?? entry["audio_codec"];
    const probe: XhsStreamProbeEntry = {
      bucket,
      width: candidate.width,
      height: candidate.height,
      bitrate: candidate.bitrate,
      audio: candidate.audio,
      audioFields: Object.keys(entry).filter((key) => /audio/i.test(key)).sort(),
      watermarked: candidate.watermarked,
      selected: candidate.url === selected,
    };
    const streamType = num(entry["streamType"] ?? entry["stream_type"]);
    if (streamType !== undefined) probe.streamType = streamType;
    if (typeof codec === "string") probe.codec = codec;
    if (typeof audioCodec === "string") probe.audioCodec = audioCodec;
    const channels = num(entry["audioChannels"] ?? entry["audio_channels"]);
    if (channels !== undefined) probe.audioChannels = channels;
    const audioBitrate = num(entry["audioBitrate"] ?? entry["audio_bitrate"]);
    if (audioBitrate !== undefined) probe.audioBitrate = audioBitrate;
    out.push(probe);
  }
  return out;
}

function imageUrlOf(entry: Record<string, unknown>): { url: string; fallbacks: string[] } | undefined {
  // Primary: the bare original-bucket URL (upstream formula) — the token
  // carries no watermark; the CDN only burns one in when a `!style`
  // rendition is requested. JPEG transcode, scene renditions and the ci
  // token trail as fallbacks. A motion-clip URL never becomes a still.
  const token = entryToken(entry);
  if (token) {
    const primary = originalImageUrl(token);
    const direct = pickString(entry, ["urlDefault", "url"]);
    const rest = [
      jpegImageUrl(token),
      ...sceneRaws(entry),
      ...(direct ? [toHttps(direct)] : []),
      `https://ci.xiaohongshu.com/${token}`,
    ].filter((u) => u && u !== primary && !isVideoUrl(u));
    return { url: primary, fallbacks: [...new Set(rest)] };
  }
  const direct = pickString(entry, ["urlDefault", "url"]);
  if (direct) {
    const primary = transformImageUrl(direct);
    if (!isVideoUrl(primary)) {
      return { url: primary, fallbacks: [toHttps(direct)].filter((u) => u !== primary && !isVideoUrl(u)) };
    }
  }
  const traceId = pickString(entry, ["traceId"]);
  if (traceId) return { url: `https://sns-img-qc.xhscdn.com/${traceId}`, fallbacks: [] };
  return undefined;
}

/** Bare token from the richest source available: any scene rendition, the direct URL, then fileId. */
function entryToken(entry: Record<string, unknown>): string | undefined {
  const info = entry["infoList"];
  if (Array.isArray(info)) {
    for (const e of info) {
      if (!isRecord(e)) continue;
      const u = pickString(e, ["url"]);
      if (!u) continue;
      const token = imageTokenOf(u);
      if (token) return token;
    }
  }
  const direct = pickString(entry, ["urlDefault", "url"]);
  if (direct) {
    const token = imageTokenOf(direct);
    if (token) return token;
  }
  const fileId = fileToken(entry);
  return fileId || undefined;
}

/** Every raw scene rendition URL, https-normalized. */
function sceneRaws(entry: Record<string, unknown>): string[] {
  const info = entry["infoList"];
  if (!Array.isArray(info)) return [];
  return info.flatMap((e) => {
    if (!isRecord(e)) return [];
    const u = pickString(e, ["url"]);
    return u ? [toHttps(u)] : [];
  });
}

/** Video length in seconds from `video.capa.duration`, or undefined when unknown. */
function videoDuration(video: unknown): number | undefined {
  if (!isRecord(video)) return undefined;
  const capa = video["capa"];
  if (!isRecord(capa)) return undefined;
  return num(capa["duration"]);
}

function fileToken(entry: Record<string, unknown>): string {
  const fileId = pickString(entry, ["fileId"]);
  if (!fileId) return "";
  return fileId.split("!")[0];
}

/** Extract the bare `notes_pre_post/...` token by stripping the style suffix (`!...`). */
export function imageTokenOf(url: string): string | undefined {
  let parsed: URL | undefined;
  try {
    parsed = new URL(toHttps(url));
  } catch {
    return undefined;
  }
  const host = parsed.host.toLowerCase();
  if (!host.endsWith(".xhscdn.com") && !host.endsWith(".xiaohongshu.com")) {
    return undefined;
  }
  const withoutStyle = parsed.pathname.split("!")[0];
  const parts = withoutStyle.split("/").filter((p) => p.length > 0);
  const token =
    parts.length > 2 && /^[0-9a-f]{32}$/.test(parts[1])
      ? parts.slice(2).join("/")
      : parts.join("/");
  return token || undefined;
}

/** Bare original-bucket URL for a token (upstream formula): unwatermarked bytes. */
export function originalImageUrl(token: string): string {
  return `https://sns-img-bd.xhscdn.com/${token}`;
}

/** Same as `originalImageUrl` but transcoded to JPEG by the CDN. */
export function jpegImageUrl(token: string): string {
  return `https://ci.xiaohongshu.com/${token}?imageView2/format/jpg`;
}

function num(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/**
 * Parse a Xiaohongshu note page.
 * @param html Full page HTML source.
 * @param pageUrl The URL the HTML was fetched from (used to find the note id).
 */
export function parseXhs(html: string, pageUrl: string, thumbnailScenes: string[] = []): XhsResult {
  const idMatch = NOTE_ID_PATTERN.exec(pageUrl);
  const wantedId = idMatch ? idMatch[1].toLowerCase() : undefined;

  const states: unknown[] = [];
  for (const marker of STATE_MARKERS) {
    const parsed = extractJsonAfter(html, marker);
    if (parsed !== undefined) states.push(parsed);
  }

  let note = findNoteInStates(states, wantedId) ?? extractNoteDetailEntry(html, wantedId);
  if (
    note &&
    wantedId &&
    nonBlank(note["noteId"]) &&
    (note["noteId"] as string).toLowerCase() !== wantedId
  ) {
    // A mismatched id means stale data from another post: never present it
    // as the requested note.
    note = undefined;
  }

  const looksLikeXhs =
    /xiaohongshu\.com|rednote\.com|xhslink/.test(pageUrl) ||
    /xiaohongshu\.com|rednote\.com|xhslink|__INITIAL_STATE__/.test(html.slice(0, 20000));
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
  return buildNoteFromRecord(note, noteId, pageUrl, thumbnailScenes);
}

/**
 * Keep the share URL byte-for-byte whenever possible: `xsec_token` is bound
 * to the exact path it was issued for, and re-encoding its value can break the
 * signature. Only rebuild when the page URL is not already the note URL.
 */
function canonicalXhsNoteUrl(noteId: string, pageUrl?: string): string {
  const base = `https://www.xiaohongshu.com/explore/${noteId}`;
  if (typeof pageUrl !== "string" || pageUrl.length === 0) return base;
  if (pageUrl.indexOf(noteId) >= 0) return pageUrl;
  const query = pageUrl.indexOf("?") >= 0 ? pageUrl.slice(pageUrl.indexOf("?")) : "";
  if (!query) return base;
  try {
    const params = new URLSearchParams(query);
    const kept: string[] = [];
    for (const key of ["xsec_token", "xsec_source"]) {
      const value = params.get(key);
      if (value) kept.push(`${key}=${encodeURIComponent(value)}`);
    }
    return kept.length > 0 ? `${base}?${kept.join("&")}` : base;
  } catch (_) {
    return base;
  }
}

/**
 * Locate the wanted note inside already-parsed embedded states.
 * Exported so the MAIN-world content script can pass `window.__INITIAL_STATE__`
 * directly instead of re-serializing and re-parsing the page.
 */
export function findNoteInStates(
  states: unknown[],
  wantedId: string | undefined,
): Record<string, unknown> | undefined {
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
      return fromMap;
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
      return mobileNote;
    }
  }
  for (const state of states) {
    const note = deepFindNote(state, wantedId);
    if (note && (!wantedId || !nonBlank(note["noteId"]) || note["noteId"] === wantedId)) return note;
  }
  return undefined;
}

/**
 * Build the unified note output from an already-located note object.
 * Shared by parseXhs (HTML input) and the MAIN-world fast path.
 */
export function buildNoteFromRecord(
  note: Record<string, unknown>,
  noteId: string,
  pageUrl?: string,
  thumbnailScenes: string[] = [],
): XhsResult {
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
  // A real video note carries a single cover in `imageList`. Several entries mean a
  // mixed carousel (images / live photos / video) even if `type` says "video".
  const isVideoNote =
    (noteType === "video" && images.length <= 1) ||
    (noteType === "" && hasMainVideo && images.length <= 1 && !firstHasStream);

  const items: XhsItem[] = [];

  if (isVideoNote) {
    const resolved = resolveVideoUrl(note["video"]);
    if (resolved) {
      const item: XhsItem = { type: "video", url: resolved.url };
      if (resolved.alternates) item.fallbacks = resolved.alternates;
      const cover = images.length > 0 ? imageUrlOf(images[0]) : undefined;
      if (cover) item.posterUrl = cover.url;
      if (images[0]) {
        const thumbnail = thumbnailOf(images[0], thumbnailScenes);
        if (thumbnail) item.thumbnailUrl = thumbnail;
      }
      if (resolved.width !== undefined) item.width = resolved.width;
      if (resolved.height !== undefined) item.height = resolved.height;
      const duration = videoDuration(note["video"]);
      if (duration !== undefined) item.duration = duration;
      items.push(item);
    } else if (images.length === 1) {
      const img = imageUrlOf(images[0]);
      if (img) {
        const item: XhsItem = { type: "image", url: img.url, fallbacks: img.fallbacks };
        const thumbnail = thumbnailOf(images[0], thumbnailScenes);
        if (thumbnail) item.thumbnailUrl = thumbnail;
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
      const entryKeyUrlRaw = entryKey
        ? /^https?:\/\//i.test(entryKey)
          ? toHttps(entryKey)
          : `https://sns-video-bd.xhscdn.com/${entryKey.replace(/^\/+/, "")}`
        : undefined;
      // A Live photo's originVideoKey can name the still; only a non-image URL
      // may become the motion clip.
      const entryKeyUrl =
        entryKeyUrlRaw && !isImageUrl(entryKeyUrlRaw) ? entryKeyUrlRaw : undefined;
      const ownCandidates = [
        ...collectStreamCandidates(entry["stream"]),
        ...(isRecord(livePhoto) && livePhoto["stream"] !== undefined
          ? collectStreamCandidates(livePhoto["stream"])
          : []),
      ];
      const own = entryKeyUrl
        ? { url: entryKeyUrl }
        : bestVideo(ownCandidates);
      if (own && img) {
        const item: XhsItem = { type: "live", url: img.url, videoUrl: own.url, fallbacks: img.fallbacks };
        const thumbnail = thumbnailOf(entry, thumbnailScenes);
        if (thumbnail) item.thumbnailUrl = thumbnail;
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
        const item: XhsItem = { type: "image", url: img.url, fallbacks: img.fallbacks };
        const thumbnail = thumbnailOf(entry, thumbnailScenes);
        if (thumbnail) item.thumbnailUrl = thumbnail;
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
      if (noteVideo.alternates) item.fallbacks = noteVideo.alternates;
      if (noteVideo.width !== undefined) item.width = noteVideo.width;
      if (noteVideo.height !== undefined) item.height = noteVideo.height;
      const duration = videoDuration(note["video"]);
      if (duration !== undefined) item.duration = duration;
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
    url: canonicalXhsNoteUrl(noteId, pageUrl),
    author,
    items,
  };
  const platformLabel = xhsAiLabel(isRecord(note.illegalInfo) ? note.illegalInfo.desc : undefined, noteId);
  const statement = note.noteStatement;
  const authorLabel = typeof statement === 'string' && statement.startsWith('作者声明') && /ai/i.test(statement)
    ? { text: statement, source: 'author' as const } : undefined;
  if (typeof statement === 'string' && statement.trim() && !authorLabel) unknownAiLabel(noteId, statement);
  if (authorLabel && platformLabel) unknownAiLabel(noteId, platformLabel.text);
  const label = authorLabel ?? platformLabel;
  if (label) data.aiLabel = label;
  if (nonBlank(note["title"])) data.title = note["title"] as string;
  const caption = pickString(note, ["desc", "description"]);
  if (caption !== undefined) data.caption = caption;
  if (typeof note["time"] === "number" && Number.isFinite(note["time"])) {
    data.publishedAt = toIsoUtc(note["time"] as number);
  }
  return { ok: true, data };
}

/** Select a declared rendition verbatim; never manufacture CDN styles. */
function thumbnailOf(entry: Record<string, unknown>, scenes: string[]): string | undefined {
  const info = entry.infoList;
  if (!Array.isArray(info)) return undefined;
  for (const scene of scenes) {
    const candidate = info.find(e => isRecord(e) && e.imageScene === scene && nonBlank(e.url));
    if (candidate) return toHttps(candidate.url as string);
  }
  return undefined;
}

/**
 * Kind of a Xiaohongshu image URL. `preview` covers every preview scene
 * (`!nd_prv_*`, WB_PRV, H5_PRV) and is never downloaded.
 */
export type XhsImageVariant = "jpeg" | "original" | "original_ci" | "default" | "preview" | "other";

export function xhsImageVariant(url: string): XhsImageVariant {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return "other";
  }
  const host = parsed.hostname.toLowerCase();
  const bang = parsed.pathname.indexOf("!");
  const style = bang >= 0 ? parsed.pathname.slice(bang + 1).toLowerCase() : "";
  if (/prv/.test(style) || /(?:^|[^a-z])prv(?:[^a-z]|$)/i.test(parsed.search)) return "preview";
  if (host === "ci.xiaohongshu.com") {
    if (/imageView2/i.test(parsed.search) && !/thumbnail|\/w\/|\/h\//i.test(parsed.search)) return "jpeg";
    return parsed.search || style ? "other" : "original_ci";
  }
  if (host.endsWith(".xhscdn.com") && !style && !parsed.search && host.startsWith("sns-img-")) return "original";
  if (/dft/.test(style)) return "default";
  return "other";
}

/**
 * Download preference: the original resolution first (the CDN's JPEG
 * transcode of the original, which the album and provenance writer support,
 * then the original bucket and the bare ci original), then the default-size
 * variant, then anything else. Preview variants are left out, and so is any
 * motion-clip URL: a still-image candidate list never contains a video.
 */
const VARIANT_RANK: Record<Exclude<XhsImageVariant, "preview">, number> = {
  jpeg: 0, original: 1, original_ci: 2, default: 3, other: 4,
};

export function xhsImageDownloadOrder(url: string, fallbacks: string[] = []): string[] {
  const unique = [...new Set([url, ...fallbacks].filter((u) => typeof u === "string" && u.length > 0))];
  return unique
    .map((u, index) => ({ u, index, variant: xhsImageVariant(u) }))
    .filter((c) => c.variant !== "preview" && !isVideoUrl(c.u))
    .sort((a, b) => VARIANT_RANK[a.variant as keyof typeof VARIANT_RANK] -
      VARIANT_RANK[b.variant as keyof typeof VARIANT_RANK] || a.index - b.index)
    .map((c) => c.u);
}

/** Field names, scenes, declared size and ranked candidates of one image. */
export interface XhsImageProbeEntry {
  index: number;
  fields: string[];
  scenes: string[];
  width?: number;
  height?: number;
  candidates: XhsImageVariant[];
  selected?: XhsImageVariant;
}

const IMAGE_FIELDS = ["urlDefault", "urlPre", "url", "infoList", "traceId", "fileId", "livePhoto", "stream"];

export function xhsImageProbe(note: unknown): XhsImageProbeEntry[] {
  if (!isRecord(note)) return [];
  const list = note["imageList"] ?? note["images"];
  if (!Array.isArray(list)) return [];
  return list.flatMap((entry, index) => {
    if (!isRecord(entry)) return [];
    const resolved = imageUrlOf(entry);
    const order = resolved ? xhsImageDownloadOrder(resolved.url, resolved.fallbacks) : [];
    const info = Array.isArray(entry["infoList"]) ? entry["infoList"] as unknown[] : [];
    const probe: XhsImageProbeEntry = {
      index: index + 1,
      fields: IMAGE_FIELDS.filter((key) => entry[key] !== undefined && entry[key] !== null && entry[key] !== ""),
      scenes: info.flatMap((e) => isRecord(e) && typeof e["imageScene"] === "string" ? [e["imageScene"] as string] : []),
      candidates: order.map(xhsImageVariant),
    };
    const width = num(entry["width"]);
    const height = num(entry["height"]);
    if (width !== undefined) probe.width = width;
    if (height !== undefined) probe.height = height;
    if (probe.candidates.length > 0) probe.selected = probe.candidates[0];
    return [probe];
  });
}
