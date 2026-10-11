export default defineBackground(() => {
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || typeof (message as { type?: string }).type !== "string") return;
    const type = (message as { type: string }).type;

    if (type === "EASYSAVE_BRIDGE_INSTALL") {
      // Install the MAIN-world agent via the scripting API instead of a
      // <script> tag: file-based execution is exempt from the page's CSP,
      // which on these sites blocks chrome-extension: script URLs.
      void (async () => {
        try {
          const tabId = sender.tab?.id;
          if (tabId === undefined) {
            sendResponse({ ok: false });
            return;
          }
          await chrome.scripting.executeScript({
            target: { tabId },
            files: ["page-bridge.js"],
            world: "MAIN",
          });
          sendResponse({ ok: true });
        } catch {
          sendResponse({ ok: false });
        }
      })();
      return true;
    }

    if (type !== "EASYSAVE_DOWNLOAD") return;
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
