// Runs in the page's MAIN world:
//  1. sniffs XHR/fetch JSON responses for post records (SPA navigation loads
//     posts without a full page load, so embedded state goes stale);
//  2. answers state requests from the content script (ISOLATED world).

import { cachedNotesFromText, NoteCache } from "../src/note-cache";
import { cachedProductsFromText, ProductCache } from "../src/ig-cache";

export default defineUnlistedScript(() => {
  const w = window as unknown as Record<string, unknown>;
  if (w["__easysaveBridgeInstalled"]) return;
  w["__easysaveBridgeInstalled"] = true;

  const SOURCE = "easysave";
  const noteCache = new NoteCache(20);
  const productCache = new ProductCache(20);

  function readState(): unknown {
    const w = window as unknown as Record<string, unknown>;
    for (const key of ["__INITIAL_STATE__", "__NEXT_DATA__", "__NUXT__"]) {
      if (w[key] !== undefined) return w[key];
    }
    return undefined;
  }

  // postMessage uses structured clone, which throws on functions, symbols,
  // BigInt values and cyclic graphs sometimes found in live page state.
  // Sanitize first so the bridge answers instead of dying silently.
  function safeClone(value: unknown): unknown {
    const seen = new WeakSet<object>();
    const walk = (v: unknown): unknown => {
      if (typeof v === "bigint") return `${String(v)}n`;
      if (typeof v === "function" || typeof v === "symbol" || v === undefined) return undefined;
      if (v === null || typeof v !== "object") return v;
      if (seen.has(v)) return undefined;
      seen.add(v);
      if (Array.isArray(v)) {
        const out: unknown[] = [];
        for (const el of v) out.push(walk(el));
        return out;
      }
      const out: Record<string, unknown> = {};
      for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
        const cloned = walk(val);
        if (cloned !== undefined) out[k] = cloned;
      }
      return out;
    };
    return walk(value);
  }

  function sniffText(text: string): void {
    if (!text || text.length < 2) return;
    try {
      const notes = cachedNotesFromText(text);
      if (notes.length > 0) noteCache.add(notes);
    } catch {
      // Ignore sniffing failures; the page must never break.
    }
    try {
      const products = cachedProductsFromText(text);
      if (products.length > 0) productCache.add(products);
    } catch {
      // Ignore sniffing failures; the page must never break.
    }
  }

  function isJsonResponse(contentType: string | null): boolean {
    return !!contentType && contentType.toLowerCase().includes("json");
  }

  let sniffInstalled = false;
  function installSniff(): void {
    if (sniffInstalled) return;
    sniffInstalled = true;
    try {
      const originalFetch = window.fetch.bind(window);
      window.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
        const response = await originalFetch(input, init);
        try {
          const contentType = response.headers.get("content-type");
          if (isJsonResponse(contentType)) {
            const text = await response.clone().text();
            sniffText(text);
          }
        } catch {
          // Ignore; the original response is untouched.
        }
        return response;
      }) as typeof window.fetch;

      const originalOpen = XMLHttpRequest.prototype.open;
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (
        this: XMLHttpRequest,
        method: string,
        url: string | URL,
        ...rest: unknown[]
      ): void {
        (originalOpen as (...args: unknown[]) => void).apply(this, [method, url, ...rest]);
      } as typeof XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.send = function (
        this: XMLHttpRequest,
        ...args: unknown[]
      ): ReturnType<typeof XMLHttpRequest.prototype.send> {
        this.addEventListener("load", () => {
          try {
            if (typeof this.responseText === "string") sniffText(this.responseText);
          } catch {
            // Ignore sniffing failures.
          }
        });
        return (originalSend as (...a: unknown[]) => ReturnType<typeof XMLHttpRequest.prototype.send>).apply(
          this,
          args,
        );
      };
    } catch {
      // If patching fails (locked-down page), state reads still work.
    }
  }

  installSniff();

  window.addEventListener("message", (event: MessageEvent) => {
    if (event.source !== window) return;
    const data = event.data as {
      source?: string;
      type?: string;
      nonce?: string;
      wantedId?: string;
      wantedShortcode?: string;
    } | null;
    if (!data || data.source !== SOURCE || data.type !== "EASYSAVE_GET_STATE") return;
    let state: unknown;
    let note: unknown;
    let recent: unknown;
    let product: unknown;
    try {
      state = safeClone(readState());
      if (typeof data.wantedId === "string" && data.wantedId.length > 0) {
        note = safeClone(noteCache.get(data.wantedId));
      }
      recent = safeClone(noteCache.recent());
      if (typeof data.wantedShortcode === "string" && data.wantedShortcode.length > 0) {
        product = safeClone(productCache.get(data.wantedShortcode));
      }
    } catch {
      state = undefined;
      note = undefined;
      recent = undefined;
      product = undefined;
    }
    const answer = {
      source: SOURCE,
      type: "EASYSAVE_STATE",
      nonce: data.nonce,
      state,
      note,
      recent,
      product,
    };
    try {
      window.postMessage(answer, "*");
    } catch {
      // Last resort: answer without payloads so the content script falls back
      // to parsing the page HTML instead of timing out.
      try {
        window.postMessage(
          { source: SOURCE, type: "EASYSAVE_STATE", nonce: data.nonce },
          "*",
        );
      } catch {
        // Ignore; the content script will time out and use its fallback.
      }
    }
  });
});
