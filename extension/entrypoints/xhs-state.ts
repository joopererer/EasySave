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

  window.addEventListener("message", (event: MessageEvent) => {
    if (event.source !== window) return;
    const data = event.data as { source?: string; type?: string; nonce?: string } | null;
    if (!data || data.source !== SOURCE || data.type !== "EASYSAVE_GET_STATE") return;
    let state: unknown;
    try {
      state = readState();
    } catch {
      state = undefined;
    }
    window.postMessage({ source: SOURCE, type: "EASYSAVE_STATE", nonce: data.nonce, state }, "*");
  });
});
