import { describe, expect, it } from "vitest";
import {
  buildNoteFromRecord,
  xhsImageDownloadOrder,
  xhsMediaKindOf,
  type XhsItem,
} from "../src/xhs";

// v1.10.1: a Xiaohongshu Live photo's motion clip must never come from an
// image URL. The still sits in the same entry as the clip, and its original
// rendition is a HEIC — which used to be downloaded as an unplayable .mp4.

const STILL_TOKEN = "notes_pre_post/1040g3k8liveheicstill0001";
const STILL_ORIGINAL = `https://sns-img-bd.xhscdn.com/${STILL_TOKEN}`;
const CLIP = "https://sns-video-v27.xhscdn.com/stream/1/10/19/01ea342f872f66af010050039edbdaf681_19.mp4?sign=ef06&t=6ad0";
const BACKUP_CLIP = "https://sns-bak-v11.xhscdn.com/stream/1/10/19/01ea342f872f66af010050039edbdaf681_19.mp4";

function stillEntry(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    width: 3024,
    height: 4032,
    livePhoto: true,
    url: "",
    urlDefault: `http://sns-webpic-qc.xhscdn.com/202611092130/c31b90ae/${STILL_TOKEN}!nd_dft_wlteh_webp_3`,
    urlPre: "",
    traceId: STILL_TOKEN,
    fileId: STILL_TOKEN,
    infoList: [
      { imageScene: "WB_PRV", url: `http://sns-webpic-qc.xhscdn.com/202611092130/c31b90ae/${STILL_TOKEN}!nd_prv_wlteh_webp_3` },
      { imageScene: "WB_DFT", url: `http://sns-webpic-qc.xhscdn.com/202611092130/c31b90ae/${STILL_TOKEN}!nd_dft_wlteh_webp_3` },
    ],
    ...extra,
  };
}

function noteWith(images: Record<string, unknown>[], video?: Record<string, unknown>) {
  return {
    noteId: "6ae9d62b000000000f026e9d",
    type: "normal",
    title: "live",
    desc: "d",
    imageList: images,
    ...(video ? { video } : {}),
  };
}

function items(images: Record<string, unknown>[]): XhsItem[] {
  const result = buildNoteFromRecord(
    noteWith(images),
    "6ae9d62b000000000f026e9d",
    "https://www.xiaohongshu.com/explore/6ae9d62b000000000f026e9d",
  );
  if (!result.ok) throw new Error(`parse failed: ${result.error.code}`);
  return result.data.items;
}

describe("xhsMediaKindOf", () => {
  it("separates still renditions from motion clips", () => {
    expect(xhsMediaKindOf(STILL_ORIGINAL)).toBe("image");
    expect(xhsMediaKindOf(`https://ci.xiaohongshu.com/${STILL_TOKEN}?imageView2/format/jpg`)).toBe("image");
    expect(xhsMediaKindOf(`https://ci.xiaohongshu.com/${STILL_TOKEN}`)).toBe("image");
    expect(xhsMediaKindOf(`https://sns-webpic-qc.xhscdn.com/2026/a/${STILL_TOKEN}!nd_dft_wlteh_webp_3`)).toBe("image");
    expect(xhsMediaKindOf("https://sns-img-qc.xhscdn.com/abc.heic")).toBe("image");
    expect(xhsMediaKindOf(CLIP)).toBe("video");
    expect(xhsMediaKindOf(BACKUP_CLIP)).toBe("video");
    expect(xhsMediaKindOf("https://cdn.example.com/a.mp4")).toBe("video");
    expect(xhsMediaKindOf("https://cdn.example.com/object")).toBeUndefined();
    expect(xhsMediaKindOf("not a url")).toBeUndefined();
  });
});

describe("Live photo motion clip candidates", () => {
  it("keeps the clip when the stream also carries the HEIC still", () => {
    const [item] = items([
      stillEntry({
        stream: {
          EF4: [{ masterUrl: CLIP, backupUrls: [BACKUP_CLIP] }],
          // The still's own rendition, with the size that used to win the
          // pixel-area ranking.
          EF7: [{ masterUrl: `${STILL_ORIGINAL}/origin.heic`, width: 3024, height: 4032 }],
        },
      }),
    ]);
    expect(item.type).toBe("live");
    expect(item.videoUrl).toBe(CLIP);
    expect(item.url.startsWith("https://sns-img-bd.xhscdn.com/")).toBe(true);
    expect(item.url).toContain(STILL_TOKEN);
    for (const url of item.fallbacks ?? []) {
      expect(xhsMediaKindOf(url)).not.toBe("video");
    }
  });

  it("ignores a still carried in a stream entry's own `url`", () => {
    const [item] = items([
      stillEntry({
        stream: {
          EF4: [
            { url: `${STILL_ORIGINAL}/origin.heic`, width: 3024, height: 4032 },
            { masterUrl: CLIP },
          ],
        },
      }),
    ]);
    expect(item.type).toBe("live");
    expect(item.videoUrl).toBe(CLIP);
  });

  it("ignores a still inside livePhoto.stream", () => {
    const [item] = items([
      stillEntry({
        stream: { EF4: [{ masterUrl: CLIP }] },
        livePhoto: { stream: { EF4: [{ masterUrl: `${STILL_ORIGINAL}/origin.heic` }] } },
      }),
    ]);
    expect(item.type).toBe("live");
    expect(item.videoUrl).toBe(CLIP);
  });

  it("ignores an originVideoKey that names the still", () => {
    const [item] = items([
      stillEntry({
        originVideoKey: `${STILL_ORIGINAL}/origin.heic`,
        stream: { EF4: [{ masterUrl: CLIP }] },
      }),
    ]);
    expect(item.type).toBe("live");
    expect(item.videoUrl).toBe(CLIP);
  });

  it("drops an image-only originVideoKey when no clip exists", () => {
    const [item] = items([
      stillEntry({ originVideoKey: `${STILL_ORIGINAL}/origin.heic` }),
    ]);
    // No motion clip left: the entry is a plain image, never a "live" item
    // whose video slot holds the still.
    expect(item.type).toBe("image");
    expect(item.videoUrl).toBeUndefined();
    expect(item.url.startsWith("https://sns-img-bd.xhscdn.com/")).toBe(true);
    expect(item.url).toContain(STILL_TOKEN);
  });

  it("keeps a live entry whose stream holds only the clip", () => {
    const [item] = items([stillEntry({ stream: { EF4: [{ masterUrl: CLIP }] } })]);
    expect(item.type).toBe("live");
    expect(item.videoUrl).toBe(CLIP);
  });
});

describe("note-level video candidates", () => {
  it("ignores a still in the note video stream", () => {
    const result = buildNoteFromRecord(
      {
        noteId: "6ae9d62b000000000f026e9d",
        type: "video",
        desc: "d",
        imageList: [{ width: 1080, height: 1920, urlDefault: `http://sns-webpic-qc.xhscdn.com/2026/a/${STILL_TOKEN}!nd_dft_wlteh_webp_3` }],
        video: {
          media: {
            stream: {
              h264: [{ masterUrl: CLIP, backupUrls: [BACKUP_CLIP] }],
              image: [{ masterUrl: `${STILL_ORIGINAL}/poster.heic`, width: 3024, height: 4032 }],
            },
          },
        },
      },
      "6ae9d62b000000000f026e9d",
      "https://www.xiaohongshu.com/explore/6ae9d62b000000000f026e9d",
    );
    if (!result.ok) throw new Error(`parse failed: ${result.error.code}`);
    const [item] = result.data.items;
    expect(item.type).toBe("video");
    expect(item.url).toBe(CLIP);
    for (const url of item.fallbacks ?? []) {
      expect(xhsMediaKindOf(url)).not.toBe("image");
    }
  });
});

describe("image download order", () => {
  it("never ranks a motion clip as a still candidate", () => {
    const order = xhsImageDownloadOrder(STILL_ORIGINAL, [
      CLIP,
      `https://ci.xiaohongshu.com/${STILL_TOKEN}?imageView2/format/jpg`,
      BACKUP_CLIP,
    ]);
    expect(order).not.toContain(CLIP);
    expect(order).not.toContain(BACKUP_CLIP);
    expect(order[0]).toBe(`https://ci.xiaohongshu.com/${STILL_TOKEN}?imageView2/format/jpg`);
    for (const url of order) expect(xhsMediaKindOf(url)).not.toBe("video");
  });
});
