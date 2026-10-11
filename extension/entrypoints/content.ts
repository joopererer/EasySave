export default defineContentScript({
  matches: ["*://*.xiaohongshu.com/*", "*://*.instagram.com/*"],
  world: "MAIN",
  main() {
    const host = location.hostname.toLowerCase();
    const isXhs = host === "xiaohongshu.com" || host.endsWith(".xiaohongshu.com");
    const isInstagram = host === "instagram.com" || host.endsWith(".instagram.com");

    const PREFIX = "easysave";
    let panelEl: HTMLElement | null = null;
    let lastParsedUrl: string | null = null;
    let lastResult: import("../src/index").ParseResult | null = null;
    let statusTimer: ReturnType<typeof setTimeout> | null = null;

    const css = `
      .${PREFIX}-btn{position:fixed;right:20px;bottom:24px;z-index:2147483647;
        background:#ff2442;color:#fff;border:none;border-radius:999px;
        padding:10px 18px;font-size:14px;font-weight:600;cursor:pointer;
        box-shadow:0 4px 16px rgba(0,0,0,.25);font-family:system-ui,sans-serif}
      .${PREFIX}-btn:hover{filter:brightness(1.08)}
      .${PREFIX}-panel{position:fixed;right:20px;bottom:76px;z-index:2147483647;
        width:340px;max-height:70vh;display:flex;flex-direction:column;
        background:#fff;border-radius:12px;box-shadow:0 8px 32px rgba(0,0,0,.3);
        font-family:system-ui,sans-serif;font-size:13px;color:#222;overflow:hidden}
      .${PREFIX}-head{display:flex;align-items:center;gap:8px;padding:10px 12px;
        border-bottom:1px solid #eee;font-weight:600}
      .${PREFIX}-head button{margin-left:auto;border:none;background:none;
        font-size:16px;cursor:pointer;color:#888}
      .${PREFIX}-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;
        padding:12px;overflow-y:auto}
      .${PREFIX}-cell{position:relative;aspect-ratio:3/4;border-radius:8px;overflow:hidden;
        background:#f3f3f3;cursor:pointer;border:2px solid transparent}
      .${PREFIX}-cell img,.${PREFIX}-cell video{width:100%;height:100%;object-fit:cover;display:block}
      .${PREFIX}-cell.${PREFIX}-off{opacity:.4}
      .${PREFIX}-cell.${PREFIX}-off{border-color:transparent}
      .${PREFIX}-cell:not(.${PREFIX}-off){border-color:#ff2442}
      .${PREFIX}-tick{position:absolute;top:4px;right:4px;width:20px;height:20px;border-radius:50%;
        background:#ff2442;color:#fff;font-size:13px;line-height:20px;text-align:center}
      .${PREFIX}-cell.${PREFIX}-off .${PREFIX}-tick{background:#bbb}
      .${PREFIX}-badge{position:absolute;left:4px;bottom:4px;background:rgba(0,0,0,.6);
        color:#fff;font-size:11px;padding:1px 6px;border-radius:6px}
      .${PREFIX}-foot{padding:10px 12px;border-top:1px solid #eee;display:flex;gap:8px;align-items:center}
      .${PREFIX}-foot .${PREFIX}-dl{flex:1;background:#ff2442;color:#fff;border:none;
        border-radius:8px;padding:8px;font-size:14px;font-weight:600;cursor:pointer}
      .${PREFIX}-foot .${PREFIX}-dl:disabled{background:#ccc;cursor:default}
      .${PREFIX}-foot .${PREFIX}-link{border:none;background:none;color:#ff2442;cursor:pointer;font-size:13px}
      .${PREFIX}-err{padding:16px;color:#c00;line-height:1.6}
      .${PREFIX}-status{padding:6px 12px;color:#666;font-size:12px}
    `;
    const style = document.createElement("style");
    style.textContent = css;
    document.documentElement.appendChild(style);

    const btn = document.createElement("button");
    btn.className = `${PREFIX}-btn`;
    btn.textContent = "下载";
    btn.addEventListener("click", () => {
      if (panelEl) {
        closePanel();
      } else {
        void openPanel();
      }
    });
    document.documentElement.appendChild(btn);

    function closePanel(): void {
      panelEl?.remove();
      panelEl = null;
    }

    function noteIdFromUrl(url: string): string | undefined {
      const m = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-f0-9]{24})/i.exec(url);
      return m ? m[1].toLowerCase() : undefined;
    }

    async function parseCurrent(): Promise<import("../src/index").ParseResult> {
      const url = location.href;
      if (lastResult && lastParsedUrl === url) return lastResult;
      const { parse } = await import("../src/index");
      let result: import("../src/index").ParseResult;
      if (isXhs) {
        const { readXhsStateJson } = await import("../src/main-world");
        const { findNoteInStates, buildNoteFromRecord } = await import("../src/xhs");
        const wantedId = noteIdFromUrl(url);
        const state = readXhsStateJson();
        const note = state === undefined ? undefined : findNoteInStates([state], wantedId);
        if (note) {
          const noteId =
            typeof note["noteId"] === "string" && (note["noteId"] as string).length > 0
              ? (note["noteId"] as string)
              : (wantedId ?? "");
          result = noteId ? buildNoteFromRecord(note, noteId) : parse(document.documentElement.outerHTML, url);
        } else {
          result = parse(document.documentElement.outerHTML, url);
        }
      } else {
        result = parse(document.documentElement.outerHTML, url);
      }
      lastParsedUrl = url;
      lastResult = result;
      return result;
    }

    // SPA in-page navigation: drop the cached result so the next open re-parses.
    let observedUrl = location.href;
    setInterval(() => {
      if (location.href !== observedUrl) {
        observedUrl = location.href;
        lastParsedUrl = null;
        lastResult = null;
        closePanel();
      }
    }, 800);

    const TYPE_LABEL: Record<string, string> = { image: "图", video: "视频", live: "实况" };

    async function openPanel(): Promise<void> {
      const result = await parseCurrent();
      const panel = document.createElement("div");
      panel.className = `${PREFIX}-panel`;

      if (!result.ok) {
        const { errorMessage } = await import("../src/errors");
        const head = document.createElement("div");
        head.className = `${PREFIX}-head`;
        head.textContent = "EasySave";
        const close = document.createElement("button");
        close.textContent = "✕";
        close.addEventListener("click", closePanel);
        head.appendChild(close);
        const err = document.createElement("div");
        err.className = `${PREFIX}-err`;
        const failure = result as unknown as { error: { code: import("../src/index").ParseErrorCode } };
        err.textContent = errorMessage(failure.error.code);
        panel.append(head, err);
        document.documentElement.appendChild(panel);
        panelEl = panel;
        return;
      }

      const data = result.data;
      const items = data.items;
      const selected = new Set<number>(items.map((_, i) => i));

      const head = document.createElement("div");
      head.className = `${PREFIX}-head`;
      const title =
        ("title" in data && typeof data.title === "string" ? data.title : undefined) ??
        data.caption ??
        data.id;
      head.textContent = `${data.author.name ?? ""} · ${items.length} 个媒体`;
      head.title = title;
      const close = document.createElement("button");
      close.textContent = "✕";
      close.addEventListener("click", closePanel);
      head.appendChild(close);

      const grid = document.createElement("div");
      grid.className = `${PREFIX}-grid`;

      items.forEach((item, i) => {
        const cell = document.createElement("div");
        cell.className = `${PREFIX}-cell`;
        let thumb: HTMLElement;
        if (item.type === "image" || item.type === "live") {
          const img = document.createElement("img");
          img.src = item.url;
          img.loading = "lazy";
          thumb = img;
        } else {
          const v = document.createElement("video");
          v.src = item.videoUrl ?? item.url;
          v.muted = true;
          v.preload = "metadata";
          thumb = v;
        }
        const tick = document.createElement("div");
        tick.className = `${PREFIX}-tick`;
        tick.textContent = "✓";
        const badge = document.createElement("div");
        badge.className = `${PREFIX}-badge`;
        badge.textContent = TYPE_LABEL[item.type] ?? item.type;
        cell.append(thumb, tick, badge);
        cell.addEventListener("click", () => {
          if (selected.has(i)) {
            selected.delete(i);
            cell.classList.add(`${PREFIX}-off`);
          } else {
            selected.add(i);
            cell.classList.remove(`${PREFIX}-off`);
          }
          refreshFoot();
        });
        grid.appendChild(cell);
      });

      const foot = document.createElement("div");
      foot.className = `${PREFIX}-foot`;
      const allBtn = document.createElement("button");
      allBtn.className = `${PREFIX}-link`;
      allBtn.textContent = "全选";
      allBtn.addEventListener("click", () => {
        items.forEach((_, i) => selected.add(i));
        grid.querySelectorAll(`.${PREFIX}-off`).forEach((el) => el.classList.remove(`${PREFIX}-off`));
        refreshFoot();
      });
      const noneBtn = document.createElement("button");
      noneBtn.className = `${PREFIX}-link`;
      noneBtn.textContent = "取消全选";
      noneBtn.addEventListener("click", () => {
        selected.clear();
        grid.querySelectorAll(`.${PREFIX}-cell`).forEach((el) => el.classList.add(`${PREFIX}-off`));
        refreshFoot();
      });
      const dlBtn = document.createElement("button");
      dlBtn.className = `${PREFIX}-dl`;
      const status = document.createElement("div");
      status.className = `${PREFIX}-status`;

      function refreshFoot(): void {
        dlBtn.textContent = `下载所选 (${selected.size})`;
        dlBtn.disabled = selected.size === 0;
      }
      refreshFoot();

      dlBtn.addEventListener("click", () => {
        void (async () => {
          const { downloadTargets } = await import("../src/download");
          const ctx = { platform: data.platform, author: data.author.name, id: data.id };
          const targets = [...selected]
            .sort((a, b) => a - b)
            .flatMap((i, k) => downloadTargets(items[i], ctx, k + 1));
          status.textContent = `正在下载 ${targets.length} 个文件…`;
          dlBtn.disabled = true;
          try {
            const res = (await chrome.runtime.sendMessage({
              type: "EASYSAVE_DOWNLOAD",
              targets,
            })) as { ok: boolean; failed?: number };
            status.textContent = res?.ok
              ? `已开始下载 ${targets.length} 个文件`
              : `下载失败 ${res?.failed ?? targets.length} 个，请重试`;
          } catch {
            status.textContent = "无法连接后台，请重载插件后重试";
          } finally {
            if (statusTimer) clearTimeout(statusTimer);
            statusTimer = setTimeout(() => {
              status.textContent = "";
              refreshFoot();
            }, 4000);
          }
        })();
      });

      foot.append(allBtn, noneBtn, dlBtn);
      panel.append(head, grid, foot, status);
      document.documentElement.appendChild(panel);
      panelEl = panel;
    }

    if (!isXhs && !isInstagram) {
      btn.style.display = "none";
    }
  },
});
