import { readdirSync, readFileSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { parseXhs, sanitizeJsUndefined, imageTokenOf, originalImageUrl, jpegImageUrl } from "../src/xhs";

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
        },
      ]);
    }
  });
});
