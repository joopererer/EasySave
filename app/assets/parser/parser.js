"use strict";
var EasySaveParser = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // src/_parse_page.ts
  var parse_page_exports = {};
  __export(parse_page_exports, {
    calculateToken: () => calculateToken,
    extractTweetId: () => extractTweetId,
    moduleCall: () => moduleCall,
    parse: () => parse,
    parseInstagram: () => parseInstagram,
    parseInstagramFromDom: () => parseInstagramFromDom,
    parsePage: () => parsePage,
    parsePageForModule: () => parsePageForModule,
    parseX: () => parseX,
    parseXhs: () => parseXhs
  });

  // src/ai-label.ts
  function instagramAiLabel(info) {
    if (!info || typeof info !== "object" || Array.isArray(info)) return;
    const text2 = info.attribution_label_text;
    if (typeof text2 === "string" && text2.trim()) return { text: "AI content", source: "platform" };
  }
  function unknownAiLabel(id, value) {
    console.info("EasySaveAiLabel:" + JSON.stringify({ id, value }));
  }
  function xhsAiLabel(desc, id) {
    if (typeof desc !== "string" || !desc.trim()) return;
    if (desc === "\u53EF\u80FD\u542BAI\u751F\u6210\u5185\u5BB9") return { text: desc, source: "platform" };
    if (desc.startsWith("\u4F5C\u8005\u58F0\u660E") && /ai/i.test(desc)) return { text: desc, source: "author" };
    unknownAiLabel(id, desc);
  }
  function tiktokAiLabel(value, id) {
    if (value === 1 || value === "1") return { text: "Contains AI-generated media", source: "platform" };
    if (value === 2 || value === "2") return { text: "Creator labeled as AI-generated", source: "author" };
    if (typeof value === "string" && value.trim() || typeof value === "number" || typeof value === "boolean") {
      unknownAiLabel(id, value);
    }
  }

  // src/xhs.ts
  var NOTE_ID_PATTERN = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-f0-9]{24})/i;
  var STATE_MARKERS = ["__INITIAL_STATE__", "__NEXT_DATA__", "__NUXT__"];
  var XHS_CDN_SUFFIX = ".xhscdn.com";
  var XIAOHONGSHU_SUFFIX = ".xiaohongshu.com";
  function isRecord(value) {
    return typeof value === "object" && value !== null;
  }
  function nonBlank(value) {
    return typeof value === "string" && value.trim().length > 0;
  }
  function pickString(obj, keys) {
    for (const key of keys) {
      const value = obj[key];
      if (nonBlank(value)) return value;
    }
    return void 0;
  }
  function toIsoUtc(ms) {
    return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
  }
  function toHttps(url) {
    return url.startsWith("http://") ? `https://${url.slice("http://".length)}` : url;
  }
  function transformImageUrl(url) {
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
    const token = parts.length > 2 && /^[a-fA-F0-9]{32}$/.test(parts[1]) ? parts.slice(2).join("/") : parts.join("/");
    if (!token) return https;
    return `https://ci.xiaohongshu.com/${token}`;
  }
  function scanBalancedObject(html, from) {
    const start = html.indexOf("{", from);
    if (start < 0) return void 0;
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
    return void 0;
  }
  function sanitizeJsUndefined(source) {
    let out = "";
    let i = 0;
    let inString = false;
    let escaped = false;
    const isIdChar = (c) => /[A-Za-z0-9_$]/.test(c);
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
      if (source.startsWith("undefined", i) && (i === 0 || !isIdChar(source[i - 1])) && (i + "undefined".length >= source.length || !isIdChar(source[i + "undefined".length]))) {
        out += "null";
        i += "undefined".length;
        continue;
      }
      out += c;
      i++;
    }
    return out;
  }
  function tryParseJson(text2) {
    try {
      return JSON.parse(text2);
    } catch {
      return void 0;
    }
  }
  function extractJsonAfter(html, marker) {
    let from = 0;
    for (; ; ) {
      const at = html.indexOf(marker, from);
      if (at < 0) return void 0;
      const scanned = scanBalancedObject(html, at + marker.length);
      if (!scanned) return void 0;
      const raw = html.slice(scanned.start, scanned.end + 1);
      const parsed = tryParseJson(raw) ?? tryParseJson(sanitizeJsUndefined(raw));
      if (parsed !== void 0) return parsed;
      from = scanned.end + 1;
    }
  }
  function extractNoteDetailEntry(html, wantedId) {
    let from = 0;
    for (; ; ) {
      const at = html.indexOf('"noteDetailMap"', from);
      if (at < 0) return void 0;
      const colon = html.indexOf(":", at + '"noteDetailMap"'.length);
      if (colon < 0) return void 0;
      const scanned = scanBalancedObject(html, colon + 1);
      if (!scanned) return void 0;
      const raw = html.slice(scanned.start, scanned.end + 1);
      const map = tryParseJson(raw) ?? tryParseJson(sanitizeJsUndefined(raw));
      if (isRecord(map)) {
        if (wantedId && isRecord(map[wantedId])) {
          const entry = map[wantedId];
          return isRecord(entry["note"]) ? entry["note"] : entry;
        }
        if (!wantedId) {
          for (const entry of Object.values(map)) {
            if (!isRecord(entry)) continue;
            const note = isRecord(entry["note"]) ? entry["note"] : entry;
            if (isNoteShaped(note)) return note;
          }
        }
      }
      from = scanned.end + 1;
    }
  }
  function isNoteShaped(obj) {
    if (nonBlank(obj["noteId"])) {
      if (nonBlank(obj["title"]) || nonBlank(obj["desc"]) || nonBlank(obj["description"]) || Array.isArray(obj["imageList"]) || Array.isArray(obj["images"]) || isRecord(obj["video"])) {
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
  function deepFindNote(root, wantedId) {
    const seen = /* @__PURE__ */ new Set();
    let fallback;
    const visit = (node, depth) => {
      if (!isRecord(node) && !Array.isArray(node)) return;
      const obj = node;
      if (seen.has(obj) || depth > 24) return;
      seen.add(obj);
      if (isRecord(node)) {
        if (nonBlank(node["noteId"]) && node["noteId"] === wantedId) {
          fallback = void 0;
          throw { found: node };
        }
        if (!fallback && !wantedId && isNoteShaped(node)) fallback = node;
        for (const value of Object.values(node)) visit(value, depth + 1);
      } else {
        for (const value of node) visit(value, depth + 1);
      }
    };
    try {
      visit(root, 0);
    } catch (e) {
      if (isRecord(e) && "found" in e) return e["found"];
      throw e;
    }
    return fallback;
  }
  function streamEntries(stream) {
    return bucketedStreamEntries(stream).map(([, entry]) => entry);
  }
  function bucketedStreamEntries(stream) {
    if (!isRecord(stream)) return [];
    const out = [];
    for (const [bucket, arr] of Object.entries(stream)) {
      if (Array.isArray(arr)) {
        for (const entry of arr) {
          if (isRecord(entry)) out.push([bucket, entry]);
        }
      }
    }
    return out;
  }
  function audioStateOf(entry) {
    const codec = entry["audioCodec"] ?? entry["audio_codec"];
    const channels = num(entry["audioChannels"] ?? entry["audio_channels"]);
    const bitrate = num(entry["audioBitrate"] ?? entry["audio_bitrate"]);
    if (codec === void 0 && channels === void 0 && bitrate === void 0) return "unknown";
    const namedCodec = typeof codec === "string" && codec.trim() !== "" && !/^(?:none|null|unknown|0)$/i.test(codec.trim());
    return namedCodec || (channels ?? 0) > 0 || (bitrate ?? 0) > 0 ? "yes" : "no";
  }
  function candidateFromEntry(entry) {
    const type = entry["streamType"] ?? entry["stream_type"];
    const desc = entry["streamDesc"] ?? entry["stream_desc"];
    const watermarked = type === 259 || type === 309 || typeof desc === "string" && desc.toUpperCase() === "WEB_LIVEPHOTO_19";
    const urls2 = [
      entry["masterUrl"],
      entry["master_url"],
      ...Array.isArray(entry["backupUrls"]) ? entry["backupUrls"] : Array.isArray(entry["backup_urls"]) ? entry["backup_urls"] : [],
      entry["url"]
    ].filter(nonBlank);
    if (urls2.length === 0) return void 0;
    const width = typeof entry["width"] === "number" ? entry["width"] : 0;
    const height = typeof entry["height"] === "number" ? entry["height"] : 0;
    const bitrate = num(entry["avgBitrate"]) ?? num(entry["videoBitrate"]) ?? 0;
    return { url: toHttps(urls2[0]), watermarked, width, height, audio: audioStateOf(entry), bitrate };
  }
  function collectStreamCandidates(container) {
    if (!isRecord(container)) return [];
    const streamObj = container["stream"] !== void 0 && isRecord(container) ? container["stream"] : container;
    return streamEntries(streamObj).map(candidateFromEntry).filter((c) => c !== void 0);
  }
  function resolveVideoUrl(video) {
    const ranked = rankVideoCandidates(videoCandidates(video));
    const best = ranked[0];
    if (!best) return void 0;
    const resolved = { url: best.url };
    if (best.width > 0) resolved.width = best.width;
    if (best.height > 0) resolved.height = best.height;
    const alternates = [...new Set(ranked.slice(1).filter((c) => !c.watermarked && c.audio !== "no").map((c) => c.url))].filter((url) => url !== best.url);
    if (alternates.length > 0) resolved.alternates = alternates;
    return resolved;
  }
  function originVideoUrl(video) {
    const key = (isRecord(video["consumer"]) ? pickString(video["consumer"], ["originVideoKey"]) : void 0) ?? pickString(video, ["originVideoKey"]);
    if (!key) return void 0;
    if (/^https?:\/\//i.test(key)) return toHttps(key);
    return `https://sns-video-bd.xhscdn.com/${key.replace(/^\/+/, "")}`;
  }
  function videoStreamEntries(video) {
    const out = [];
    const add = (prefix, container) => {
      if (!isRecord(container)) return;
      const stream = container["stream"] !== void 0 ? container["stream"] : container;
      for (const [bucket, entry] of bucketedStreamEntries(stream)) out.push([`${prefix}.${bucket}`, entry]);
    };
    if (isRecord(video["media"]) && video["media"]["stream"] !== void 0) {
      add("media", video["media"]["stream"]);
    }
    if (video["stream"] !== void 0) add("video", video["stream"]);
    if (typeof video["mediaV2"] === "string") {
      try {
        const parsed = JSON.parse(video["mediaV2"]);
        if (isRecord(parsed) && parsed["stream"] !== void 0) add("mediaV2", parsed["stream"]);
      } catch {
      }
    }
    return out;
  }
  function videoCandidates(video) {
    if (!isRecord(video)) return [];
    const candidates = [];
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
  var AUDIO_RANK = { yes: 0, unknown: 1, no: 2 };
  function rankVideoCandidates(candidates) {
    return [...candidates].sort((a, b) => {
      if (a.watermarked !== b.watermarked) return a.watermarked ? 1 : -1;
      if (a.audio !== b.audio) return AUDIO_RANK[a.audio] - AUDIO_RANK[b.audio];
      if (!!a.origin !== !!b.origin) return a.origin ? -1 : 1;
      const area = b.width * b.height - a.width * a.height;
      return area !== 0 ? area : b.bitrate - a.bitrate;
    });
  }
  function bestVideo(candidates) {
    return rankVideoCandidates(candidates)[0];
  }
  function xhsStreamProbe(video) {
    if (!isRecord(video)) return [];
    const selected = resolveVideoUrl(video)?.url;
    const out = [];
    const origin = originVideoUrl(video);
    if (origin) {
      out.push({
        bucket: "origin",
        width: 0,
        height: 0,
        bitrate: 0,
        audio: "unknown",
        audioFields: [],
        watermarked: false,
        selected: origin === selected
      });
    }
    for (const [bucket, entry] of videoStreamEntries(video)) {
      const candidate = candidateFromEntry(entry);
      if (!candidate) continue;
      const codec = entry["videoCodec"] ?? entry["video_codec"];
      const audioCodec = entry["audioCodec"] ?? entry["audio_codec"];
      const probe = {
        bucket,
        width: candidate.width,
        height: candidate.height,
        bitrate: candidate.bitrate,
        audio: candidate.audio,
        audioFields: Object.keys(entry).filter((key) => /audio/i.test(key)).sort(),
        watermarked: candidate.watermarked,
        selected: candidate.url === selected
      };
      const streamType = num(entry["streamType"] ?? entry["stream_type"]);
      if (streamType !== void 0) probe.streamType = streamType;
      if (typeof codec === "string") probe.codec = codec;
      if (typeof audioCodec === "string") probe.audioCodec = audioCodec;
      const channels = num(entry["audioChannels"] ?? entry["audio_channels"]);
      if (channels !== void 0) probe.audioChannels = channels;
      const audioBitrate = num(entry["audioBitrate"] ?? entry["audio_bitrate"]);
      if (audioBitrate !== void 0) probe.audioBitrate = audioBitrate;
      out.push(probe);
    }
    return out;
  }
  function imageUrlOf(entry) {
    const token = entryToken(entry);
    if (token) {
      const primary = originalImageUrl(token);
      const direct2 = pickString(entry, ["urlDefault", "url"]);
      const rest = [
        jpegImageUrl(token),
        ...sceneRaws(entry),
        ...direct2 ? [toHttps(direct2)] : [],
        `https://ci.xiaohongshu.com/${token}`
      ].filter((u) => u && u !== primary);
      return { url: primary, fallbacks: [...new Set(rest)] };
    }
    const direct = pickString(entry, ["urlDefault", "url"]);
    if (direct) {
      return { url: transformImageUrl(direct), fallbacks: [toHttps(direct)] };
    }
    const traceId = pickString(entry, ["traceId"]);
    if (traceId) return { url: `https://sns-img-qc.xhscdn.com/${traceId}`, fallbacks: [] };
    return void 0;
  }
  function entryToken(entry) {
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
    return fileId || void 0;
  }
  function sceneRaws(entry) {
    const info = entry["infoList"];
    if (!Array.isArray(info)) return [];
    return info.flatMap((e) => {
      if (!isRecord(e)) return [];
      const u = pickString(e, ["url"]);
      return u ? [toHttps(u)] : [];
    });
  }
  function videoDuration(video) {
    if (!isRecord(video)) return void 0;
    const capa = video["capa"];
    if (!isRecord(capa)) return void 0;
    return num(capa["duration"]);
  }
  function fileToken(entry) {
    const fileId = pickString(entry, ["fileId"]);
    if (!fileId) return "";
    return fileId.split("!")[0];
  }
  function imageTokenOf(url) {
    let parsed;
    try {
      parsed = new URL(toHttps(url));
    } catch {
      return void 0;
    }
    const host = parsed.host.toLowerCase();
    if (!host.endsWith(".xhscdn.com") && !host.endsWith(".xiaohongshu.com")) {
      return void 0;
    }
    const withoutStyle = parsed.pathname.split("!")[0];
    const parts = withoutStyle.split("/").filter((p) => p.length > 0);
    const token = parts.length > 2 && /^[0-9a-f]{32}$/.test(parts[1]) ? parts.slice(2).join("/") : parts.join("/");
    return token || void 0;
  }
  function originalImageUrl(token) {
    return `https://sns-img-bd.xhscdn.com/${token}`;
  }
  function jpegImageUrl(token) {
    return `https://ci.xiaohongshu.com/${token}?imageView2/format/jpg`;
  }
  function num(value) {
    return typeof value === "number" && Number.isFinite(value) ? value : void 0;
  }
  function parseXhs(html, pageUrl, thumbnailScenes = []) {
    const idMatch = NOTE_ID_PATTERN.exec(pageUrl);
    const wantedId = idMatch ? idMatch[1].toLowerCase() : void 0;
    const states = [];
    for (const marker of STATE_MARKERS) {
      const parsed = extractJsonAfter(html, marker);
      if (parsed !== void 0) states.push(parsed);
    }
    let note = findNoteInStates(states, wantedId) ?? extractNoteDetailEntry(html, wantedId);
    if (note && wantedId && nonBlank(note["noteId"]) && note["noteId"].toLowerCase() !== wantedId) {
      note = void 0;
    }
    const looksLikeXhs = /xiaohongshu\.com|rednote\.com|xhslink/.test(pageUrl) || /xiaohongshu\.com|rednote\.com|xhslink|__INITIAL_STATE__/.test(html.slice(0, 2e4));
    if (!note) {
      if (looksLikeXhs) {
        return {
          ok: false,
          error: {
            code: "LOGIN_REQUIRED",
            message: "Xiaohongshu returned an authenticated-only shell without note data."
          }
        };
      }
      return {
        ok: false,
        error: { code: "INVALID_PAGE", message: "Not a Xiaohongshu note page." }
      };
    }
    const noteId = nonBlank(note["noteId"]) ? note["noteId"] : wantedId ?? "";
    if (!noteId) {
      return {
        ok: false,
        error: { code: "INVALID_PAGE", message: "Could not determine the note id." }
      };
    }
    return buildNoteFromRecord(note, noteId, pageUrl, thumbnailScenes);
  }
  function canonicalXhsNoteUrl(noteId, pageUrl) {
    const base = `https://www.xiaohongshu.com/explore/${noteId}`;
    if (typeof pageUrl !== "string" || pageUrl.length === 0) return base;
    if (pageUrl.indexOf(noteId) >= 0) return pageUrl;
    const query = pageUrl.indexOf("?") >= 0 ? pageUrl.slice(pageUrl.indexOf("?")) : "";
    if (!query) return base;
    try {
      const params = new URLSearchParams(query);
      const kept = [];
      for (const key of ["xsec_token", "xsec_source"]) {
        const value = params.get(key);
        if (value) kept.push(`${key}=${encodeURIComponent(value)}`);
      }
      return kept.length > 0 ? `${base}?${kept.join("&")}` : base;
    } catch (_) {
      return base;
    }
  }
  function findNoteInStates(states, wantedId) {
    for (const state of states) {
      if (!isRecord(state)) continue;
      const byMap = isRecord(state["note"]) && isRecord(state["note"]["noteDetailMap"]) ? state["note"]["noteDetailMap"][wantedId ?? ""] : void 0;
      const fromMap = isRecord(byMap) && isRecord(byMap["note"]) ? byMap["note"] : isRecord(byMap) ? byMap : void 0;
      if (fromMap && (!wantedId || !nonBlank(fromMap["noteId"]) || fromMap["noteId"] === wantedId)) {
        return fromMap;
      }
      const mobile = isRecord(state["noteData"]) && isRecord(state["noteData"]["data"]) ? state["noteData"]["data"]["noteData"] : void 0;
      const mobileNote = isRecord(mobile) && isRecord(mobile["note"]) ? mobile["note"] : isRecord(mobile) ? mobile : void 0;
      if (mobileNote && (!wantedId || !nonBlank(mobileNote["noteId"]) || mobileNote["noteId"] === wantedId)) {
        return mobileNote;
      }
    }
    for (const state of states) {
      const note = deepFindNote(state, wantedId);
      if (note && (!wantedId || !nonBlank(note["noteId"]) || note["noteId"] === wantedId)) return note;
    }
    return void 0;
  }
  function buildNoteFromRecord(note, noteId, pageUrl, thumbnailScenes = []) {
    const user = isRecord(note["user"]) ? note["user"] : isRecord(note["author"]) ? note["author"] : {};
    const author = {};
    const authorName = pickString(user, ["nickname", "nickName", "name", "userName"]);
    const authorId = pickString(user, ["userId", "user_id", "id", "redId"]);
    if (authorName) author.name = authorName;
    if (authorId) author.id = authorId;
    const rawImages = Array.isArray(note["imageList"]) ? note["imageList"] : note["images"] ?? [];
    const images = rawImages.filter(isRecord);
    const noteType = typeof note["type"] === "string" ? note["type"] : "";
    const firstHasStream = images.length > 0 && (images[0]["stream"] !== void 0 || images[0]["livePhoto"] !== void 0);
    const hasMainVideo = isRecord(note["video"]) && (nonBlank(note["video"]["originVideoKey"]) || isRecord(note["video"]["consumer"]) && nonBlank(
      note["video"]["consumer"]["originVideoKey"]
    ) || collectStreamCandidates(note["video"]["media"]).length > 0 || collectStreamCandidates(note["video"]["stream"]).length > 0 || typeof note["video"]["mediaV2"] === "string" && (note["video"]["mediaV2"].includes("master_url") || note["video"]["mediaV2"].includes("masterUrl")));
    const isVideoNote = noteType === "video" && images.length <= 1 || noteType === "" && hasMainVideo && images.length <= 1 && !firstHasStream;
    const items = [];
    if (isVideoNote) {
      const resolved = resolveVideoUrl(note["video"]);
      if (resolved) {
        const item = { type: "video", url: resolved.url };
        if (resolved.alternates) item.fallbacks = resolved.alternates;
        const cover = images.length > 0 ? imageUrlOf(images[0]) : void 0;
        if (cover) item.posterUrl = cover.url;
        if (images[0]) {
          const thumbnail = thumbnailOf(images[0], thumbnailScenes);
          if (thumbnail) item.thumbnailUrl = thumbnail;
        }
        if (resolved.width !== void 0) item.width = resolved.width;
        if (resolved.height !== void 0) item.height = resolved.height;
        const duration = videoDuration(note["video"]);
        if (duration !== void 0) item.duration = duration;
        items.push(item);
      } else if (images.length === 1) {
        const img = imageUrlOf(images[0]);
        if (img) {
          const item = { type: "image", url: img.url, fallbacks: img.fallbacks };
          const thumbnail = thumbnailOf(images[0], thumbnailScenes);
          if (thumbnail) item.thumbnailUrl = thumbnail;
          const w = num(images[0]["width"]);
          const h = num(images[0]["height"]);
          if (w !== void 0) item.width = w;
          if (h !== void 0) item.height = h;
          items.push(item);
        }
      }
    } else {
      const noteVideo = resolveVideoUrl(note["video"]);
      let noteVideoEmitted = false;
      images.forEach((entry) => {
        const img = imageUrlOf(entry);
        const livePhoto = entry["livePhoto"];
        const entryKey = pickString(entry, ["originVideoKey"]) ?? (isRecord(livePhoto) ? pickString(livePhoto, ["originVideoKey"]) : void 0);
        const entryKeyUrl = entryKey ? /^https?:\/\//i.test(entryKey) ? toHttps(entryKey) : `https://sns-video-bd.xhscdn.com/${entryKey.replace(/^\/+/, "")}` : void 0;
        const ownCandidates = [
          ...collectStreamCandidates(entry["stream"]),
          ...isRecord(livePhoto) && livePhoto["stream"] !== void 0 ? collectStreamCandidates(livePhoto["stream"]) : []
        ];
        const own = entryKeyUrl ? { url: entryKeyUrl } : bestVideo(ownCandidates);
        if (own && img) {
          const item = { type: "live", url: img.url, videoUrl: own.url, fallbacks: img.fallbacks };
          const thumbnail = thumbnailOf(entry, thumbnailScenes);
          if (thumbnail) item.thumbnailUrl = thumbnail;
          const w = num(entry["width"]);
          const h = num(entry["height"]);
          if (w !== void 0) item.width = w;
          if (h !== void 0) item.height = h;
          items.push(item);
          return;
        }
        if (own && !img) {
          items.push({ type: "video", url: own.url });
          return;
        }
        if (img) {
          const item = { type: "image", url: img.url, fallbacks: img.fallbacks };
          const thumbnail = thumbnailOf(entry, thumbnailScenes);
          if (thumbnail) item.thumbnailUrl = thumbnail;
          const w = num(entry["width"]);
          const h = num(entry["height"]);
          if (w !== void 0) item.width = w;
          if (h !== void 0) item.height = h;
          items.push(item);
        }
      });
      if (noteVideo && !noteVideoEmitted && images.length !== 1) {
        noteVideoEmitted = true;
        const item = { type: "video", url: noteVideo.url };
        if (noteVideo.alternates) item.fallbacks = noteVideo.alternates;
        if (noteVideo.width !== void 0) item.width = noteVideo.width;
        if (noteVideo.height !== void 0) item.height = noteVideo.height;
        const duration = videoDuration(note["video"]);
        if (duration !== void 0) item.duration = duration;
        items.push(item);
      }
    }
    if (items.length === 0) {
      return {
        ok: false,
        error: {
          code: "LOGIN_REQUIRED",
          message: "Xiaohongshu note has no extractable media."
        }
      };
    }
    const data = {
      platform: "xhs",
      id: noteId,
      url: canonicalXhsNoteUrl(noteId, pageUrl),
      author,
      items
    };
    const platformLabel = xhsAiLabel(isRecord(note.illegalInfo) ? note.illegalInfo.desc : void 0, noteId);
    const statement = note.noteStatement;
    const authorLabel = typeof statement === "string" && statement.startsWith("\u4F5C\u8005\u58F0\u660E") && /ai/i.test(statement) ? { text: statement, source: "author" } : void 0;
    if (typeof statement === "string" && statement.trim() && !authorLabel) unknownAiLabel(noteId, statement);
    if (authorLabel && platformLabel) unknownAiLabel(noteId, platformLabel.text);
    const label = authorLabel ?? platformLabel;
    if (label) data.aiLabel = label;
    if (nonBlank(note["title"])) data.title = note["title"];
    const caption = pickString(note, ["desc", "description"]);
    if (caption !== void 0) data.caption = caption;
    if (typeof note["time"] === "number" && Number.isFinite(note["time"])) {
      data.publishedAt = toIsoUtc(note["time"]);
    }
    return { ok: true, data };
  }
  function thumbnailOf(entry, scenes) {
    const info = entry.infoList;
    if (!Array.isArray(info)) return void 0;
    for (const scene of scenes) {
      const candidate = info.find((e) => isRecord(e) && e.imageScene === scene && nonBlank(e.url));
      if (candidate) return toHttps(candidate.url);
    }
    return void 0;
  }
  function xhsImageVariant(url) {
    let parsed;
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
  var VARIANT_RANK = {
    jpeg: 0,
    original: 1,
    original_ci: 2,
    default: 3,
    other: 4
  };
  function xhsImageDownloadOrder(url, fallbacks = []) {
    const unique = [...new Set([url, ...fallbacks].filter((u) => typeof u === "string" && u.length > 0))];
    return unique.map((u, index) => ({ u, index, variant: xhsImageVariant(u) })).filter((c) => c.variant !== "preview").sort((a, b) => VARIANT_RANK[a.variant] - VARIANT_RANK[b.variant] || a.index - b.index).map((c) => c.u);
  }
  var IMAGE_FIELDS = ["urlDefault", "urlPre", "url", "infoList", "traceId", "fileId", "livePhoto", "stream"];
  function xhsImageProbe(note) {
    if (!isRecord(note)) return [];
    const list = note["imageList"] ?? note["images"];
    if (!Array.isArray(list)) return [];
    return list.flatMap((entry, index) => {
      if (!isRecord(entry)) return [];
      const resolved = imageUrlOf(entry);
      const order = resolved ? xhsImageDownloadOrder(resolved.url, resolved.fallbacks) : [];
      const info = Array.isArray(entry["infoList"]) ? entry["infoList"] : [];
      const probe = {
        index: index + 1,
        fields: IMAGE_FIELDS.filter((key) => entry[key] !== void 0 && entry[key] !== null && entry[key] !== ""),
        scenes: info.flatMap((e) => isRecord(e) && typeof e["imageScene"] === "string" ? [e["imageScene"]] : []),
        candidates: order.map(xhsImageVariant)
      };
      const width = num(entry["width"]);
      const height = num(entry["height"]);
      if (width !== void 0) probe.width = width;
      if (height !== void 0) probe.height = height;
      if (probe.candidates.length > 0) probe.selected = probe.candidates[0];
      return [probe];
    });
  }

  // src/instagram.ts
  var SHORTCODE_PATTERN = /\/(?:p|reels?|tv)\/([A-Za-z0-9-_]+)/;
  var SHORTCODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  var DATA_SJS_PATTERN = /<script\b[^>]*\bdata-sjs[^>]*>(\{.+?\})<\/script>/gs;
  function isRecord2(value) {
    return typeof value === "object" && value !== null;
  }
  function nonBlank2(value) {
    return typeof value === "string" && value.trim().length > 0;
  }
  function toIsoUtcSeconds(seconds) {
    return new Date(seconds * 1e3).toISOString().replace(/\.\d{3}Z$/, "Z");
  }
  function shortcodeToMediaId(shortcode) {
    if (!shortcode) return void 0;
    let id = 0n;
    for (const ch of shortcode) {
      const digit = SHORTCODE_ALPHABET.indexOf(ch);
      if (digit < 0) return void 0;
      id = id * 64n + BigInt(digit);
    }
    return id.toString(10);
  }
  function isProductShaped(obj, mediaId) {
    const matchesId = String(obj["id"] ?? "") === mediaId || String(obj["pk"] ?? "") === mediaId || nonBlank2(obj["code"]) && shortcodeToMediaId(obj["code"]) === mediaId || nonBlank2(obj["shortcode"]) && shortcodeToMediaId(obj["shortcode"]) === mediaId;
    if (!matchesId) return false;
    return "video_versions" in obj || "carousel_media" in obj || "image_versions2" in obj || "display_url" in obj || "video_url" in obj || "edge_sidecar_to_children" in obj;
  }
  function findProduct(root, mediaId) {
    const seen = /* @__PURE__ */ new Set();
    const visit = (node) => {
      if (!isRecord2(node) && !Array.isArray(node)) return void 0;
      if (seen.has(node)) return void 0;
      seen.add(node);
      if (isRecord2(node)) {
        if (isProductShaped(node, mediaId)) return node;
        for (const value of Object.values(node)) {
          const found = visit(value);
          if (found) return found;
        }
        return void 0;
      }
      for (const value of node) {
        const found = visit(value);
        if (found) return found;
      }
      return void 0;
    };
    return visit(root);
  }
  function bestRendition(list) {
    if (!Array.isArray(list)) return void 0;
    let best;
    for (const entry of list) {
      if (!isRecord2(entry) || !nonBlank2(entry["url"])) continue;
      const width = typeof entry["width"] === "number" ? entry["width"] : 0;
      const height = typeof entry["height"] === "number" ? entry["height"] : 0;
      if (!best || width * height > best.width * best.height) {
        best = { url: entry["url"], width, height };
      }
    }
    return best;
  }
  function bestImage(media) {
    const versions = isRecord2(media["image_versions2"]) ? media["image_versions2"]["candidates"] : void 0;
    const best = bestRendition(versions);
    if (best) return best;
    if (nonBlank2(media["display_url"])) {
      const dim = isRecord2(media["dimensions"]) ? media["dimensions"] : {};
      const width = typeof dim["width"] === "number" ? dim["width"] : 0;
      const height = typeof dim["height"] === "number" ? dim["height"] : 0;
      return { url: media["display_url"], width, height };
    }
    return void 0;
  }
  function bestVideoUrl(media) {
    const best = bestRendition(media["video_versions"]);
    if (best) return best;
    if (nonBlank2(media["video_url"])) {
      const dim = isRecord2(media["dimensions"]) ? media["dimensions"] : {};
      const width = typeof dim["width"] === "number" ? dim["width"] : 0;
      const height = typeof dim["height"] === "number" ? dim["height"] : 0;
      return { url: media["video_url"], width, height };
    }
    return void 0;
  }
  function originalMediaItem(media) {
    const image = bestImage(media);
    const video = bestVideoUrl(media);
    if (video) {
      const item = {
        type: "video",
        url: image ? image.url : video.url,
        width: video.width,
        height: video.height
      };
      if (image) item.videoUrl = video.url;
      const rawDuration = media["video_duration"];
      if (typeof rawDuration === "number" && Number.isFinite(rawDuration)) {
        item.duration = rawDuration;
      }
      return item;
    }
    if (image) return { type: "image", url: image.url, width: image.width, height: image.height };
    return void 0;
  }
  function parseInstagram(html, pageUrl, smallThumbnail = false) {
    const shortcodeMatch = SHORTCODE_PATTERN.exec(pageUrl);
    const shortcode = shortcodeMatch ? shortcodeMatch[1] : void 0;
    const mediaId = shortcode ? shortcodeToMediaId(shortcode) : void 0;
    let product;
    if (mediaId) {
      DATA_SJS_PATTERN.lastIndex = 0;
      let match;
      while ((match = DATA_SJS_PATTERN.exec(html)) !== null) {
        let parsed;
        try {
          parsed = JSON.parse(match[1]);
        } catch {
          continue;
        }
        product = findProduct(parsed, mediaId);
        if (product) break;
      }
    }
    if (!product && shortcode) {
      try {
        const g = typeof globalThis !== "undefined" ? globalThis : typeof window !== "undefined" ? window : null;
        const cached = g?.["__easysaveIgProducts"];
        if (cached && isRecord2(cached[shortcode])) {
          product = cached[shortcode];
        }
      } catch (_) {
      }
    }
    const looksLikeInstagram = /instagram\.com|instagr\.am/.test(pageUrl) || /instagram\.com|instagr\.am|data-sjs/.test(html.slice(0, 2e4));
    if (!product || !shortcode) {
      if (looksLikeInstagram) {
        const isAgeGated = /sensitive content|age-restricted|查看帖子|了解详情|see post|成人内容|sensitive_content/i.test(html);
        return {
          ok: false,
          error: {
            code: "LOGIN_REQUIRED",
            message: isAgeGated ? "\u8BE5\u5E16\u5B50\u5305\u542B\u654F\u611F\u5185\u5BB9\u6216\u5E74\u9F84\u9650\u5236\uFF0C\u9700\u8981\u901A\u8FC7\u7F51\u9875\u6388\u6743\u6216\u70B9\u51FB\u67E5\u770B\u3002" : "Instagram returned a login-gated shell without post data."
          }
        };
      }
      return {
        ok: false,
        error: { code: "INVALID_PAGE", message: "Not an Instagram post page." }
      };
    }
    return buildPostFromProduct(product, shortcode, smallThumbnail);
  }
  function buildPostFromProduct(product, shortcode, smallThumbnail = false) {
    for (const line of probeInstagramAiFields(product)) console.info?.("EasySaveIgAiProbe:" + line);
    const user = isRecord2(product["user"]) ? product["user"] : isRecord2(product["owner"]) ? product["owner"] : {};
    const author = {};
    if (nonBlank2(user["username"])) author.name = user["username"];
    const authorId = user["pk"] ?? user["id"];
    if (authorId !== void 0 && authorId !== null && String(authorId).length > 0) {
      author.id = String(authorId);
    }
    let caption = "";
    const captionRaw = product["caption"];
    if (typeof captionRaw === "string") {
      caption = captionRaw;
    } else if (isRecord2(captionRaw) && typeof captionRaw["text"] === "string") {
      caption = captionRaw["text"];
    } else if (isRecord2(product["edge_media_to_caption"])) {
      const edges = product["edge_media_to_caption"]["edges"];
      if (Array.isArray(edges) && edges.length > 0 && isRecord2(edges[0]["node"])) {
        const text2 = edges[0]["node"]["text"];
        if (typeof text2 === "string") caption = text2;
      }
    }
    const takenAt = product["taken_at"] ?? product["taken_at_timestamp"];
    const publishedAt = typeof takenAt === "number" && Number.isFinite(takenAt) ? toIsoUtcSeconds(takenAt) : "";
    const items = [];
    const carousel = product["carousel_media"];
    const sidecar = isRecord2(product["edge_sidecar_to_children"]) ? product["edge_sidecar_to_children"]["edges"] : void 0;
    if (Array.isArray(carousel) && carousel.length > 0) {
      for (const child of carousel) {
        if (!isRecord2(child)) continue;
        const item = mediaItem(child, smallThumbnail);
        if (item) items.push(item);
      }
    } else if (Array.isArray(sidecar) && sidecar.length > 0) {
      for (const edge of sidecar) {
        if (!isRecord2(edge) || !isRecord2(edge["node"])) continue;
        const item = mediaItem(edge["node"], smallThumbnail);
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
          message: "Instagram post has no extractable media."
        }
      };
    }
    const data = {
      platform: "instagram",
      id: shortcode,
      url: `https://www.instagram.com/p/${shortcode}/`,
      author,
      caption,
      items
    };
    if (publishedAt) data.publishedAt = publishedAt;
    const aiLabel = instagramAiLabel(product.ai_label_info);
    if (aiLabel) data.aiLabel = aiLabel;
    return { ok: true, data };
  }
  function probeInstagramAiFields(product) {
    const lines = [];
    const seen = /* @__PURE__ */ new Set();
    let visited = 0;
    const visit = (node, path, privateTree = false, depth = 0) => {
      if (!node || typeof node !== "object" || seen.has(node) || depth > 24 || visited++ > 1e4) return;
      seen.add(node);
      if (Array.isArray(node)) {
        node.forEach((value, i) => visit(value, `${path}[${i}]`, privateTree, depth + 1));
        return;
      }
      for (const [name, value] of Object.entries(node)) {
        if (!/^[A-Za-z_][A-Za-z0-9_]{0,79}$/.test(name)) continue;
        const next = path + "." + name;
        const sensitive = privateTree || /user|owner|author|caption|text|url|email|phone|account|cookie|token|session|password|secret|authorization/i.test(name);
        if ((next.startsWith("$.ai_label_info.") || /ai|gen_ai|genai|label|disclosure|c2pa/i.test(name)) && lines.length < 256) {
          const type = value === null ? "null" : Array.isArray(value) ? "array" : typeof value;
          const record2 = { path: next, name, type };
          if ((next === "$.ai_label_info.attribution_label_text" || next === "$.ai_label_info.subtitle_text") && typeof value === "string") {
            const text2 = value.replace(/[\u0000-\u001f\u007f-\u009f]/g, "");
            if (!/https?:\/\/|[?&][^\s=]+=/i.test(text2)) record2.value = Array.from(text2).slice(0, name === "subtitle_text" ? 120 : 60).join("");
          } else if (!sensitive && (typeof value === "boolean" || typeof value === "number" && Number.isFinite(value) || typeof value === "string" && /^[A-Za-z0-9_]{1,40}$/.test(value))) record2.value = value;
          lines.push(JSON.stringify(record2));
        }
        visit(value, next, sensitive, depth + 1);
      }
    };
    visit(product, "$");
    return lines;
  }
  function mediaItem(media, smallThumbnail) {
    const item = originalMediaItem(media);
    const versions = isRecord2(media.image_versions2) ? media.image_versions2.candidates : void 0;
    if (item && smallThumbnail && Array.isArray(versions)) {
      const candidates = versions.filter((e) => isRecord2(e) && nonBlank2(e.url) && typeof e.width === "number" && typeof e.height === "number" && e.width > 0 && e.height > 0);
      candidates.sort((a, b) => a.width * a.height - b.width * b.height);
      if (candidates[0]) item.thumbnailUrl = candidates[0].url;
    }
    return item;
  }

  // src/x.ts
  var TWEET_ID_PATTERN = /(?:x|twitter)\.com\/(?:[^/]+)\/status\/(\d+)/i;
  var X_ERROR_COPY = {
    LOGIN_REQUIRED: {
      zh: "\u8BE5\u5185\u5BB9\u9700\u8981\u767B\u5F55 X \u624D\u80FD\u67E5\u770B",
      en: "Log in to X to view this post."
    },
    AGE_NOT_SET: {
      zh: "\u8BE5\u5185\u5BB9\u9700\u8981\u4F60\u7684 X \u8D26\u53F7\u5148\u8BBE\u7F6E\u51FA\u751F\u65E5\u671F\uFF08\u5E74\u9F84\uFF09\u540E\u624D\u80FD\u67E5\u770B",
      en: "Add your date of birth to your X account to view this post."
    },
    AGE_RESTRICTED: {
      zh: "\u8BE5\u5E16\u5B50\u6709\u5E74\u9F84\u9650\u5236\uFF0C\u9700\u8981\u767B\u5F55\u5DF2\u5B8C\u6210\u5E74\u9F84\u9A8C\u8BC1\u7684 X \u8D26\u53F7\u624D\u80FD\u67E5\u770B",
      en: "This post is age-restricted. Log in with an age-verified X account to view it."
    },
    PROTECTED: {
      zh: "\u8BE5\u5E16\u5B50\u6765\u81EA\u53D7\u4FDD\u62A4\u7684\u8D26\u53F7\uFF0C\u53EA\u6709\u83B7\u51C6\u7684\u5173\u6CE8\u8005\u53EF\u4EE5\u67E5\u770B",
      en: "This post is from a protected account; only approved followers can view it."
    },
    PRIVATE_OR_UNAVAILABLE: {
      zh: "\u5E16\u5B50\u4E0D\u53EF\u7528\uFF1A\u53EF\u80FD\u5DF2\u5220\u9664\u3001\u8BBE\u4E3A\u79C1\u5BC6\uFF0C\u6216\u9700\u8981\u767B\u5F55 X \u624D\u80FD\u67E5\u770B",
      en: "Post unavailable: it may be deleted, private, or require logging in to X."
    }
  };
  var X_SENSITIVE_MEDIA_HINT = {
    zh: "\u8BE5\u5E16\u5B50\u6709\u5E74\u9F84\u9650\u5236\u3002\u5DF2\u767B\u5F55 X \u4ECD\u65E0\u6CD5\u67E5\u770B\u65F6\uFF0C\u8BF7\u5728 X \u7684\u201C\u8BBE\u7F6E \u2192 \u9690\u79C1\u548C\u5B89\u5168 \u2192 \u4F60\u770B\u5230\u7684\u5185\u5BB9\u201D\u4E2D\u5F00\u542F\u201C\u663E\u793A\u53EF\u80FD\u5305\u542B\u654F\u611F\u5185\u5BB9\u7684\u5A92\u4F53\u201D\uFF0C\u5E76\u786E\u8BA4\u8D26\u53F7\u5DF2\u5B8C\u6210\u5E74\u9F84\u9A8C\u8BC1",
    en: `This post is age-restricted. If it stays unavailable while logged in, turn on "Display media that may contain sensitive content" under X Settings \u2192 Privacy and safety \u2192 Content you see, and confirm your account's age.`
  };
  var X_SESSION_EXPIRED = {
    zh: "X \u767B\u5F55\u72B6\u6001\u5DF2\u5931\u6548\uFF0C\u8BF7\u5728 EasySave \u4E2D\u91CD\u65B0\u767B\u5F55 X \u540E\u91CD\u8BD5",
    en: "Your X session has expired. Log in to X again in EasySave and retry."
  };
  function xFailure(code) {
    return { ok: false, error: { code, message: X_ERROR_COPY[code].zh } };
  }
  function classifyXUnavailable(result) {
    const typename = result["__typename"];
    const reason = typeof result["reason"] === "string" ? result["reason"] : "";
    if (typename === "TweetUnavailable" || typename === void 0 && reason) {
      switch (reason) {
        case "NsfwLoggedOut":
          return xFailure("LOGIN_REQUIRED");
        case "NsfwViewerHasNoStatedAge":
          return xFailure("AGE_NOT_SET");
        case "NsfwViewerIsUnderage":
          return xFailure("AGE_RESTRICTED");
        case "Protected":
          return xFailure("PROTECTED");
      }
      if (/log.?in|sign.?in|authentication/i.test(reason)) return xFailure("LOGIN_REQUIRED");
      if (/age/i.test(reason)) return xFailure("AGE_RESTRICTED");
      return typename === "TweetUnavailable" ? xFailure("PRIVATE_OR_UNAVAILABLE") : void 0;
    }
    if (typename === "TweetTombstone") {
      const text2 = tombstoneText(result);
      if (/^age.restricted/i.test(text2.trim())) return xFailure("AGE_RESTRICTED");
      if (/(?:log|sign)\s*in\b/i.test(text2)) return xFailure("LOGIN_REQUIRED");
      return xFailure("PRIVATE_OR_UNAVAILABLE");
    }
    return void 0;
  }
  function tombstoneText(result) {
    const tombstone = result["tombstone"];
    const textObj = isRecord3(tombstone) ? tombstone["text"] : void 0;
    return isRecord3(textObj) && typeof textObj["text"] === "string" ? textObj["text"] : "";
  }
  function isRecord3(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
  }
  function normalizeImageUrl(url) {
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
  function formatUtc(dateStr) {
    try {
      const d = new Date(dateStr);
      if (isNaN(d.getTime())) return void 0;
      return d.toISOString().replace(/\.\d{3}Z$/, "Z");
    } catch {
      return void 0;
    }
  }
  function extractTweetId(url) {
    const m = TWEET_ID_PATTERN.exec(url);
    return m ? m[1] : void 0;
  }
  function calculateToken(id) {
    return (Number(id) / 1e15 * Math.PI).toString(36).replace(/(0+|\.)/g, "");
  }
  function parseX(input, pageUrl) {
    let root;
    if (typeof input === "string") {
      const trimmed = input.trim();
      if (trimmed.startsWith("<")) {
        const visible = trimmed.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");
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
    if (!isRecord3(root) || Object.keys(root).length === 0) {
      return xFailure("PRIVATE_OR_UNAVAILABLE");
    }
    const errors = Array.isArray(root["errors"]) ? root["errors"] : [];
    const restricted = /nsfwloggedout|age.?restrict|age.?verif|log.?in|sign.?in|authentication/i;
    if (errors.some((error) => isRecord3(error) && ([32, 215, 239].includes(Number(error["code"])) || restricted.test(typeof error["message"] === "string" ? error["message"] : "")))) {
      return xFailure("LOGIN_REQUIRED");
    }
    const unavailable = classifyXUnavailable(root);
    if (unavailable) return unavailable;
    if (Array.isArray(root["errors"]) && root["errors"].length > 0) {
      return xFailure("PRIVATE_OR_UNAVAILABLE");
    }
    const idStr = typeof root["id_str"] === "string" ? root["id_str"] : typeof root["id"] === "number" || typeof root["id"] === "string" ? String(root["id"]) : extractTweetId(pageUrl);
    if (!idStr) {
      return {
        ok: false,
        error: {
          code: "INVALID_PAGE",
          message: "Unable to extract tweet ID."
        }
      };
    }
    const user = isRecord3(root["user"]) ? root["user"] : void 0;
    const screenName = typeof user?.["screen_name"] === "string" ? user["screen_name"] : "";
    const name = typeof user?.["name"] === "string" ? user["name"] : void 0;
    const canonicalUrl = screenName ? `https://x.com/${screenName}/status/${idStr}` : `https://x.com/i/status/${idStr}`;
    const caption = typeof root["text"] === "string" ? root["text"] : "";
    const publishedAt = typeof root["created_at"] === "string" ? formatUtc(root["created_at"]) : void 0;
    const items = [];
    const mediaDetails = Array.isArray(root["mediaDetails"]) ? root["mediaDetails"] : [];
    for (const media of mediaDetails) {
      if (!isRecord3(media)) continue;
      const mediaType = media["type"];
      const originalInfo = isRecord3(media["original_info"]) ? media["original_info"] : void 0;
      const width = typeof originalInfo?.["width"] === "number" ? originalInfo["width"] : void 0;
      const height = typeof originalInfo?.["height"] === "number" ? originalInfo["height"] : void 0;
      const mediaUrlHttps = typeof media["media_url_https"] === "string" ? media["media_url_https"] : "";
      if (mediaType === "photo") {
        if (mediaUrlHttps) {
          items.push({
            type: "image",
            url: normalizeImageUrl(mediaUrlHttps),
            width,
            height
          });
        }
      } else if (mediaType === "video") {
        const videoInfo = isRecord3(media["video_info"]) ? media["video_info"] : void 0;
        const variants = Array.isArray(videoInfo?.["variants"]) ? videoInfo["variants"] : [];
        const mp4Variants = variants.filter((v) => isRecord3(v) && v["content_type"] === "video/mp4" && typeof v["url"] === "string").sort((a, b) => (Number(b["bitrate"]) || 0) - (Number(a["bitrate"]) || 0));
        const best = mp4Variants[0];
        if (best && typeof best["url"] === "string") {
          const item = {
            type: "video",
            url: best["url"],
            posterUrl: mediaUrlHttps ? normalizeImageUrl(mediaUrlHttps) : void 0,
            width,
            height
          };
          const durationMillis = typeof videoInfo?.["duration_millis"] === "number" ? videoInfo["duration_millis"] : 0;
          if (durationMillis > 0) {
            item.duration = Math.round(durationMillis / 1e3 * 1e3) / 1e3;
          }
          items.push(item);
        }
      } else if (mediaType === "animated_gif") {
        const videoInfo = isRecord3(media["video_info"]) ? media["video_info"] : void 0;
        const variants = Array.isArray(videoInfo?.["variants"]) ? videoInfo["variants"] : [];
        const mp4Variants = variants.filter((v) => isRecord3(v) && v["content_type"] === "video/mp4" && typeof v["url"] === "string").sort((a, b) => (Number(b["bitrate"]) || 0) - (Number(a["bitrate"]) || 0));
        const best = mp4Variants[0];
        if (best && typeof best["url"] === "string") {
          items.push({
            type: "video",
            isGif: true,
            url: best["url"],
            posterUrl: mediaUrlHttps ? normalizeImageUrl(mediaUrlHttps) : void 0,
            width,
            height
          });
        }
      }
    }
    const post = {
      platform: "x",
      id: idStr,
      url: canonicalUrl,
      author: {
        name,
        id: screenName || void 0
      },
      caption,
      publishedAt,
      items
    };
    return { ok: true, data: post };
  }
  function graphqlTweetResult(responses, id) {
    for (const response of responses) {
      if (!isRecord3(response) || !isRecord3(response["data"])) continue;
      const data = response["data"];
      const byRestId = isRecord3(data["tweetResult"]) ? data["tweetResult"]["result"] : void 0;
      if (isRecord3(byRestId)) return byRestId;
      const thread = data["threaded_conversation_with_injections_v2"];
      const instructions = isRecord3(thread) && Array.isArray(thread["instructions"]) ? thread["instructions"] : [];
      for (const instruction of instructions) {
        const entries = isRecord3(instruction) && Array.isArray(instruction["entries"]) ? instruction["entries"] : [];
        for (const entry of entries) {
          if (!isRecord3(entry) || entry["entryId"] !== `tweet-${id}`) continue;
          const content = entry["content"];
          const itemContent = isRecord3(content) ? content["itemContent"] : void 0;
          const results = isRecord3(itemContent) ? itemContent["tweet_results"] : void 0;
          const result = isRecord3(results) ? results["result"] : void 0;
          if (isRecord3(result)) return result;
        }
      }
    }
    return void 0;
  }
  function unwrapVisibility(result) {
    return result["__typename"] === "TweetWithVisibilityResults" && isRecord3(result["tweet"]) ? result["tweet"] : result;
  }
  function parseXGraphql(responses, pageUrl) {
    const id = extractTweetId(pageUrl);
    if (!id) return { ok: false, error: { code: "UNSUPPORTED_URL", message: "Unable to extract tweet ID." } };
    const found = graphqlTweetResult(responses, id);
    if (!found) {
      return { ok: false, error: { code: "INVALID_PAGE", message: "X page returned no post data." } };
    }
    const result = unwrapVisibility(found);
    const unavailable = classifyXUnavailable(result);
    if (unavailable) return unavailable;
    const legacy = isRecord3(result["legacy"]) ? result["legacy"] : void 0;
    if (!legacy) return xFailure("PRIVATE_OR_UNAVAILABLE");
    const core = isRecord3(result["core"]) ? result["core"] : void 0;
    const userResults = core && isRecord3(core["user_results"]) ? core["user_results"] : void 0;
    const user = userResults && isRecord3(userResults["result"]) ? userResults["result"] : void 0;
    const userLegacy = user && isRecord3(user["legacy"]) ? user["legacy"] : {};
    const userCore = user && isRecord3(user["core"]) ? user["core"] : {};
    const pick = (key) => typeof userLegacy[key] === "string" ? userLegacy[key] : typeof userCore[key] === "string" ? userCore[key] : void 0;
    const entities = isRecord3(legacy["extended_entities"]) ? legacy["extended_entities"] : isRecord3(legacy["entities"]) ? legacy["entities"] : {};
    const media = Array.isArray(entities["media"]) ? entities["media"] : [];
    const noteTweet = isRecord3(result["note_tweet"]) ? result["note_tweet"] : void 0;
    const noteResults = noteTweet && isRecord3(noteTweet["note_tweet_results"]) ? noteTweet["note_tweet_results"] : void 0;
    const noteResult = noteResults && isRecord3(noteResults["result"]) ? noteResults["result"] : void 0;
    let text2 = typeof noteResult?.["text"] === "string" ? noteResult["text"] : typeof legacy["full_text"] === "string" ? legacy["full_text"] : "";
    for (const item of media) {
      const link = isRecord3(item) && typeof item["url"] === "string" ? item["url"] : "";
      if (link && text2.endsWith(link)) text2 = text2.slice(0, -link.length).trimEnd();
    }
    const restId = typeof result["rest_id"] === "string" ? result["rest_id"] : id;
    return parseX({
      id_str: restId,
      user: { screen_name: pick("screen_name"), name: pick("name") },
      text: text2,
      created_at: legacy["created_at"],
      mediaDetails: media
    }, pageUrl);
  }
  var SHORT_TOKEN = /^[A-Za-z0-9_]{1,48}$/;
  function shortToken(value) {
    return typeof value === "string" && SHORT_TOKEN.test(value) ? value : void 0;
  }
  function xProbe(input, source, pageUrl) {
    let root = input;
    if (source === "syndication") {
      if (typeof input !== "string" || input.trim() === "") return { source, shape: "empty", fields: [] };
      try {
        root = JSON.parse(input);
      } catch {
        return { source, shape: "unknown", fields: [] };
      }
    }
    let result;
    let fields = [];
    if (source === "graphql") {
      const responses = Array.isArray(root) ? root : [];
      const id = extractTweetId(pageUrl) ?? "";
      result = graphqlTweetResult(responses, id);
      if (!result) return { source, shape: "none", fields: [] };
    } else {
      if (!isRecord3(root)) return { source, shape: "unknown", fields: [] };
      if (Object.keys(root).length === 0) return { source, shape: "empty", fields: [] };
      result = root;
    }
    fields = Object.keys(result).filter((key) => SHORT_TOKEN.test(key)).sort().slice(0, 24);
    const wrapped = result["__typename"] === "TweetWithVisibilityResults";
    const inner = unwrapVisibility(result);
    const typename = shortToken(inner["__typename"]);
    const probe = { source, shape: "unknown", fields };
    if (typename) probe.typename = typename;
    if (wrapped) probe.wrapped = true;
    const reason = shortToken(inner["reason"]);
    if (reason) probe.reason = reason;
    if (typename === "TweetTombstone") {
      probe.shape = "tombstone";
      probe.tombstone = tombstoneText(inner).slice(0, 40);
    } else if (typename === "TweetUnavailable" || !typename && reason) {
      probe.shape = "unavailable";
    } else if (Array.isArray(inner["errors"]) && !isRecord3(inner["legacy"]) && !inner["id_str"]) {
      probe.shape = "errors";
    } else if (isRecord3(inner["legacy"]) || inner["id_str"] !== void 0) {
      probe.shape = "tweet";
      const legacy = isRecord3(inner["legacy"]) ? inner["legacy"] : void 0;
      const entities = legacy && isRecord3(legacy["extended_entities"]) ? legacy["extended_entities"] : void 0;
      const media = entities ? entities["media"] : inner["mediaDetails"];
      probe.mediaCount = Array.isArray(media) ? media.length : 0;
    }
    return probe;
  }

  // src/tiktok.ts
  var record = (v) => v !== null && typeof v === "object" && !Array.isArray(v) ? v : {};
  var text = (v) => typeof v === "string" ? v : void 0;
  var number = (v) => typeof v === "number" && Number.isFinite(v) ? v : 0;
  function extractTiktokPostId(url) {
    try {
      const u = new URL(url);
      if (!["http:", "https:"].includes(u.protocol) || !["www.tiktok.com", "m.tiktok.com", "tiktok.com"].includes(u.hostname)) return;
      return /^\/@[^/]*\/(?:video|photo)\/(\d+)\/?$/.exec(u.pathname)?.[1] ?? /^\/v\/(\d+)\.html\/?$/.exec(u.pathname)?.[1] ?? /^\/share\/video\/(\d+)\/?$/.exec(u.pathname)?.[1];
    } catch {
      return;
    }
  }
  function isTiktokLink(url) {
    if (extractTiktokPostId(url)) return true;
    try {
      const u = new URL(url);
      return ["http:", "https:"].includes(u.protocol) && ["vm.tiktok.com", "vt.tiktok.com"].includes(u.hostname) && /^\/[^/]+\/?$/.test(u.pathname);
    } catch {
      return false;
    }
  }
  function urls(value) {
    const values = Array.isArray(value) ? value : [value];
    return [...new Set(values.filter((v) => {
      if (typeof v !== "string") return false;
      try {
        return ["https:", "http:"].includes(new URL(v).protocol);
      } catch {
        return false;
      }
    }))];
  }
  function selectTiktokPoster(value) {
    const candidates = [];
    const push = (raw) => {
      candidates.push(...urls(raw));
      if (raw !== null && typeof raw === "object") {
        const holder = record(raw);
        candidates.push(...urls(record(holder.imageURL).urlList), ...urls(holder.urlList));
      }
    };
    const source = record(value);
    push(source.originCover);
    push(source.cover);
    push(source.dynamicCover);
    push(record(source.video).originCover);
    push(record(source.video).cover);
    push(record(source.video).dynamicCover);
    return candidates[0];
  }
  function selectTiktokVideo(value) {
    const video = record(value);
    const variants = (Array.isArray(video.bitrateInfo) ? video.bitrateInfo : []).map((v) => {
      const b = record(v), addr = record(b.PlayAddr);
      return {
        urls: urls(addr.UrlList),
        width: number(addr.Width),
        height: number(addr.Height),
        bitrate: number(b.Bitrate)
      };
    }).filter((v) => v.urls.length > 0).sort((a, b) => b.width * b.height - a.width * a.height || b.bitrate - a.bitrate);
    const candidates = [.../* @__PURE__ */ new Set([
      ...variants.flatMap((v) => v.urls),
      ...urls(video.playAddr),
      ...urls(record(video.PlayAddrStruct).UrlList)
    ])];
    if (!candidates.length) return;
    return {
      type: "video",
      url: candidates[0],
      videoUrl: candidates[0],
      fallbacks: candidates.slice(1),
      width: variants[0]?.width || number(video.width) || void 0,
      height: variants[0]?.height || number(video.height) || void 0,
      duration: number(video.duration) || void 0
    };
  }
  function failure(detail) {
    const status = Number(detail.statusCode);
    const message = (text(detail.statusMsg) ?? text(detail.statusMessage))?.toLowerCase() ?? "";
    if ([10216, 10222].includes(status) || /private/.test(message))
      return { ok: false, error: { code: "PRIVATE", message: "\u8BE5 TikTok \u5E16\u5B50\u6216\u8D26\u53F7\u4E3A\u79C1\u5BC6" } };
    if (status === 10204 || /region|country|geo.?block|ip.*block/.test(message))
      return { ok: false, error: { code: "REGION_RESTRICTED", message: "\u8BE5 TikTok \u5E16\u5B50\u53D7\u5730\u533A\u6216 IP \u9650\u5236" } };
    if (/deleted|removed|not found|does not exist/.test(message))
      return { ok: false, error: { code: "DELETED", message: "\u8BE5 TikTok \u5E16\u5B50\u5DF2\u5220\u9664\u6216\u4E0D\u5B58\u5728" } };
    return { ok: false, error: { code: "UNKNOWN", message: "\u65E0\u6CD5\u8BFB\u53D6 TikTok \u5E16\u5B50\uFF0C\u8BF7\u91CD\u65B0\u89E3\u6790" } };
  }
  function parseTiktok(input, pageUrl) {
    const wanted = extractTiktokPostId(pageUrl);
    if (!wanted) return { ok: false, error: { code: "UNSUPPORTED_URL", message: "\u8BF7\u5148\u5C55\u5F00 TikTok \u77ED\u94FE" } };
    let root;
    try {
      const json = input.trim().startsWith("{") ? input : /<script\b[^>]*\bid=["']__UNIVERSAL_DATA_FOR_REHYDRATION__["'][^>]*>([\s\S]*?)<\/script>/i.exec(input)?.[1];
      root = record(JSON.parse(json ?? ""));
    } catch {
      return failure({});
    }
    const scope = record(root.__DEFAULT_SCOPE__);
    const details = ["webapp.video-detail", "webapp.reflow.video.detail"].map((key) => record(scope[key])).filter((detail2) => Object.keys(detail2).length > 0);
    const detail = details.find((detail2) => Number(detail2.statusCode) === 0 && text(record(record(detail2.itemInfo).itemStruct).id) === wanted) ?? details[0] ?? {};
    const item = record(record(detail.itemInfo).itemStruct);
    if (Number(detail.statusCode) !== 0 || !Object.keys(item).length) return failure(detail);
    const id = text(item.id);
    if (!id || !/^\d+$/.test(id) || id !== wanted) return failure({});
    const imagePost = record(item.imagePost);
    let items;
    if (Array.isArray(imagePost.images)) {
      items = imagePost.images.map((raw) => {
        const image = record(raw), addr = record(image.imageURL);
        const candidates = urls(addr.urlList);
        return {
          type: "image",
          url: candidates[0],
          fallbacks: candidates.slice(1),
          width: number(image.imageWidth) || void 0,
          height: number(image.imageHeight) || void 0
        };
      });
      if (items.some((i) => !i.url)) return failure({});
      const cover = selectTiktokPoster({ cover: imagePost.cover });
      if (cover && items.length) items[0] = { ...items[0], posterUrl: cover };
    } else {
      const video = selectTiktokVideo(item.video);
      const poster = selectTiktokPoster({ video: item.video });
      items = video ? [{ ...video, posterUrl: poster }] : [];
    }
    if (!items.length) return failure({});
    const author = record(item.author), authorId = text(author.id);
    const created = Number(item.createTime);
    const date = new Date(created * 1e3);
    return { ok: true, data: {
      platform: "tiktok",
      id,
      url: `https://www.tiktok.com/@/video/${id}`,
      author: { name: text(author.nickname), id: authorId && /^\d+$/.test(authorId) ? authorId : void 0 },
      caption: text(item.desc),
      title: text(imagePost.title),
      aiLabel: tiktokAiLabel(item.aigcLabelType, id),
      publishedAt: created > 0 && !isNaN(date.getTime()) ? date.toISOString().replace(".000Z", "Z") : void 0,
      items
    } };
  }
  function tiktokExpiresAt(url) {
    try {
      let earliest = Infinity;
      new URL(url).searchParams.forEach((value, key) => {
        if (!["expire", "x-expires"].includes(key.toLowerCase()) || !/^[0-9]+$/.test(value)) return;
        const seconds = Number(value), ms = seconds * 1e3;
        if (Number.isSafeInteger(seconds) && Number.isSafeInteger(ms) && !Number.isNaN(new Date(ms).getTime())) earliest = Math.min(earliest, ms);
      });
      return Number.isFinite(earliest) ? new Date(earliest).toISOString() : void 0;
    } catch {
      return void 0;
    }
  }

  // src/_utils.ts
  function hostnameOf(url) {
    try {
      const { hostname } = new URL(url);
      return hostname ?? null;
    } catch {
      return null;
    }
  }
  function isXhsHost(host) {
    return /xiaohongshu\.com|rednote\.com|xhslink\.com|xhslink\.cn|xhs\.cn/.test(host);
  }
  function isInstagramHost(host) {
    return /instagram\.com|instagr\.am/.test(host);
  }
  function isXHost(host) {
    return /x\.com|twitter\.com/.test(host);
  }

  // src/media-resources.ts
  function withMediaResources(result, site, expiry = () => void 0) {
    if (!result?.ok || !Array.isArray(result.data?.items)) return result;
    const defaults = site.download;
    const request = (role, url) => {
      const extra = defaults.resourceDefaults?.[role] ?? {};
      return {
        headers: { ...defaults.headers, ...extra.headers },
        cookieDomains: [...extra.cookieDomains ?? defaults.cookieDomains],
        expiresAt: expiry(url),
        transport: extra.transport ?? defaults.transport,
        resumable: extra.resumable ?? defaults.resumable
      };
    };
    return { ...result, data: { ...result.data, items: result.data.items.map((item) => {
      const video = item.type === "video";
      const primary = video ? item.videoUrl && item.videoUrl !== item.url ? "poster" : "video" : "image";
      const resources = [{ role: primary, url: item.url, request: request(primary, item.url) }];
      if (item.videoUrl && (!video || item.videoUrl !== item.url)) {
        const role = video ? "video" : "motion";
        resources.push({ role, url: item.videoUrl, request: request(role, item.videoUrl) });
      }
      if (item.posterUrl) resources.push({
        role: "poster",
        url: item.posterUrl,
        request: request("poster", item.posterUrl)
      });
      if (item.thumbnailUrl) resources.push({
        role: "poster",
        url: item.thumbnailUrl,
        request: request("poster", item.thumbnailUrl)
      });
      for (const url of item.fallbacks ?? []) resources.push({
        role: "fallback",
        fallbackFor: primary,
        url,
        request: request(primary, url)
      });
      return { ...item, resources };
    }) } };
  }

  // src/page-hooks.js
  function installIgSniff() {
    (() => {
      if (window.__easysaveSniffInstalled) return;
      window.__easysaveSniffInstalled = true;
      window.__easysaveIgProducts = window.__easysaveIgProducts || {};
      function isProductShaped2(obj) {
        if (!obj || typeof obj !== "object") return false;
        const sc = typeof obj.shortcode === "string" ? obj.shortcode : typeof obj.code === "string" ? obj.code : null;
        if (!sc) return false;
        return "video_versions" in obj || "carousel_media" in obj || "image_versions2" in obj || "display_url" in obj || "video_url" in obj || "edge_sidecar_to_children" in obj;
      }
      function extractProducts(payload) {
        const seen = /* @__PURE__ */ new Set();
        function visit(node) {
          if (!node || typeof node !== "object") return;
          if (seen.has(node)) return;
          seen.add(node);
          if (isProductShaped2(node)) {
            const sc = typeof node.shortcode === "string" ? node.shortcode : node.code;
            window.__easysaveIgProducts[sc] = node;
          }
          if (Array.isArray(node)) {
            for (const item of node) visit(item);
          } else {
            for (const key of Object.keys(node)) visit(node[key]);
          }
        }
        try {
          visit(payload);
        } catch (_) {
        }
      }
      function sniffText(text2) {
        if (!text2 || text2.length < 10) return;
        if (!text2.includes("shortcode") && !text2.includes("xdt_shortcode_media") && !text2.includes("edge_sidecar_to_children") && !text2.includes("display_url")) return;
        try {
          const json = JSON.parse(text2);
          extractProducts(json);
        } catch (_) {
        }
      }
      try {
        const originalFetch = window.fetch;
        if (originalFetch) {
          window.fetch = async function(...args) {
            const response = await originalFetch.apply(this, args);
            try {
              const clone = response.clone();
              clone.text().then(sniffText).catch(() => {
              });
            } catch (_) {
            }
            return response;
          };
        }
      } catch (_) {
      }
      try {
        const originalOpen = XMLHttpRequest.prototype.open;
        const originalSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          this.__url = url;
          return originalOpen.apply(this, [method, url, ...rest]);
        };
        XMLHttpRequest.prototype.send = function(...args) {
          this.addEventListener("load", function() {
            try {
              sniffText(this.responseText);
            } catch (_) {
            }
          });
          return originalSend.apply(this, args);
        };
      } catch (_) {
      }
    })();
  }
  function readXhsAccount() {
    return JSON.parse(function() {
      try {
        var unwrap = function(v) {
          return v && v.__v_isRef ? v.value : v;
        };
        var state = window.__INITIAL_STATE__;
        var user = state && unwrap(state.user);
        if (!user) return JSON.stringify({ state: "unknown" });
        var loggedIn = unwrap(user.loggedIn);
        if (typeof loggedIn !== "boolean") return JSON.stringify({ state: "unknown" });
        if (!loggedIn) return JSON.stringify({ state: "guest" });
        var info = unwrap(user.userInfo);
        var result = { state: "user" };
        if (info && info.userId) result.userId = String(info.userId);
        if (info && info.nickname) result.nickname = String(info.nickname);
        return JSON.stringify(result);
      } catch (e) {
        return JSON.stringify({ state: "unknown" });
      }
    }());
  }
  function tiktokReady() {
    return (() => {
      try {
        const node = document.getElementById("__UNIVERSAL_DATA_FOR_REHYDRATION__");
        const root = window.__UNIVERSAL_DATA_FOR_REHYDRATION__ || node && JSON.parse(node.textContent);
        const scope = root && root.__DEFAULT_SCOPE__;
        return !!(scope && ["webapp.video-detail", "webapp.reflow.video.detail"].some((key) => {
          const detail = scope[key];
          return detail && (detail.itemInfo && detail.itemInfo.itemStruct && detail.itemInfo.itemStruct.id || detail.statusCode != null && Number(detail.statusCode) !== 0);
        }));
      } catch (_) {
        return false;
      }
    })();
  }
  function installXGraphqlSniff() {
    (() => {
      if (window.__easysaveXSniffInstalled) return;
      window.__easysaveXSniffInstalled = true;
      window.__easysaveXGraphql = window.__easysaveXGraphql || [];
      const pattern = /\/graphql\/[^/?#]+\/(TweetResultByRestId|TweetDetail)(?:[?#]|$)/;
      function keep(url, text2) {
        const match = pattern.exec(String(url || ""));
        if (!match || typeof text2 !== "string" || text2.length > 4e6) return;
        const list = window.__easysaveXGraphql;
        list.push({ op: match[1], text: text2 });
        while (list.length > 8) list.shift();
      }
      try {
        const originalFetch = window.fetch;
        if (originalFetch) {
          window.fetch = async function(...args) {
            const response = await originalFetch.apply(this, args);
            try {
              const input = args[0];
              const url = typeof input === "string" ? input : input && input.url || "";
              if (pattern.test(String(url))) response.clone().text().then((text2) => keep(url, text2)).catch(() => {
              });
            } catch (_) {
            }
            return response;
          };
        }
      } catch (_) {
      }
      try {
        const originalOpen = XMLHttpRequest.prototype.open;
        const originalSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url, ...rest) {
          this.__easysaveXUrl = url;
          return originalOpen.apply(this, [method, url, ...rest]);
        };
        XMLHttpRequest.prototype.send = function(...args) {
          if (pattern.test(String(this.__easysaveXUrl || ""))) {
            this.addEventListener("load", function() {
              try {
                if (this.responseType === "" || this.responseType === "text") keep(this.__easysaveXUrl, this.responseText);
                else if (this.responseType === "json") keep(this.__easysaveXUrl, JSON.stringify(this.response));
              } catch (_) {
              }
            });
          }
          return originalSend.apply(this, args);
        };
      } catch (_) {
      }
    })();
  }

  // src/parser-modules.ts
  var page = () => window;
  var failure2 = (code, message) => ({ code, message });
  var onXPage = () => {
    try {
      return /(?:^|\.)(?:x|twitter)\.com$/i.test(location.hostname);
    } catch (_) {
      return false;
    }
  };
  var xCaptured = () => (page().__easysaveXGraphql || []).flatMap((entry) => {
    try {
      return [JSON.parse(entry.text)];
    } catch (_) {
      return [];
    }
  });
  var modules = {
    x: {
      // The logged-in entry page (load.entryTemplate) is read from the page's own
      // GraphQL responses; the guest JSON endpoint path never runs these hooks.
      install: () => {
        if (onXPage()) installXGraphqlSniff();
      },
      ready: (c) => {
        const id = extractTweetId(c.url);
        return !onXPage() || (page().__easysaveXGraphql || []).some((entry) => entry.op === "TweetResultByRestId" || !!id && typeof entry.text === "string" && entry.text.includes(`"tweet-${id}"`));
      },
      parsePage: (c) => parseXGraphql(xCaptured(), c.url),
      probe: (c) => onXPage() ? { tag: "XProbe", ...xProbe(xCaptured(), "graphql", c.url) } : { tag: "XProbe", ...xProbe(c.input ?? "", "syndication", c.url) },
      classify: (c) => {
        if (!c.loggedIn) return c.error;
        if (!onXPage()) return c.error;
        if (c.error?.code === "AGE_RESTRICTED") return failure2("AGE_RESTRICTED", X_SENSITIVE_MEDIA_HINT.zh);
        if (c.error?.code === "LOGIN_REQUIRED") return failure2("LOGIN_REQUIRED", X_SESSION_EXPIRED.zh);
        return c.error;
      },
      request: (c) => {
        const id = extractTweetId(c.url);
        if (!id) throw new Error("UNSUPPORTED_URL");
        const template = c.site.load.endpointTemplate;
        return {
          url: template.replaceAll("{id}", id).replaceAll("{token}", calculateToken(id)),
          headers: c.site.load.headers || {}
        };
      },
      parse: (c) => c.statusCode === 404 ? { ok: false, error: failure2("PRIVATE_OR_UNAVAILABLE", "Post is unavailable or private") } : parseX(c.input || "", c.url)
    },
    xhs: {
      // App-only download order: original resolution first, preview scenes
      // (WB_PRV / H5_PRV / !nd_prv) never. The legacy url/fallbacks stay as-is.
      decorate: (result) => !result?.ok || !Array.isArray(result.data?.items) ? result : { ...result, data: { ...result.data, items: result.data.items.map((item) => item.type === "video" ? item : { ...item, downloadOrder: xhsImageDownloadOrder(item.url, item.fallbacks ?? []) }) } },
      ready: (c) => {
        const state = page().__INITIAL_STATE__;
        if (!state) return false;
        const wanted = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-zA-Z0-9]+)/.exec(c.url)?.[1];
        const map = state.note?.noteDetailMap;
        if (map) return wanted ? Object.hasOwn(map, wanted) : Object.keys(map).length > 0;
        const note = state.noteData?.data?.noteData || state.noteData?.data;
        return !!note && (!wanted || !(note.noteId || note.id) || (note.noteId || note.id) === wanted);
      },
      account: () => readXhsAccount(),
      probe: (c) => {
        const id = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-zA-Z0-9]+)/.exec(c.url)?.[1];
        const note = findNoteInStates([page().__INITIAL_STATE__], id);
        return { tag: "XhsStreamProbe", streams: xhsStreamProbe(note?.["video"]), images: xhsImageProbe(note) };
      },
      probeSession: (c) => {
        if ((c.statusCode || 0) >= 300 && (c.statusCode || 0) < 400) return !(c.location || "").includes("/login");
        if (c.statusCode !== 200) return true;
        if ((c.input || "").includes('"loggedIn":false')) return false;
        return true;
      },
      classify: (c) => ["LOGIN_REQUIRED", "INVALID_PAGE"].includes(c.error?.code) ? c.loggedIn ? failure2("PRIVATE_OR_UNAVAILABLE", "\u672A\u80FD\u8BFB\u53D6\u7B14\u8BB0\u5185\u5BB9\uFF08\u5206\u4EAB\u94FE\u63A5\u53EF\u80FD\u5DF2\u8FC7\u671F\uFF0C\u8BF7\u91CD\u65B0\u7C98\u8D34\u539F\u5206\u4EAB\u94FE\u63A5\u518D\u8BD5\uFF09") : failure2("LOGIN_REQUIRED", "\u9700\u8981\u5148\u767B\u5F55\u5C0F\u7EA2\u4E66\u624D\u80FD\u89E3\u6790\u8BE5\u7B14\u8BB0") : c.error
    },
    instagram: {
      install: () => installIgSniff(),
      ready: (c) => {
        const id = /\/(?:p|reels?|tv)\/([A-Za-z0-9_-]+)/.exec(c.url)?.[1];
        return !!(id && page().__easysaveIgProducts?.[id]) || !!document.querySelector("article video, main video, article img, main img");
      },
      prepare: () => {
        const words = ["see post", "view post", "\u67E5\u770B\u5E16\u5B50", "\u67E5\u770B\u8CBC\u6587", "\u4E86\u89E3\u8BE6\u60C5", "continue", "i understand", "\u786E\u8BA4"];
        for (const node of Array.from(document.querySelectorAll('button, [role="button"], a[role="button"]'))) {
          const text2 = (node.innerText || node.textContent || "").trim().toLowerCase();
          if (words.some((word) => text2.includes(word))) {
            node.click();
            return true;
          }
        }
        return false;
      },
      classify: (c) => c.error?.code === "LOGIN_REQUIRED" && c.loggedIn ? failure2("PRIVATE_OR_UNAVAILABLE", /敏感内容|年龄限制/.test(c.error.message || "") ? c.error.message : "\u672A\u80FD\u8BFB\u53D6\u5E16\u5B50\u5185\u5BB9\uFF08\u53EF\u80FD\u5305\u542B\u53D7\u9650\u5185\u5BB9\u6216\u5DF2\u88AB\u5220\u9664\uFF09") : c.error
    },
    tiktok: {
      expiresAt: (c) => tiktokExpiresAt(c.url),
      ready: () => tiktokReady(),
      navigate: (c) => {
        const id = extractTiktokPostId(c.url);
        return id ? { url: c.site.normalize.canonicalTemplate.replaceAll("{id}", id) } : { wait: true };
      },
      parse: (c) => parseTiktok(c.input || "", c.url)
    }
  };
  function moduleCall(moduleId, hook, context) {
    if (!Object.hasOwn(modules, moduleId)) throw new Error("UNSUPPORTED_MODULE");
    if (hook === "decorate") throw new Error("UNSUPPORTED_HOOK");
    if (hook === "classify" && context.error?.code === "PRIVATE_OR_UNAVAILABLE" && context.site.auth.mode !== "none" && !context.loggedIn && moduleId !== "x") {
      context = { ...context, error: failure2("LOGIN_REQUIRED", "\u53EF\u80FD\u9700\u8981\u767B\u5F55" + context.site.displayName) };
    }
    const module = modules[moduleId];
    const output = (value) => JSON.stringify({ value: hook === "parse" || hook === "parsePage" ? withMediaResources(module.decorate ? module.decorate(value) : value, context.site, (url) => module.expiresAt?.({ ...context, url })) : value });
    if (Object.hasOwn(module, hook)) return output(module[hook](context) ?? null);
    switch (hook) {
      case "install":
      case "navigate":
      case "account":
        return JSON.stringify({ value: null });
      case "prepare":
        return JSON.stringify({ value: false });
      case "ready":
        return JSON.stringify({ value: true });
      case "parsePage": {
        try {
          const result = JSON.parse(parsePageForModule(moduleId, context.site.download?.thumbnailScenes, context.site.download?.thumbnailVariant === "smallestCandidate"));
          if (result.ok) return output(result);
        } catch (_) {
        }
        return output(JSON.parse(parse(document.documentElement.outerHTML, context.url, moduleId, context.site.download?.thumbnailScenes, context.site.download?.thumbnailVariant === "smallestCandidate")));
      }
      case "parse":
        return output(JSON.parse(parse(context.input || "", context.url, moduleId, context.site.download?.thumbnailScenes, context.site.download?.thumbnailVariant === "smallestCandidate")));
      case "classify": {
        const error = context.error;
        return JSON.stringify({ value: error?.code === "PRIVATE_OR_UNAVAILABLE" && context.site.auth.mode !== "none" && !context.loggedIn ? failure2("LOGIN_REQUIRED", "\u53EF\u80FD\u9700\u8981\u767B\u5F55" + context.site.displayName) : error });
      }
      default:
        throw new Error("UNSUPPORTED_HOOK");
    }
  }

  // src/_parse_page.ts
  function noteIdFromUrl(url) {
    const m = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-f0-9]{24})/i.exec(url);
    return m ? m[1].toLowerCase() : void 0;
  }
  function shortcodeFromUrl(url) {
    const m = /\/(?:p|reels?|tv)\/([A-Za-z0-9-_]+)/.exec(url);
    return m ? m[1] : void 0;
  }
  function parseInstagramFromDom(doc, pageUrl) {
    const shortcodeMatch = /\/(?:p|reels?|tv)\/([A-Za-z0-9-_]+)/.exec(pageUrl);
    const shortcode = shortcodeMatch ? shortcodeMatch[1] : void 0;
    if (!shortcode) return void 0;
    const items = [];
    const seenUrls = /* @__PURE__ */ new Set();
    const videos = Array.from(doc.querySelectorAll("article video, main video, video"));
    for (const v of videos) {
      const videoEl = v;
      const videoSrc = videoEl.currentSrc || videoEl.src || videoEl.querySelector("source")?.getAttribute("src");
      if (videoSrc && !seenUrls.has(videoSrc)) {
        seenUrls.add(videoSrc);
        const poster = videoEl.poster || videoEl.getAttribute("poster") || "";
        items.push({
          type: "video",
          url: poster ? poster : videoSrc,
          videoUrl: videoSrc
        });
      }
    }
    const imgs = Array.from(doc.querySelectorAll("article img, main img"));
    for (const img of imgs) {
      const imgEl = img;
      const src = imgEl.currentSrc || imgEl.src;
      if (!src || src.startsWith("data:") || seenUrls.has(src)) continue;
      const rect = imgEl.getBoundingClientRect ? imgEl.getBoundingClientRect() : null;
      if (rect && (rect.width < 120 || rect.height < 120)) continue;
      if (items.some((it) => it.url === src)) continue;
      seenUrls.add(src);
      items.push({
        type: "image",
        url: src,
        width: rect?.width ? Math.round(rect.width) : void 0,
        height: rect?.height ? Math.round(rect.height) : void 0
      });
    }
    if (items.length === 0) {
      const ogVideo = doc.querySelector('meta[property="og:video"]')?.getAttribute("content");
      const ogImage = doc.querySelector('meta[property="og:image"]')?.getAttribute("content");
      if (ogVideo) {
        items.push({
          type: "video",
          url: ogImage || ogVideo,
          videoUrl: ogVideo
        });
      } else if (ogImage) {
        items.push({
          type: "image",
          url: ogImage
        });
      }
    }
    if (items.length === 0) return void 0;
    let caption = "";
    const captionEl = doc.querySelector('article h1, article span[dir="auto"], meta[property="og:title"]');
    if (captionEl) {
      caption = (captionEl.getAttribute("content") || captionEl.textContent || "").trim();
    }
    const authorName = doc.querySelector("article header a")?.textContent?.trim() || "";
    return {
      ok: true,
      data: {
        platform: "instagram",
        id: shortcode,
        url: `https://www.instagram.com/p/${shortcode}/`,
        author: { name: authorName },
        caption,
        items
      }
    };
  }
  function parsePage() {
    const url = window.location.href;
    const moduleId = isTiktokLink(url) ? "tiktok" : isXhsHost(url) ? "xhs" : isInstagramHost(url) ? "instagram" : isXHost(url) ? "x" : "";
    return parsePageForModule(moduleId);
  }
  function parsePageForModule(moduleId, thumbnailScenes = [], smallThumbnail = false) {
    const url = window.location.href;
    const html = document.documentElement.outerHTML;
    if (moduleId === "tiktok") {
      const result = parseTiktok(html, url);
      if (result.ok) return JSON.stringify(result);
      const state = window.__UNIVERSAL_DATA_FOR_REHYDRATION__;
      if (state && typeof state === "object") {
        return JSON.stringify(parseTiktok(JSON.stringify(state), url));
      }
      return JSON.stringify(result);
    }
    if (moduleId === "xhs") {
      const state = window.__INITIAL_STATE__;
      if (state !== void 0) {
        try {
          const wantedId = noteIdFromUrl(url);
          const note = findNoteInStates([state], wantedId);
          if (note) {
            const noteId = typeof note["noteId"] === "string" && note["noteId"].length > 0 ? note["noteId"] : wantedId ?? "";
            if (noteId) {
              return JSON.stringify(buildNoteFromRecord(note, noteId, url, thumbnailScenes));
            }
          }
        } catch (_) {
        }
      }
      return JSON.stringify(parseXhs(html, url, thumbnailScenes));
    }
    if (moduleId === "instagram") {
      const shortcode = shortcodeFromUrl(url);
      if (shortcode && window.__easysaveIgProducts?.[shortcode]) {
        return JSON.stringify(
          buildPostFromProduct(window.__easysaveIgProducts[shortcode], shortcode, smallThumbnail)
        );
      }
      const res = parseInstagram(html, url, smallThumbnail);
      if (res.ok) return JSON.stringify(res);
      const domRes = parseInstagramFromDom(document, url);
      if (domRes && domRes.ok) return JSON.stringify(domRes);
      return JSON.stringify(res);
    }
    if (moduleId === "x") {
      return JSON.stringify({
        ok: false,
        error: { code: "UNSUPPORTED_URL", message: "X posts require syndication JSON input to parse(input, pageUrl)" }
      });
    }
    return JSON.stringify({ ok: false, error: { code: "UNSUPPORTED_URL", message: `Unsupported host: ${url}` } });
  }
  function parse(input, pageUrl, moduleId, thumbnailScenes = [], smallThumbnail = false) {
    if (moduleId ? moduleId === "tiktok" : isTiktokLink(pageUrl)) return JSON.stringify(parseTiktok(input, pageUrl));
    const host = hostnameOf(pageUrl);
    if (!host) {
      return JSON.stringify({ ok: false, error: { code: "UNSUPPORTED_URL", message: `Cannot parse URL: ${pageUrl}` } });
    }
    if (moduleId ? moduleId === "xhs" : isXhsHost(host)) {
      return JSON.stringify(parseXhs(input, pageUrl, thumbnailScenes));
    }
    if (moduleId ? moduleId === "instagram" : isInstagramHost(host)) {
      return JSON.stringify(parseInstagram(input, pageUrl, smallThumbnail));
    }
    if (moduleId ? moduleId === "x" : isXHost(host)) {
      return JSON.stringify(parseX(input, pageUrl));
    }
    return JSON.stringify({ ok: false, error: { code: "UNSUPPORTED_URL", message: `Unsupported host: ${host}` } });
  }
  return __toCommonJS(parse_page_exports);
})();
