// Runs in the page's MAIN world. Answers state requests from the content
// script (which lives in the ISOLATED world and cannot touch window state).

export default defineUnlistedScript(() => {
  const SOURCE = "easysave";

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

  window.addEventListener("message", (event: MessageEvent) => {
    if (event.source !== window) return;
    const data = event.data as { source?: string; type?: string; nonce?: string } | null;
    if (!data || data.source !== SOURCE || data.type !== "EASYSAVE_GET_STATE") return;
    let state: unknown;
    try {
      state = safeClone(readState());
    } catch {
      state = undefined;
    }
    try {
      window.postMessage({ source: SOURCE, type: "EASYSAVE_STATE", nonce: data.nonce, state }, "*");
    } catch {
      // Last resort: answer without state so the content script falls back
      // to parsing the page HTML instead of timing out.
      try {
        window.postMessage(
          { source: SOURCE, type: "EASYSAVE_STATE", nonce: data.nonce, state: undefined },
          "*",
        );
      } catch {
        // Ignore; the content script will time out and use its fallback.
      }
    }
  });
});
