import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { buildPostFromProduct, parseInstagram, probeInstagramAiFields } from "../src/instagram";

const fixture = (name: string): Record<string, unknown> => JSON.parse(readFileSync(
  new URL(`../../spec/fixtures/instagram/${name}_v149.json`, import.meta.url), "utf8"));

describe("Instagram post-level AI attribution", () => {
  for (const [name, label] of [
    ["ig_ai_platform", { text: "Made with AI", source: "platform" }],
    ["ig_ai_null", undefined],
    ["ig_ai_account_only", undefined],
  ] as const) {
    it(`${name}: cached product and HTML parser agree on post attribution`, () => {
      const product = fixture(name);
      const code = String(product.code);
      const cached = buildPostFromProduct(product, code, true);
      const html = `<script data-sjs>${JSON.stringify({ product })}</script>`;
      const parsed = parseInstagram(html, `https://www.instagram.com/p/${code}/`);
      expect(cached.ok).toBe(true);
      expect(parsed.ok).toBe(true);
      if (!cached.ok || !parsed.ok) throw new Error("fixture did not parse");
      expect((cached.data as unknown as Record<string, unknown>).aiLabel).toEqual(label);
      expect((parsed.data as unknown as Record<string, unknown>).aiLabel).toEqual(label);
      expect(cached.data.items).toHaveLength(1);
    });
  }

  it("preserves the exact nonblank platform label without deriving the source from method", () => {
    const product = fixture("ig_ai_platform");
    product.ai_label_info = { attribution_label_text: "  使用 AI 制作  ", method: "PLATFORM_DETECTED" };
    expect(buildPostFromProduct(product, String(product.code))).toMatchObject({
      ok: true, data: { aiLabel: { text: "  使用 AI 制作  ", source: "platform" } },
    });
  });

  for (const value of ["", " \t\n", null, 1, true, {}, []]) {
    it(`does not label an invalid attribution value ${JSON.stringify(value)}`, () => {
      const product = fixture("ig_ai_platform");
      product.ai_label_info = { attribution_label_text: value };
      const result = buildPostFromProduct(product, String(product.code));
      expect(result.ok).toBe(true);
      if (!result.ok) throw new Error("fixture did not parse");
      expect(result.data).not.toHaveProperty("aiLabel");
    });
  }
});

describe("Instagram root platform-label diagnostics", () => {
  const decode = (product: unknown) => probeInstagramAiFields(product).map(line => JSON.parse(line));

  it("records platform wording and every root info field including discriminator enums", () => {
    expect(decode(fixture("ig_ai_platform"))).toEqual(expect.arrayContaining([
      { path: "$.ai_label_info.attribution_label_text", name: "attribution_label_text", type: "string", value: "Made with AI" },
      { path: "$.ai_label_info.method", name: "method", type: "string", value: "AUTHOR_DISCLOSURE" },
      { path: "$.ai_label_info.confidence", name: "confidence", type: "number", value: 0.98 },
      { path: "$.ai_label_info.enabled", name: "enabled", type: "boolean", value: true },
    ]));
  });

  it("filters controls and limits the authorised platform wording to 60 characters", () => {
    const text = "AI\u0000\n\u007f\u0085 " + "生".repeat(80);
    const records = decode({ ai_label_info: { attribution_label_text: text } });
    const label = records.find(record => record.path === "$.ai_label_info.attribution_label_text");
    expect(label.value).toBe("AI " + "生".repeat(57));
    expect(Array.from(label.value).length).toBe(60);
  });

  it("keeps account labels, URL values, query values and private descendants out of logs", () => {
    const output = decode({
      ai_label_info: {
        method: "PLATFORM_DETECTED",
        disclosure_url: "https://private.example/?token=PRIVATE_URL",
        account: { label: "PRIVATE_ACCOUNT" },
        debug: "PRIVATE prose must remain type only",
      },
      user: { aigm_account_label_info: { attribution_label_text: "PRIVATE_ACCOUNT_LABEL" } },
    });
    expect(output).toContainEqual({ path: "$.ai_label_info.method", name: "method", type: "string", value: "PLATFORM_DETECTED" });
    expect(output).toContainEqual({ path: "$.ai_label_info.debug", name: "debug", type: "string" });
    expect(JSON.stringify(output)).not.toMatch(/PRIVATE|https:\/\//);
  });

  for (const text of ["https://private.invalid/?token=PRIVATE", "AI ?token=PRIVATE", "AI &id=PRIVATE"]) {
    it(`records only the type when platform wording contains a URL or query (${text.slice(0, 4)})`, () => {
      const output = decode({ ai_label_info: { attribution_label_text: text } });
      expect(output).toContainEqual({
        path: "$.ai_label_info.attribution_label_text", name: "attribution_label_text", type: "string",
      });
      expect(JSON.stringify(output)).not.toContain("PRIVATE");
    });
  }

  for (const [name, text] of [
    ["control-split URL", "ht\ntps://private.invalid/resource"],
    ["control-split query", "AI ?to\nken=PRIVATE_QUERY"],
    ["URL beyond truncation", "AI " + "生".repeat(80) + " https://private.invalid/resource"],
    ["control-split URL beyond truncation", "AI " + "生".repeat(80) + " ht\ntps://private.invalid/resource"],
  ]) {
    it(`rejects platform wording containing ${name} before truncation`, () => {
      const label = decode({ ai_label_info: { attribution_label_text: text } })
        .find(record => record.path === "$.ai_label_info.attribution_label_text");
      expect(label).toEqual({
        path: "$.ai_label_info.attribution_label_text", name: "attribution_label_text", type: "string",
      });
    });
  }
});
