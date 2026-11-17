import { withMediaResources } from './media-resources';
import { parseX, parseXGraphql, xProbe, calculateToken, extractTweetId, X_SENSITIVE_MEDIA_HINT, X_SESSION_EXPIRED } from './x';
import { findNoteInStates, xhsImageDownloadOrder, xhsImageProbe, xhsLandingPage, xhsPageSignal, xhsStreamProbe, XHS_LOGIN_REQUIRED } from './xhs';
import { parseTiktok, extractTiktokPostId, tiktokExpiresAt } from './tiktok';
import { gateMediaUnavailable, instagramPageSignal } from './instagram';
import { parsePageForModule as legacyPage, parse as legacyParse } from './_parse_page';
import { installIgSniff, installXGraphqlSniff, readXhsAccount, tiktokReady } from './page-hooks';

type Context = { url: string; input?: string; site: any; error?: any; loggedIn?: boolean; statusCode?: number; location?: string; caps?: string[] };
type Hooks = Partial<Record<'install' | 'request' | 'ready' | 'navigate' | 'prepare' | 'parsePage' | 'parse' | 'classify' | 'account' | 'probeSession' | 'expiresAt' | 'probe', (c: Context) => any>>
  & { decorate?: (result: any) => any };
const page = () => window as any;
const failure = (code: string, message: string) => ({ code, message });
/** Shown when an App that believes it is signed in meets a login wall. */
const SESSION_EXPIRED = '登录可能已失效，请重新登录';
/** Answer used when the page cannot be read or the module cannot parse it. */
const unreadable = () => failure('INVALID_PAGE', '页面内容无法识别，可能已改版');
/** The page a failed parse landed on; empty when the document is unreadable. */
const pageHtml = (): string => {
  try { return document.documentElement.outerHTML || ''; } catch (_) { return ''; }
};
/** An older App gets a code it renders with login guidance. */
const appFacing = (moduleId: string, result: any, caps: unknown) =>
  moduleId === 'instagram' ? gateMediaUnavailable(result, caps) : result;
const onXPage = () => {
  try { return /(?:^|\.)(?:x|twitter)\.com$/i.test(location.hostname); } catch (_) { return false; }
};
const xCaptured = (): any[] => (page().__easysaveXGraphql || []).flatMap((entry: any) => {
  try { return [JSON.parse(entry.text)]; } catch (_) { return []; }
});

const modules: Record<string, Hooks> = {
  x: {
    // The logged-in entry page (load.entryTemplate) is read from the page's own
    // GraphQL responses; the guest JSON endpoint path never runs these hooks.
    install: () => { if (onXPage()) installXGraphqlSniff(); },
    ready: (c) => {
      const id = extractTweetId(c.url);
      return !onXPage() || (page().__easysaveXGraphql || []).some((entry: any) =>
        entry.op === 'TweetResultByRestId' || (!!id && typeof entry.text === 'string' && entry.text.includes(`"tweet-${id}"`)));
    },
    parsePage: (c) => parseXGraphql(xCaptured(), c.url),
    probe: (c) => onXPage()
      ? { tag: 'XProbe', ...xProbe(xCaptured(), 'graphql', c.url) }
      : { tag: 'XProbe', ...xProbe(c.input ?? '', 'syndication', c.url) },
    classify: (c) => {
      if (!c.loggedIn) return c.error;
      // Only the logged-in page's own answer proves the session still sees a restriction.
      if (!onXPage()) return c.error;
      if (c.error?.code === 'AGE_RESTRICTED') return failure('AGE_RESTRICTED', X_SENSITIVE_MEDIA_HINT.zh);
      if (c.error?.code === 'LOGIN_REQUIRED') return failure('LOGIN_REQUIRED', X_SESSION_EXPIRED.zh);
      return c.error;
    },
    request: (c) => {
      const id = extractTweetId(c.url);
      if (!id) throw new Error('UNSUPPORTED_URL');
      const template = c.site.load.endpointTemplate;
      return { url: template.replaceAll('{id}', id).replaceAll('{token}', calculateToken(id)),
        headers: c.site.load.headers || {} };
    },
    parse: (c) => c.statusCode === 404
      ? { ok: false, error: failure('PRIVATE_OR_UNAVAILABLE', 'Post is unavailable or private') }
      : parseX(c.input || '', c.url),
  },
  xhs: {
    // App-only download order: original resolution first, preview scenes
    // (WB_PRV / H5_PRV / !nd_prv) never. The legacy url/fallbacks stay as-is.
    decorate: (result) => !result?.ok || !Array.isArray(result.data?.items) ? result
      : { ...result, data: { ...result.data, items: result.data.items.map((item: any) =>
          item.type === 'video' ? item
            : { ...item, downloadOrder: xhsImageDownloadOrder(item.url, item.fallbacks ?? []) }) } },
    ready: (c) => {
      const state = page().__INITIAL_STATE__;
      if (!state) return false;
      const wanted = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-zA-Z0-9]+)/.exec(c.url)?.[1];
      const map = state.note?.noteDetailMap;
      if (map) return wanted ? Object.hasOwn(map, wanted) : Object.keys(map).length > 0;
      const note = state.noteData?.data?.noteData || state.noteData?.data;
      return !!note && (!wanted || !(note.noteId || note.id) || (note.noteId || note.id) === wanted);
    },
    account: () => readXhsAccount(),
    probe: (c) => {
      const id = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-zA-Z0-9]+)/.exec(c.url)?.[1];
      const note = findNoteInStates([page().__INITIAL_STATE__], id);
      return { tag: 'XhsStreamProbe', streams: xhsStreamProbe(note?.['video']), images: xhsImageProbe(note) };
    },
    probeSession: (c) => {
      if ((c.statusCode || 0) >= 300 && (c.statusCode || 0) < 400) return !(c.location || '').includes('/login');
      if (c.statusCode !== 200) return true;
      if ((c.input || '').includes('"loggedIn":false')) return false;
      return true;
    },
    classify: (c) => {
      if (!['LOGIN_REQUIRED', 'INVALID_PAGE'].includes(c.error?.code)) return c.error;
      if (!c.loggedIn) return failure('LOGIN_REQUIRED', XHS_LOGIN_REQUIRED);
      // A note request bounced to the home feed or the login page, and a login
      // wall on a page the App believes it is signed in for, both mean the
      // stored session is what is missing. Anything else (the note's own
      // unavailable notice, or no signal at all) keeps the old answer.
      if (xhsLandingPage(c.url || '') || xhsPageSignal(pageHtml(), c.url) === 'login_wall') {
        return failure('LOGIN_REQUIRED', SESSION_EXPIRED);
      }
      return failure('PRIVATE_OR_UNAVAILABLE', '未能读取笔记内容（分享链接可能已过期，请重新粘贴原分享链接再试）');
    },
  },
  instagram: {
    install: () => installIgSniff(),
    ready: (c) => {
      const id = /\/(?:p|reels?|tv)\/([A-Za-z0-9_-]+)/.exec(c.url)?.[1];
      return !!(id && page().__easysaveIgProducts?.[id]) ||
        !!document.querySelector('article video, main video, article img, main img');
    },
    prepare: () => {
      const words = ['see post', 'view post', '查看帖子', '查看貼文', '了解详情', 'continue', 'i understand', '确认'];
      for (const node of Array.from(document.querySelectorAll('button, [role="button"], a[role="button"]'))) {
        const text = ((node as HTMLElement).innerText || node.textContent || '').trim().toLowerCase();
        if (words.some((word) => text.includes(word))) { (node as HTMLElement).click(); return true; }
      }
      return false;
    },
    probe: () => ({ tag: 'IgParse', reason: 'no_probe' }),
    classify: (c) => {
      if (c.error?.code !== 'LOGIN_REQUIRED' || !c.loggedIn) return c.error;
      // A login wall on a page the App believes it is signed in for means the
      // stored session stopped working; an age / sensitive-content gate and a
      // page with no signal keep the old answer.
      if (instagramPageSignal(pageHtml(), c.url) === 'login_wall') {
        return failure('LOGIN_REQUIRED', SESSION_EXPIRED);
      }
      return failure('PRIVATE_OR_UNAVAILABLE', /敏感内容|年龄限制/.test(c.error.message || '')
        ? c.error.message : '未能读取帖子内容（可能包含受限内容或已被删除）');
    },
  },
  tiktok: {
    expiresAt: (c) => tiktokExpiresAt(c.url),
    ready: () => tiktokReady(),
    navigate: (c) => {
      const id = extractTiktokPostId(c.url);
      return id ? { url: c.site.normalize.canonicalTemplate.replaceAll('{id}', id) } : { wait: true };
    },
    parse: (c) => parseTiktok(c.input || '', c.url),
  },
};

/**
 * A hook answer the App can always read.
 *
 * A hot-updated bundle runs inside an App it does not control: a throw inside a
 * hook reaches the App as an empty `evaluateJavascript` result, which it reports
 * as `FormatException: Invalid parser hook result` with nothing but a retry.
 * Every hook therefore answers a value of its own documented shape, and a
 * failure of any kind becomes an existing error code instead of an exception.
 */
export function moduleCall(moduleId: string, hook: string, context: Context): string {
  try {
    return runHook(moduleId, hook, context);
  } catch (_) {
    return fallbackHook(hook, context);
  }
}

function fallbackHook(hook: string, context: Context): string {
  switch (hook) {
    case 'parse': case 'parsePage':
      return JSON.stringify({ value: { ok: false, error: unreadable() } });
    case 'classify':
      return JSON.stringify({ value: context?.error ?? unreadable() });
    case 'ready': case 'prepare':
      return JSON.stringify({ value: false });
    case 'probe':
      // The App reads `probe` as a structure; a bare null would be reported as
      // a hook mismatch, so an empty probe still names itself.
      return JSON.stringify({ value: { tag: 'NoProbe' } });
    default:
      return JSON.stringify({ value: null });
  }
}

/** The value of a hook that returned nothing, in the shape its hook expects. */
function emptyHookValue(hook: string, context: Context): any {
  switch (hook) {
    case 'install': case 'navigate': case 'account': return null;
    case 'ready': case 'prepare': return false;
    case 'classify': return context.error ?? unreadable();
    case 'probe': return { tag: 'NoProbe' };
    default: return null;
  }
}

function parseObjectOrUnreadable(raw: unknown): any {
  try {
    const parsed = JSON.parse(String(raw));
    return parsed && typeof parsed === 'object' ? parsed : { ok: false, error: unreadable() };
  } catch (_) {
    return { ok: false, error: unreadable() };
  }
}

function runHook(moduleId: string, hook: string, context: Context): string {
  if (!Object.hasOwn(modules, moduleId)) {
    // The module id comes from the verified manifest, so this is a bundle/App
    // mismatch; answer structurally so the user sees readable copy.
    return hook === 'parse' || hook === 'parsePage'
      ? JSON.stringify({ value: { ok: false, error: unreadable() } })
      : fallbackHook(hook, context);
  }
  if (hook === 'decorate') throw new Error('UNSUPPORTED_HOOK');
  if (hook === 'classify' && context.error?.code === 'PRIVATE_OR_UNAVAILABLE' &&
      context.site.auth.mode !== 'none' && !context.loggedIn && moduleId !== 'x') {
    context = { ...context, error: failure('LOGIN_REQUIRED', '可能需要登录' + context.site.displayName) };
  }
  const module = modules[moduleId];
  const scenes = context.site?.download?.thumbnailScenes;
  const smallThumbnail = context.site?.download?.thumbnailVariant === 'smallestCandidate';
  const output = (value: any) => JSON.stringify({ value:
    hook === 'parse' || hook === 'parsePage'
      ? withMediaResources(module.decorate ? module.decorate(value) : value, context.site, (url) =>
          module.expiresAt?.({ ...context, url }))
      : value });
  if (Object.hasOwn(module, hook)) {
    const value = (module as any)[hook](context);
    return output(value === undefined ? emptyHookValue(hook, context) : value);
  }
  switch (hook) {
    case 'install': case 'navigate': case 'account': return JSON.stringify({ value: null });
    case 'prepare': return JSON.stringify({ value: false });
    case 'ready': return JSON.stringify({ value: true });
    case 'parsePage': {
      const html = pageHtml();
      const cached = parseObjectOrUnreadable(legacyPage(moduleId, scenes, smallThumbnail));
      if (cached.ok) return output(cached);
      // Without a readable document the HTML fallback has nothing to judge, so
      // the page-level answer (an unreadable page, or a bounced note request)
      // stands instead of being flattened into a login guess.
      if (!html) return output(cached);
      // The page cache may be stale or the page may not be a note page; the
      // independent HTML answer decides, and it never throws either.
      return output(appFacing(moduleId, parseObjectOrUnreadable(legacyParse(html, context.url, moduleId, scenes, smallThumbnail)), context.caps));
    }
    case 'parse': return output(appFacing(moduleId, parseObjectOrUnreadable(legacyParse(context.input || '', context.url, moduleId, scenes, smallThumbnail)), context.caps));
    case 'classify': {
      const error = context.error;
      return JSON.stringify({ value: error?.code === 'PRIVATE_OR_UNAVAILABLE' &&
        context.site.auth.mode !== 'none' && !context.loggedIn
          ? failure('LOGIN_REQUIRED', '可能需要登录' + context.site.displayName) : error ?? unreadable() });
    }
    case 'probe': return JSON.stringify({ value: { tag: 'NoProbe' } });
    default: throw new Error('UNSUPPORTED_HOOK');
  }
}
