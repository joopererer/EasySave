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
    parse: () => parse,
    parseInstagram: () => parseInstagram,
    parsePage: () => parsePage,
    parseX: () => parseX,
    parseXhs: () => parseXhs
  });

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
  function tryParseJson(text) {
    try {
      return JSON.parse(text);
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
    if (!isRecord(stream)) return [];
    const out = [];
    for (const arr of Object.values(stream)) {
      if (Array.isArray(arr)) {
        for (const entry of arr) {
          if (isRecord(entry)) out.push(entry);
        }
      }
    }
    return out;
  }
  function candidateFromEntry(entry) {
    const type = entry["streamType"] ?? entry["stream_type"];
    const desc = entry["streamDesc"] ?? entry["stream_desc"];
    const watermarked = type === 259 || type === 309 || typeof desc === "string" && desc.toUpperCase() === "WEB_LIVEPHOTO_19";
    const urls = [
      entry["masterUrl"],
      entry["master_url"],
      ...Array.isArray(entry["backupUrls"]) ? entry["backupUrls"] : Array.isArray(entry["backup_urls"]) ? entry["backup_urls"] : [],
      entry["url"]
    ].filter(nonBlank);
    if (urls.length === 0) return void 0;
    const width = typeof entry["width"] === "number" ? entry["width"] : 0;
    const height = typeof entry["height"] === "number" ? entry["height"] : 0;
    return { url: toHttps(urls[0]), watermarked, width, height };
  }
  function collectStreamCandidates(container) {
    if (!isRecord(container)) return [];
    const streamObj = container["stream"] !== void 0 && isRecord(container) ? container["stream"] : container;
    return streamEntries(streamObj).map(candidateFromEntry).filter((c) => c !== void 0);
  }
  function resolveVideoUrl(video) {
    if (!isRecord(video)) return void 0;
    const key = (isRecord(video["consumer"]) ? pickString(video["consumer"], ["originVideoKey"]) : void 0) ?? pickString(video, ["originVideoKey"]);
    if (key) {
      if (/^https?:\/\//i.test(key)) return { url: toHttps(key) };
      return { url: `https://sns-video-bd.xhscdn.com/${key.replace(/^\/+/, "")}` };
    }
    const candidates = [];
    if (isRecord(video["media"])) {
      const media = video["media"];
      if (media["stream"] !== void 0) candidates.push(...collectStreamCandidates(media["stream"]));
    }
    if (video["stream"] !== void 0) candidates.push(...collectStreamCandidates(video["stream"]));
    if (typeof video["mediaV2"] === "string") {
      try {
        const parsed = JSON.parse(video["mediaV2"]);
        if (isRecord(parsed) && parsed["stream"] !== void 0) {
          candidates.push(...collectStreamCandidates(parsed["stream"]));
        }
      } catch {
      }
    }
    const best = bestVideo(candidates);
    if (!best) return void 0;
    const resolved = { url: best.url };
    if (best.width > 0) resolved.width = best.width;
    if (best.height > 0) resolved.height = best.height;
    return resolved;
  }
  function bestVideo(candidates) {
    return [...candidates].sort((a, b) => {
      if (a.watermarked !== b.watermarked) return a.watermarked ? 1 : -1;
      return b.width * b.height - a.width * a.height;
    })[0];
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
  function parseXhs(html, pageUrl) {
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
    const looksLikeXhs = /xiaohongshu\.com|xhslink/.test(pageUrl) || /xiaohongshu\.com|xhslink|__INITIAL_STATE__/.test(html.slice(0, 2e4));
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
    return buildNoteFromRecord(note, noteId, pageUrl);
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
  function buildNoteFromRecord(note, noteId, pageUrl) {
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
    const isVideoNote = noteType === "video" || noteType === "" && hasMainVideo && images.length <= 1 && !firstHasStream;
    const items = [];
    if (isVideoNote) {
      const resolved = resolveVideoUrl(note["video"]);
      if (resolved) {
        const item = { type: "video", url: resolved.url };
        const cover = images.length > 0 ? imageUrlOf(images[0]) : void 0;
        if (cover) item.posterUrl = cover.url;
        if (resolved.width !== void 0) item.width = resolved.width;
        if (resolved.height !== void 0) item.height = resolved.height;
        const duration = videoDuration(note["video"]);
        if (duration !== void 0) item.duration = duration;
        items.push(item);
      } else if (images.length === 1) {
        const img = imageUrlOf(images[0]);
        if (img) {
          const item = { type: "image", url: img.url, fallbacks: img.fallbacks };
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
        const own = entryKeyUrl ? { url: entryKeyUrl, watermarked: false, width: 0, height: 0 } : bestVideo(ownCandidates);
        if (own && img) {
          const item = { type: "live", url: img.url, videoUrl: own.url, fallbacks: img.fallbacks };
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
    if (nonBlank(note["title"])) data.title = note["title"];
    const caption = pickString(note, ["desc", "description"]);
    if (caption !== void 0) data.caption = caption;
    if (typeof note["time"] === "number" && Number.isFinite(note["time"])) {
      data.publishedAt = toIsoUtc(note["time"]);
    }
    return { ok: true, data };
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
    const matchesId = String(obj["id"] ?? "") === mediaId || String(obj["pk"] ?? "") === mediaId;
    if (!matchesId) return false;
    return "video_versions" in obj || "carousel_media" in obj || "image_versions2" in obj;
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
    if (nonBlank2(media["display_url"])) return { url: media["display_url"], width: 0, height: 0 };
    return void 0;
  }
  function bestVideoUrl(media) {
    return bestRendition(media["video_versions"]);
  }
  function mediaItem(media) {
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
  function parseInstagram(html, pageUrl) {
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
    return buildPostFromProduct(product, shortcode);
  }
  function buildPostFromProduct(product, shortcode) {
    const user = isRecord2(product["user"]) ? product["user"] : isRecord2(product["owner"]) ? product["owner"] : {};
    const author = {};
    if (nonBlank2(user["username"])) author.name = user["username"];
    const authorId = user["pk"] ?? user["id"];
    if (authorId !== void 0 && authorId !== null && String(authorId).length > 0) {
      author.id = String(authorId);
    }
    const captionRaw = product["caption"];
    const caption = typeof captionRaw === "string" ? captionRaw : isRecord2(captionRaw) && typeof captionRaw["text"] === "string" ? captionRaw["text"] : "";
    const takenAt = product["taken_at"];
    const publishedAt = typeof takenAt === "number" && Number.isFinite(takenAt) ? toIsoUtcSeconds(takenAt) : "";
    const items = [];
    const carousel = product["carousel_media"];
    if (Array.isArray(carousel)) {
      for (const child of carousel) {
        if (!isRecord2(child)) continue;
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
    return { ok: true, data };
  }

  // src/x.ts
  var TWEET_ID_PATTERN = /(?:x|twitter)\.com\/(?:[^/]+)\/status\/(\d+)/i;
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
      if (trimmed.length === 0) {
        return {
          ok: false,
          error: {
            code: "PRIVATE_OR_UNAVAILABLE",
            message: "This post is private, deleted, or unavailable."
          }
        };
      }
      try {
        root = JSON.parse(trimmed);
      } catch {
        return {
          ok: false,
          error: {
            code: "PRIVATE_OR_UNAVAILABLE",
            message: "This post is private, deleted, or unavailable."
          }
        };
      }
    } else {
      root = input;
    }
    if (!isRecord3(root) || Object.keys(root).length === 0) {
      return {
        ok: false,
        error: {
          code: "PRIVATE_OR_UNAVAILABLE",
          message: "This post is private, deleted, or unavailable."
        }
      };
    }
    if (root["__typename"] === "TweetTombstone") {
      const tombstone = root["tombstone"];
      const textObj = isRecord3(tombstone) ? tombstone["text"] : void 0;
      const tombstoneText = isRecord3(textObj) && typeof textObj["text"] === "string" ? textObj["text"].toLowerCase() : "";
      if (tombstoneText.includes("limit") || tombstoneText.includes("view") || tombstoneText.includes("age") || tombstoneText.includes("sensitive") || tombstoneText.includes("login")) {
        return {
          ok: false,
          error: {
            code: "LOGIN_REQUIRED",
            message: "This post requires authentication or has viewer restrictions."
          }
        };
      }
      return {
        ok: false,
        error: {
          code: "PRIVATE_OR_UNAVAILABLE",
          message: "This post is private, deleted, or unavailable."
        }
      };
    }
    if (Array.isArray(root["errors"]) && root["errors"].length > 0) {
      return {
        ok: false,
        error: {
          code: "PRIVATE_OR_UNAVAILABLE",
          message: "This post is private, deleted, or unavailable."
        }
      };
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
    return /xiaohongshu\.com|xhslink\.com|xhslink\.cn|xhs\.cn/.test(host);
  }
  function isInstagramHost(host) {
    return /instagram\.com|instagr\.am/.test(host);
  }
  function isXHost(host) {
    return /x\.com|twitter\.com/.test(host);
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
  function parsePage() {
    const url = window.location.href;
    const html = document.documentElement.outerHTML;
    if (isXhsHost(url)) {
      const state = window.__INITIAL_STATE__;
      if (state !== void 0) {
        try {
          const wantedId = noteIdFromUrl(url);
          const note = findNoteInStates([state], wantedId);
          if (note) {
            const noteId = typeof note["noteId"] === "string" && note["noteId"].length > 0 ? note["noteId"] : wantedId ?? "";
            if (noteId) {
              return JSON.stringify(buildNoteFromRecord(note, noteId, url));
            }
          }
        } catch (_) {
        }
      }
      return JSON.stringify(parseXhs(html, url));
    }
    if (isInstagramHost(url)) {
      const shortcode = shortcodeFromUrl(url);
      if (shortcode && window.__easysaveIgProducts?.[shortcode]) {
        return JSON.stringify(
          buildPostFromProduct(window.__easysaveIgProducts[shortcode], shortcode)
        );
      }
      return JSON.stringify(parseInstagram(html, url));
    }
    if (isXHost(url)) {
      return JSON.stringify({
        ok: false,
        error: { code: "UNSUPPORTED_URL", message: "X posts require syndication JSON input to parse(input, pageUrl)" }
      });
    }
    return JSON.stringify({ ok: false, error: { code: "UNSUPPORTED_URL", message: `Unsupported host: ${url}` } });
  }
  function parse(input, pageUrl) {
    const host = hostnameOf(pageUrl);
    if (!host) {
      return JSON.stringify({ ok: false, error: { code: "UNSUPPORTED_URL", message: `Cannot parse URL: ${pageUrl}` } });
    }
    if (isXhsHost(host)) {
      return JSON.stringify(parseXhs(input, pageUrl));
    }
    if (isInstagramHost(host)) {
      return JSON.stringify(parseInstagram(input, pageUrl));
    }
    if (isXHost(host)) {
      return JSON.stringify(parseX(input, pageUrl));
    }
    return JSON.stringify({ ok: false, error: { code: "UNSUPPORTED_URL", message: `Unsupported host: ${host}` } });
  }
  return __toCommonJS(parse_page_exports);
})();
