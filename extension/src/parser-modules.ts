import { withMediaResources } from './media-resources';
import { parseX, calculateToken, extractTweetId } from './x';
import { parseTiktok, extractTiktokPostId, tiktokExpiresAt } from './tiktok';
import { parsePageForModule as legacyPage, parse as legacyParse } from './_parse_page';
import { installIgSniff, readXhsAccount, tiktokReady } from './page-hooks';

type Context = { url: string; input?: string; site: any; error?: any; loggedIn?: boolean; statusCode?: number; location?: string };
type Hooks = Partial<Record<'install' | 'request' | 'ready' | 'navigate' | 'prepare' | 'parsePage' | 'parse' | 'classify' | 'account' | 'probeSession' | 'expiresAt', (c: Context) => any>>;
const page = () => window as any;
const failure = (code: string, message: string) => ({ code, message });

const modules: Record<string, Hooks> = {
  x: {
    classify: (c) => c.error,
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
    probeSession: (c) => {
      if ((c.statusCode || 0) >= 300 && (c.statusCode || 0) < 400) return !(c.location || '').includes('/login');
      if (c.statusCode !== 200) return true;
      if ((c.input || '').includes('"loggedIn":false')) return false;
      return true;
    },
    classify: (c) => ['LOGIN_REQUIRED', 'INVALID_PAGE'].includes(c.error?.code)
      ? (c.loggedIn
        ? failure('PRIVATE_OR_UNAVAILABLE', '未能读取笔记内容（分享链接可能已过期，请重新粘贴原分享链接再试）')
        : failure('LOGIN_REQUIRED', '需要先登录小红书才能解析该笔记'))
      : c.error,
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
    classify: (c) => c.error?.code === 'LOGIN_REQUIRED' && c.loggedIn
      ? failure('PRIVATE_OR_UNAVAILABLE', /敏感内容|年龄限制/.test(c.error.message || '')
        ? c.error.message : '未能读取帖子内容（可能包含受限内容或已被删除）') : c.error,
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

export function moduleCall(moduleId: string, hook: string, context: Context): string {
  if (!Object.hasOwn(modules, moduleId)) throw new Error('UNSUPPORTED_MODULE');
  if (hook === 'classify' && context.error?.code === 'PRIVATE_OR_UNAVAILABLE' &&
      context.site.auth.mode !== 'none' && !context.loggedIn && moduleId !== 'x') {
    context = { ...context, error: failure('LOGIN_REQUIRED', '可能需要登录' + context.site.displayName) };
  }
  const module = modules[moduleId];
  const output = (value: any) => JSON.stringify({ value:
    hook === 'parse' || hook === 'parsePage'
      ? withMediaResources(value, context.site, (url) =>
          module.expiresAt?.({ ...context, url }))
      : value });
  if (Object.hasOwn(module, hook)) return output((module as any)[hook](context) ?? null);
  switch (hook) {
    case 'install': case 'navigate': case 'account': return JSON.stringify({ value: null });
    case 'prepare': return JSON.stringify({ value: false });
    case 'ready': return JSON.stringify({ value: true });
    case 'parsePage': {
      try {
        const result = JSON.parse(legacyPage(moduleId, context.site.download?.thumbnailScenes, context.site.download?.thumbnailVariant === 'smallestCandidate'));
        if (result.ok) return output(result);
      } catch (_) {
        // A stale page cache must not prevent the independent HTML fallback.
      }
      return output(JSON.parse(legacyParse(document.documentElement.outerHTML, context.url, moduleId, context.site.download?.thumbnailScenes, context.site.download?.thumbnailVariant === 'smallestCandidate')));
    }
    case 'parse': return output(JSON.parse(legacyParse(context.input || '', context.url, moduleId, context.site.download?.thumbnailScenes, context.site.download?.thumbnailVariant === 'smallestCandidate')));
    case 'classify': {
      const error = context.error;
      return JSON.stringify({ value: error?.code === 'PRIVATE_OR_UNAVAILABLE' &&
        context.site.auth.mode !== 'none' && !context.loggedIn
          ? failure('LOGIN_REQUIRED', '可能需要登录' + context.site.displayName) : error });
    }
    default: throw new Error('UNSUPPORTED_HOOK');
  }
}
