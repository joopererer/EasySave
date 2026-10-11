import { describe, expect, it } from "vitest";
import { cachedProductsFromText, extractCachedProducts, ProductCache } from "../src/ig-cache";

describe("extractCachedProducts", () => {
  it("collects product objects keyed by shortcode", () => {
    const products = extractCachedProducts({
      data: {
        items: [
          { shortcode: "AbC123-_xYz", carousel_media: [], taken_at: 1 },
          { shortcode: "AbC123-_xYz", carousel_media: [], taken_at: 1 },
          { shortcode: "other", caption: "no media keys" },
        ],
      },
    });
    expect(products.map((p) => p.shortcode)).toEqual(["AbC123-_xYz"]);
  });

  it("ignores unexpected shapes without throwing", () => {
    expect(extractCachedProducts(null)).toEqual([]);
    expect(extractCachedProducts({ shortcode: 42 })).toEqual([]);
  });
});

describe("cachedProductsFromText", () => {
  it("parses JSON bodies containing shortcode markers", () => {
    const products = cachedProductsFromText(
      JSON.stringify({ shortcode: "AbC123-_xYz", image_versions2: { candidates: [] } }),
    );
    expect(products.map((p) => p.shortcode)).toEqual(["AbC123-_xYz"]);
  });

  it("rejects non-JSON bodies", () => {
    expect(cachedProductsFromText("<html>shortcode</html>")).toEqual([]);
  });
});

describe("ProductCache", () => {
  it("evicts oldest entries beyond the limit", () => {
    const cache = new ProductCache(1);
    cache.add([{ shortcode: "a", product: {} }]);
    cache.add([{ shortcode: "b", product: {} }]);
    expect(cache.get("a")).toBeUndefined();
    expect(cache.get("b")).toEqual({});
  });
});
