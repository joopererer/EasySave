// Page-world hooks migrated from the former Dart injection strings.
export function installIgSniff() {
(() => {
  if (window.__easysaveSniffInstalled) return;
  window.__easysaveSniffInstalled = true;
  window.__easysaveIgProducts = window.__easysaveIgProducts || {};

  function isProductShaped(obj) {
    if (!obj || typeof obj !== 'object') return false;
    const sc = typeof obj.shortcode === 'string' ? obj.shortcode : (typeof obj.code === 'string' ? obj.code : null);
    if (!sc) return false;
    return ('video_versions' in obj || 'carousel_media' in obj || 'image_versions2' in obj || 'display_url' in obj || 'video_url' in obj || 'edge_sidecar_to_children' in obj);
  }

  function extractProducts(payload) {
    const seen = new Set();
    function visit(node) {
      if (!node || typeof node !== 'object') return;
      if (seen.has(node)) return;
      seen.add(node);
      if (isProductShaped(node)) {
        const sc = typeof node.shortcode === 'string' ? node.shortcode : node.code;
        window.__easysaveIgProducts[sc] = node;
      }
      if (Array.isArray(node)) {
        for (const item of node) visit(item);
      } else {
        for (const key of Object.keys(node)) visit(node[key]);
      }
    }
    try { visit(payload); } catch (_) {}
  }

  function sniffText(text) {
    if (!text || text.length < 10) return;
    if (!text.includes('shortcode') && !text.includes('xdt_shortcode_media') && !text.includes('edge_sidecar_to_children') && !text.includes('display_url')) return;
    try {
      const json = JSON.parse(text);
      extractProducts(json);
    } catch (_) {}
  }

  try {
    const originalFetch = window.fetch;
    if (originalFetch) {
      window.fetch = async function(...args) {
        const response = await originalFetch.apply(this, args);
        try {
          const clone = response.clone();
          clone.text().then(sniffText).catch(() => {});
        } catch (_) {}
        return response;
      };
    }
  } catch (_) {}

  try {
    const originalOpen = XMLHttpRequest.prototype.open;
    const originalSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function(method, url, ...rest) {
      this.__url = url;
      return originalOpen.apply(this, [method, url, ...rest]);
    };
    XMLHttpRequest.prototype.send = function(...args) {
      this.addEventListener('load', function() {
        try {
          sniffText(this.responseText);
        } catch (_) {}
      });
      return originalSend.apply(this, args);
    };
  } catch (_) {}
})();
}
export function readXhsAccount() { return JSON.parse((function () {
  try {
    var unwrap = function (v) { return v && v.__v_isRef ? v.value : v; };
    var state = window.__INITIAL_STATE__;
    var user = state && unwrap(state.user);
    if (!user) return JSON.stringify({ state: 'unknown' });
    var loggedIn = unwrap(user.loggedIn);
    if (typeof loggedIn !== 'boolean') return JSON.stringify({ state: 'unknown' });
    if (!loggedIn) return JSON.stringify({ state: 'guest' });
    var info = unwrap(user.userInfo);
    var result = { state: 'user' };
    if (info && info.userId) result.userId = String(info.userId);
    if (info && info.nickname) result.nickname = String(info.nickname);
    return JSON.stringify(result);
  } catch (e) {
    return JSON.stringify({ state: 'unknown' });
  }
})()); }
export function tiktokReady() { return (() => {
  try {
    const node = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
    const root = window.__UNIVERSAL_DATA_FOR_REHYDRATION__ ||
      (node && JSON.parse(node.textContent));
    const scope = root && root.__DEFAULT_SCOPE__;
    return !!(scope && ['webapp.video-detail', 'webapp.reflow.video.detail'].some(key => {
      const detail = scope[key];
      return detail && ((detail.itemInfo && detail.itemInfo.itemStruct && detail.itemInfo.itemStruct.id) ||
        (detail.statusCode != null && Number(detail.statusCode) !== 0));
    }));
  } catch (_) { return false; }
})(); }
