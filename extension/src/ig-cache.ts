// Pure helpers for harvesting Instagram products from XHR/fetch JSON
// payloads. The page bridge uses these to cache posts loaded by SPA
// navigation, so posts opened without a full page load are still parseable.

export interface CachedProduct {
  shortcode: string;
  product: Record<string, unknown>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isProductShaped(obj: Record<string, unknown>): boolean {
  return (
    typeof obj["shortcode"] === "string" &&
    (obj["shortcode"] as string).length > 0 &&
    ("video_versions" in obj || "carousel_media" in obj || "image_versions2" in obj)
  );
}

/**
 * Walk a decoded JSON payload and collect every product record it contains,
 * keyed by shortcode (no BigInt conversion needed at sniff time).
 * Never throws on unexpected shapes.
 */
export function extractCachedProducts(payload: unknown): CachedProduct[] {
  const out: CachedProduct[] = [];
  const seenCodes = new Set<string>();
  const seen = new Set<object>();
  const visit = (node: unknown): void => {
    if (!isRecord(node) && !Array.isArray(node)) return;
    if (seen.has(node as object)) return;
    seen.add(node as object);
    if (isRecord(node)) {
      if (isProductShaped(node)) {
        const code = node["shortcode"] as string;
        if (!seenCodes.has(code)) {
          seenCodes.add(code);
          out.push({ shortcode: code, product: node });
        }
      }
      for (const value of Object.values(node)) visit(value);
    } else {
      for (const value of node as unknown[]) visit(value);
    }
  };

  try {
    visit(payload);
  } catch {
    // Ignore; return whatever was collected.
  }
  return out;
}

/** Parse response text into cached products; returns [] for non-JSON bodies. */
export function cachedProductsFromText(text: string): CachedProduct[] {
  if (text.length === 0 || text.length > 8 * 1024 * 1024) return [];
  if (!text.includes("shortcode")) return [];
  try {
    return extractCachedProducts(JSON.parse(text) as unknown);
  } catch {
    return [];
  }
}

/** Bounded shortcode -> product cache used by the bridge. */
export class ProductCache {
  private readonly map = new Map<string, Record<string, unknown>>();
  constructor(private readonly limit = 20) {}

  add(products: CachedProduct[]): void {
    for (const { shortcode, product } of products) {
      this.map.delete(shortcode);
      this.map.set(shortcode, product);
    }
    while (this.map.size > this.limit) {
      const oldest = this.map.keys().next();
      if (oldest.done) break;
      this.map.delete(oldest.value);
    }
  }

  get(shortcode: string): Record<string, unknown> | undefined {
    return this.map.get(shortcode);
  }
}
