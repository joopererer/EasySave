import { readdirSync, readFileSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  parseXhs,
  sanitizeJsUndefined,
  imageTokenOf,
  originalImageUrl,
  jpegImageUrl,
  findNoteInStates,
  buildNoteFromRecord,
} from "../src/xhs";

const fixtureDir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "spec", "fixtures", "xhs");

const cases = readdirSync(fixtureDir)
  .filter((name) => name.endsWith(".html"))
  .map((name) => basename(name, ".html"))
  .filter((name) => {
    try {
      readFileSync(join(fixtureDir, `${name}.expected.json`), "utf-8");
      return true;
    } catch {
      return false;
    }
  })
  .sort();

describe("xhs fixtures", () => {
  if (cases.length === 0) {
    it("has fixtures to test", () => {
      expect(cases.length).toBeGreaterThan(0);
    });
  }
  for (const name of cases) {
    it(`${name}.html matches ${name}.expected.json`, () => {
      const html = readFileSync(join(fixtureDir, `${name}.html`), "utf-8");
      const expected = JSON.parse(readFileSync(join(fixtureDir, `${name}.expected.json`), "utf-8")) as
        | { error: { code: string; message: string } }
        | Record<string, unknown>;
      const id = typeof (expected as Record<string, unknown>)["id"] === "string"
        ? ((expected as Record<string, unknown>)["id"] as string)
        : name;
      const result = parseXhs(html, `https://www.xiaohongshu.com/explore/${id}`);

      if ("error" in expected) {
        expect(result.ok).toBe(false);
        if (!result.ok) {
          expect(result.error.code).toBe((expected as { error: { code: string } }).error.code);
        }
      } else {
        expect(result).toEqual({ ok: true, data: expected });
      }
    });
  }
});

describe("original-bucket primary", () => {
  const token = "notes_pre_post/1040g3k0325c98ukf4e00499d8a6r31c1c4anqs0";
  const h5 = `http://sns-webpic-qc.xhscdn.com/202610132252/fccfbed52a062a916648e7d56c157af7/${token}!h5_1080jpg`;

  it("strips the style suffix from any CDN URL", () => {
    expect(imageTokenOf(h5)).toBe(token);
    expect(imageTokenOf(`https://ci.xiaohongshu.com/${token}`)).toBe(token);
    expect(imageTokenOf("https://example.com/a.jpg")).toBeUndefined();
  });

  it("builds original and JPEG URLs from the token", () => {
    expect(originalImageUrl(token)).toBe(`https://sns-img-bd.xhscdn.com/${token}`);
    expect(jpegImageUrl(token)).toBe(
      `https://ci.xiaohongshu.com/${token}?imageView2/format/jpg`,
    );
  });
});

describe("sanitizeJsUndefined", () => {
  it("replaces undefined outside strings but keeps it inside strings", () => {
    expect(sanitizeJsUndefined('{"a":undefined,"b":"say undefined loudly"}')).toBe(
      '{"a":null,"b":"say undefined loudly"}',
    );
    expect(sanitizeJsUndefined('{"a":null}')).toBe('{"a":null}');
    expect(sanitizeJsUndefined('[undefined,null,"undefined"]')).toBe('[null,null,"undefined"]');
  });

  it("parses state containing JS undefined without touching string content", () => {
    const id = "6aca089a000000000a01efb4";
    const html =
      `<html><head><script>window.__INITIAL_STATE__={"global":{"x":undefined},` +
      `"note":{"noteDetailMap":{"${id}":{"note":{"noteId":"${id}",` +
      `"title":"say undefined loudly","desc":"d","time":1791625370000,` +
      `"user":{"nickname":"momo","userId":"604e0d4800000000010065ec"},` +
      `"imageList":[{"urlDefault":"http://sns-webpic-qc.xhscdn.com/202610112129/eb1fb79a62c72f9dbe14dd2909e2d83c/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208!nd_dft_wlteh_webp_3","width":1290,"height":1608}]}}}}` +
      `</script></head></html>`;
    const result = parseXhs(html, `https://www.xiaohongshu.com/explore/${id}`);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data.title).toBe("say undefined loudly");
      expect(result.data.items).toEqual([
        {
          type: "image",
          url: "https://sns-img-bd.xhscdn.com/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208",
          width: 1290,
          height: 1608,
          fallbacks: [
            "https://ci.xiaohongshu.com/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208?imageView2/format/jpg",
            "https://sns-webpic-qc.xhscdn.com/202610112129/eb1fb79a62c72f9dbe14dd2909e2d83c/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208!nd_dft_wlteh_webp_3",
            "https://ci.xiaohongshu.com/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208",
          ],
        },
      ]);
    }
  });

  it("findNoteInStates and buildNoteFromRecord parse decoded INITIAL_STATE JSON directly", () => {
    const id = "6aca089a000000000a01efb4";
    const state = {
      note: {
        noteDetailMap: {
          [id]: {
            note: {
              noteId: id,
              title: "t",
              desc: "d",
              time: 1791625370000,
              user: { nickname: "momo", userId: "604e0d4800000000010065ec" },
              imageList: [
                {
                  urlDefault: "https://sns-img-bd.xhscdn.com/trace",
                  width: 10,
                  height: 20,
                },
              ],
            },
          },
        },
      },
    };
    const note = findNoteInStates([state], id)!;
    const result = buildNoteFromRecord(note, id);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data).toEqual({
        platform: "xhs",
        id: id,
        url: `https://www.xiaohongshu.com/explore/${id}`,
        author: { name: "momo", id: "604e0d4800000000010065ec" },
        title: "t",
        caption: "d",
        publishedAt: "2026-10-10T09:42:50Z",
        items: [
          {
            type: "image",
            url: "https://sns-img-bd.xhscdn.com/trace",
            width: 10,
            height: 20,
            fallbacks: [
              "https://ci.xiaohongshu.com/trace?imageView2/format/jpg",
              "https://ci.xiaohongshu.com/trace",
            ],
          },
        ],
      });
    }
  });
});

describe("video duration", () => {
  const id = "6aca089a000000000a01efb4";
  it("xhs reads duration from video.capa", () => {
    const state = {
      note: {
        noteDetailMap: {
          [id]: {
            note: {
              noteId: id,
              type: "video",
              title: "t",
              desc: "d",
              time: 1791625370000,
              user: { nickname: "momo", userId: "604e0d4800000000010065ec" },
              imageList: [],
              video: {
                consumer: { originVideoKey: "https://example.com/v.mp4" },
                capa: { duration: 14 },
              },
            },
          },
        },
      },
    };
    const note = findNoteInStates([state], id)!;
    const result = buildNoteFromRecord(note, id);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data.items[0].duration).toBe(14);
    }
  });

  it("xhs omits duration without capa", () => {
    const state = {
      note: {
        noteDetailMap: {
          [id]: {
            note: {
              noteId: id,
              type: "video",
              title: "t",
              desc: "d",
              time: 1791625370000,
              user: { nickname: "momo", userId: "604e0d4800000000010065ec" },
              imageList: [],
              video: {
                consumer: { originVideoKey: "https://example.com/v.mp4" },
              },
            },
          },
        },
      },
    };
    const note = findNoteInStates([state], id)!;
    const result = buildNoteFromRecord(note, id);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect("duration" in result.data.items[0]).toBe(false);
    }
  });
});

describe("type=video carousel", () => {
  const id = "6adc49970000000033020539";
  const imageEntry = (n: number) => ({
    urlDefault: `https://sns-img-bd.xhscdn.com/img${n}`,
    width: 1080,
    height: 1440,
  });

  it("keeps every imageList entry when a video-typed note has several images", () => {
    const result = buildNoteFromRecord(
      {
        noteId: id,
        type: "video",
        title: "t",
        user: { nickname: "momo", userId: "u1" },
        imageList: [imageEntry(1), imageEntry(2), imageEntry(3)],
        video: { consumer: { originVideoKey: "https://example.com/v.mp4" } },
      },
      id,
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      const images = result.data.items.filter((i) => i.type === "image");
      expect(images).toHaveLength(3);
    }
  });

  it("still treats a single-cover video note as one video", () => {
    const result = buildNoteFromRecord(
      {
        noteId: id,
        type: "video",
        title: "t",
        user: { nickname: "momo", userId: "u1" },
        imageList: [imageEntry(1)],
        video: { consumer: { originVideoKey: "https://example.com/v.mp4" } },
      },
      id,
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data.items).toHaveLength(1);
      expect(result.data.items[0].type).toBe("video");
    }
  });
});

describe("imageUrlOf fallbacks", () => {
  const id = "6aca089a000000000a01efb4";
  const noteWith = (images: Array<Record<string, unknown>>) => ({
    noteId: id,
    title: "t",
    user: { nickname: "momo" },
    imageList: images,
  });

  it("prefers the infoList token as original-bucket URL", () => {
    const result = buildNoteFromRecord(
      noteWith([
        {
          width: 100,
          height: 200,
          infoList: [
            {
              imageScene: "WB_PRV",
              url: "http://sns-webpic-qc.xhscdn.com/202610112129/a657f0bce4b0d577975cf2d1df487c06/notes_pre_post/x!nd_prv_wlteh_webp_3",
            },
            {
              imageScene: "WB_DFT",
              url: "http://sns-webpic-qc.xhscdn.com/202610112129/eb1fb79a62c72f9dbe14dd2909e2d83c/notes_pre_post/x!nd_dft_wlteh_webp_3",
            },
          ],
        },
      ]),
      id,
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data.items[0].url).toBe("https://sns-img-bd.xhscdn.com/notes_pre_post/x");
      expect(result.data.items[0].fallbacks).toEqual([
        "https://ci.xiaohongshu.com/notes_pre_post/x?imageView2/format/jpg",
        "https://sns-webpic-qc.xhscdn.com/202610112129/a657f0bce4b0d577975cf2d1df487c06/notes_pre_post/x!nd_prv_wlteh_webp_3",
        "https://sns-webpic-qc.xhscdn.com/202610112129/eb1fb79a62c72f9dbe14dd2909e2d83c/notes_pre_post/x!nd_dft_wlteh_webp_3",
        "https://ci.xiaohongshu.com/notes_pre_post/x",
      ]);
    }
  });

  it("resolves a lone infoList rendition to the original bucket", () => {
    const result = buildNoteFromRecord(
      noteWith([
        {
          width: 100,
          height: 200,
          infoList: [
            {
              imageScene: "WB_PRV",
              url: "http://sns-webpic-qc.xhscdn.com/202610112129/a657f0bce4b0d577975cf2d1df487c06/notes_pre_post/y!nd_prv_wlteh_webp_3",
            },
          ],
        },
      ]),
      id,
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data.items[0].url).toBe("https://sns-img-bd.xhscdn.com/notes_pre_post/y");
    }
  });

  it("falls back to fileId for the original bucket", () => {
    const result = buildNoteFromRecord(
      noteWith([
        {
          width: 100,
          height: 200,
          fileId: "notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208",
          traceId: "sometrace",
        },
      ]),
      id,
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data.items[0].url).toBe(
        "https://sns-img-bd.xhscdn.com/notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208",
      );
    }
  });

  it("serves the bare token URL with JPEG transcode first fallback", () => {
    const token = "notes_pre_post/1040g3k0325c98ukf4e00499d8a6r31c1c4anqs0";
    const h5 = `http://sns-webpic-qc.xhscdn.com/202610132252/fccfbed52a062a916648e7d56c157af7/${token}!h5_1080jpg`;
    const result = buildNoteFromRecord(
      noteWith([
        {
          width: 1290,
          height: 1608,
          urlDefault: h5,
          fileId: token,
          infoList: [
            { imageScene: "H5_DTL", url: h5 },
            {
              imageScene: "H5_PRV",
              url: h5.replace("h5_1080jpg", "style_d4c824bab532bfe9"),
            },
          ],
        },
      ]),
      id,
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data.items[0].url).toBe(`https://sns-img-bd.xhscdn.com/${token}`);
      const fallbacks = result.data.items[0].fallbacks ?? [];
      expect(fallbacks[0]).toBe(`https://ci.xiaohongshu.com/${token}?imageView2/format/jpg`);
      expect(fallbacks).toContain(`https://ci.xiaohongshu.com/${token}`);
    }
  });

  it("falls back to fileId token when no URL is present", () => {
    const result = buildNoteFromRecord(
      noteWith([
        { width: 100, height: 200, fileId: "notes_pre_post/x" },
      ]),
      id,
    );
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data.items[0].url).toBe("https://sns-img-bd.xhscdn.com/notes_pre_post/x");
    }
  });
});

