export default defineBackground(() => {
  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message || (message as { type?: string }).type !== "EASYSAVE_DOWNLOAD") return;
    const targets = (message as { targets?: Array<{ url: string; filename: string }> }).targets ?? [];
    void (async () => {
      let failed = 0;
      for (const target of targets) {
        try {
          await chrome.downloads.download({
            url: target.url,
            filename: target.filename,
            conflictAction: "uniquify",
          });
        } catch {
          failed++;
        }
      }
      sendResponse({ ok: failed === 0, failed });
    })();
    return true;
  });
});
