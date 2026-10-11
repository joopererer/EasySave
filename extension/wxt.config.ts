import { defineConfig } from "wxt";

export default defineConfig({
  manifest: {
    name: "EasySave",
    description: "Media download assistant",
    version: "0.1.0",
    permissions: ["activeTab", "downloads", "declarativeNetRequest"],
    host_permissions: [
      "*://*.xhscdn.com/*",
      "*://ci.xiaohongshu.com/*",
      "*://*.cdninstagram.com/*",
    ],
    declarative_net_request: {
      rule_resources: [
        {
          id: "referer-rules",
          enabled: true,
          path: "rules.json",
        },
      ],
    },
    web_accessible_resources: [
      {
        resources: ["page-bridge.js"],
        matches: ["*://*.xiaohongshu.com/*", "*://*.instagram.com/*"],
      },
    ],
  },
});
