import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { parseInstagram, probeInstagramAiFields } from "../src/instagram";

describe("Instagram share URL fixtures", () => {
  for (const fixture of ["ig_reel", "ig_carousel"]) {
    const base = fileURLToPath(new URL(`../../spec/fixtures/instagram/${fixture}`, import.meta.url));
    const html = readFileSync(`${base}.html`, "utf8");
    const expected = JSON.parse(readFileSync(`${base}.expected.json`, "utf8"));
    for (const route of ["reel", "p"]) {
      for (const query of ["dlrf=123456", "vrfl=1", "dlrf=123456&vrfl=1"]) {
        it(`${fixture}: /${route}/ with ${query} preserves the same post`, () => {
          expect(parseInstagram(html, `https://www.instagram.com/${route}/${expected.id}/?${query}`))
            .toEqual({ ok: true, data: expected });
        });
      }
    }
  }
});

describe("Instagram AI diagnostic field probe", () => {
  const decode = (product: Record<string, unknown>) =>
    probeInstagramAiFields(product).map(line => JSON.parse(line));

  it("reports matching field paths, names and safe scalar values, including carousel children", () => {
    expect(decode({
      is_ai: true,
      gen_ai: 2,
      genai: "AI_GENERATED",
      label: "VISIBLE",
      disclosure: false,
      c2pa: null,
      carousel_media: [{ ai_label: "PLATFORM" }],
      unrelated: "PRIVATE_CAPTION",
    })).toEqual(expect.arrayContaining([
      { path: "$.is_ai", name: "is_ai", type: "boolean", value: true },
      { path: "$.gen_ai", name: "gen_ai", type: "number", value: 2 },
      { path: "$.genai", name: "genai", type: "string", value: "AI_GENERATED" },
      { path: "$.label", name: "label", type: "string", value: "VISIBLE" },
      { path: "$.disclosure", name: "disclosure", type: "boolean", value: false },
      { path: "$.c2pa", name: "c2pa", type: "null" },
      { path: "$.carousel_media[0].ai_label", name: "ai_label", type: "string", value: "PLATFORM" },
    ]));
  });

  it("records only types for prose, URLs, long strings, objects and arrays", () => {
    const result = decode({
      ai_caption: "PRIVATE prose",
      disclosure_url: "https://private.example/?token=PRIVATE",
      label_long: "x".repeat(41),
      label_cookie: "PRIVATE_COOKIE",
      c2pa_token: "PRIVATE_TOKEN",
      ai_session: "PRIVATE_SESSION",
      gen_ai: { enabled: true },
      c2pa: ["PRIVATE"],
    });
    expect(result).toEqual(expect.arrayContaining([
      { path: "$.ai_caption", name: "ai_caption", type: "string" },
      { path: "$.disclosure_url", name: "disclosure_url", type: "string" },
      { path: "$.label_long", name: "label_long", type: "string" },
      { path: "$.label_cookie", name: "label_cookie", type: "string" },
      { path: "$.c2pa_token", name: "c2pa_token", type: "string" },
      { path: "$.ai_session", name: "ai_session", type: "string" },
      { path: "$.gen_ai", name: "gen_ai", type: "object" },
      { path: "$.c2pa", name: "c2pa", type: "array" },
    ]));
    expect(JSON.stringify(result)).not.toContain("PRIVATE");
  });

  it("does not expose user information or unsafe dynamic field names", () => {
    const result = probeInstagramAiFields({
      user: { ai_label: "PRIVATE_ACCOUNT" },
      owner: { disclosure: "PRIVATE_OWNER" },
      "ai_https://private.example/user": "PRIVATE_DYNAMIC",
      caption: "PRIVATE_CAPTION",
      username: "PRIVATE_USERNAME",
    });
    const output = result.join("\n");
    expect(output).not.toMatch(/PRIVATE|https:\/\//);
    expect(decode({ AI_LABEL: true })).toEqual([
      { path: "$.AI_LABEL", name: "AI_LABEL", type: "boolean", value: true },
    ]);
  });

  it("tolerates cycles and excludes non-finite numeric values", () => {
    const product: Record<string, unknown> = { ai_score: Infinity };
    product.self = product;
    expect(decode(product)).toContainEqual({ path: "$.ai_score", name: "ai_score", type: "number" });
  });
});
