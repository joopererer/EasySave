import {
  ExtensionManifest,
  MANIFEST_URL,
  verifyManifestSignature,
} from "../src/manifest";


async function fetchManifest(): Promise<ExtensionManifest | null> {
  try {
    const res = await fetch(MANIFEST_URL, { cache: "no-cache" });
    if (!res.ok) return null;
    const data = (await res.json()) as ExtensionManifest;
    if (data && typeof data === "object") {
      const isValid = await verifyManifestSignature(data);
      if (!isValid) {
        console.warn(
          "EasySave: manifest signature verification failed! Ignoring cloud config.",
        );
        return null;
      }

      await chrome.storage.local.set({
        easysave_manifest: data,
        easysave_manifest_time: Date.now(),
      });
      await applyManifestHeaders(data.headers);
      return data;
    }
  } catch {
    // Best effort background sync
  }
  return null;
}

async function applyManifestHeaders(
  headers?: Record<string, Record<string, string>>,
): Promise<void> {
  if (!headers || !chrome.declarativeNetRequest?.updateDynamicRules) return;
  try {
    const newRules: chrome.declarativeNetRequest.Rule[] = [];
    let ruleId = 100;
    for (const [platform, headerMap] of Object.entries(headers)) {
      const requestHeaders: chrome.declarativeNetRequest.ModifyHeaderInfo[] =
        Object.entries(headerMap).map(([header, value]) => ({
          header,
          operation: chrome.declarativeNetRequest.HeaderOperation.SET,
          value,
        }));
      if (requestHeaders.length === 0) continue;
      let urlFilter = "*";
      if (platform === "xhs") urlFilter = "*://*.xiaohongshu.com/*";
      else if (platform === "instagram") urlFilter = "*://*.instagram.com/*";

      newRules.push({
        id: ruleId++,
        priority: 2,
        action: {
          type: chrome.declarativeNetRequest.RuleActionType.MODIFY_HEADERS,
          requestHeaders,
        },
        condition: {
          urlFilter,
          resourceTypes: [
            chrome.declarativeNetRequest.ResourceType.XMLHTTPREQUEST,
            chrome.declarativeNetRequest.ResourceType.MAIN_FRAME,
            chrome.declarativeNetRequest.ResourceType.SUB_FRAME,
          ],
        },
      });
    }

    const oldRules = await chrome.declarativeNetRequest.getDynamicRules();
    await chrome.declarativeNetRequest.updateDynamicRules({
      removeRuleIds: oldRules.map((r) => r.id),
      addRules: newRules,
    });
  } catch {
    // Best effort dynamic rule update
  }
}

export default defineBackground(() => {
  chrome.runtime.onInstalled.addListener(() => {
    void fetchManifest();
    chrome.alarms?.create("easysave_manifest_sync", { periodInMinutes: 360 });
  });

  chrome.alarms?.onAlarm.addListener((alarm) => {
    if (alarm.name === "easysave_manifest_sync") {
      void fetchManifest();
    }
  });

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || typeof (message as { type?: string }).type !== "string") return;
    const type = (message as { type: string }).type;

    if (type === "EASYSAVE_GET_PLATFORM_CONFIG") {
      const platform = (message as { platform?: string }).platform ?? "";
      void (async () => {
        try {
          const storage = await chrome.storage.local.get("easysave_manifest");
          const manifest = storage.easysave_manifest as ExtensionManifest | undefined;
          const config = manifest?.platforms?.[platform];
          sendResponse({
            enabled: config?.enabled ?? true,
            notice: config?.notice ?? "",
          });
        } catch {
          sendResponse({ enabled: true, notice: "" });
        }
      })();
      return true;
    }

    if (type === "EASYSAVE_BRIDGE_INSTALL") {
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
    const targets =
      (message as { targets?: Array<{ url: string; filename: string }> }).targets ?? [];
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
