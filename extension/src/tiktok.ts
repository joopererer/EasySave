// Pure TikTok parser. Cookies never enter the parser input or output model.
import { tiktokAiLabel, type AiLabel } from './ai-label';
type RecordValue = Record<string, unknown>;
const record = (v: unknown): RecordValue =>
  v !== null && typeof v === 'object' && !Array.isArray(v) ? v as RecordValue : {};
const text = (v: unknown): string | undefined => typeof v === 'string' ? v : undefined;
const number = (v: unknown): number => typeof v === 'number' && Number.isFinite(v) ? v : 0;

export function extractTiktokPostId(url: string): string | undefined {
  try {
    const u = new URL(url);
    if (!['http:', 'https:'].includes(u.protocol) ||
        !['www.tiktok.com', 'm.tiktok.com', 'tiktok.com'].includes(u.hostname)) return;
    return /^\/@[^/]*\/(?:video|photo)\/(\d+)\/?$/.exec(u.pathname)?.[1] ??
      /^\/v\/(\d+)\.html\/?$/.exec(u.pathname)?.[1] ??
      /^\/share\/video\/(\d+)\/?$/.exec(u.pathname)?.[1];
  } catch { return; }
}

export function isTiktokLink(url: string): boolean {
  if (extractTiktokPostId(url)) return true;
  try {
    const u = new URL(url);
    return ['http:', 'https:'].includes(u.protocol) &&
      ['vm.tiktok.com', 'vt.tiktok.com'].includes(u.hostname) && /^\/[^/]+\/?$/.test(u.pathname);
  } catch { return false; }
}

function urls(value: unknown): string[] {
  const values = Array.isArray(value) ? value : [value];
  return [...new Set(values.filter((v): v is string => {
    if (typeof v !== 'string') return false;
    try { return ['https:', 'http:'].includes(new URL(v).protocol); } catch { return false; }
  }))];
}

export interface TiktokItem {
  type: 'image' | 'video';
  url: string;
  videoUrl?: string;
  fallbacks?: string[];
  width?: number;
  height?: number;
  duration?: number;
}

/** Only playback addresses are candidates. downloadAddr is never read. */
export function selectTiktokVideo(value: unknown): TiktokItem | undefined {
  const video = record(value);
  const variants = (Array.isArray(video.bitrateInfo) ? video.bitrateInfo : [])
    .map(v => {
      const b = record(v), addr = record(b.PlayAddr);
      return { urls: urls(addr.UrlList), width: number(addr.Width),
        height: number(addr.Height), bitrate: number(b.Bitrate) };
    }).filter(v => v.urls.length > 0)
    .sort((a, b) => b.width * b.height - a.width * a.height || b.bitrate - a.bitrate);
  const candidates = [...new Set([
    ...variants.flatMap(v => v.urls), ...urls(video.playAddr),
    ...urls(record(video.PlayAddrStruct).UrlList),
  ])];
  if (!candidates.length) return;
  return { type: 'video', url: candidates[0], videoUrl: candidates[0],
    fallbacks: candidates.slice(1),
    width: variants[0]?.width || number(video.width) || undefined,
    height: variants[0]?.height || number(video.height) || undefined,
    duration: number(video.duration) || undefined };
}

export type TiktokErrorCode = 'DELETED' | 'PRIVATE' | 'REGION_RESTRICTED' | 'UNKNOWN' | 'UNSUPPORTED_URL';
export type TiktokResult = { ok: false; error: { code: TiktokErrorCode; message: string } } |
  { ok: true; data: { platform: 'tiktok'; id: string; url: string;
    author: { name?: string; id?: string }; caption?: string; title?: string;
    publishedAt?: string; items: TiktokItem[]; aiLabel?: AiLabel } };

function failure(detail: RecordValue): TiktokResult {
  const status = Number(detail.statusCode);
  const message = (text(detail.statusMsg) ?? text(detail.statusMessage))?.toLowerCase() ?? '';
  // Private codes and IP denial are documented by yt-dlp's TikTok extractor.
  // Do not infer deletion merely from an unknown status or missing itemStruct.
  if ([10216, 10222].includes(status) || /private/.test(message))
    return { ok: false, error: { code: 'PRIVATE', message: '该 TikTok 帖子或账号为私密' } };
  if (status === 10204 || /region|country|geo.?block|ip.*block/.test(message))
    return { ok: false, error: { code: 'REGION_RESTRICTED', message: '该 TikTok 帖子受地区或 IP 限制' } };
  if (/deleted|removed|not found|does not exist/.test(message))
    return { ok: false, error: { code: 'DELETED', message: '该 TikTok 帖子已删除或不存在' } };
  return { ok: false, error: { code: 'UNKNOWN', message: '无法读取 TikTok 帖子，请重新解析' } };
}

export function parseTiktok(input: string, pageUrl: string): TiktokResult {
  const wanted = extractTiktokPostId(pageUrl);
  if (!wanted) return { ok: false, error: { code: 'UNSUPPORTED_URL', message: '请先展开 TikTok 短链' } };
  let root: RecordValue;
  try {
    const json = input.trim().startsWith('{') ? input :
      /<script\b[^>]*\bid=["']__UNIVERSAL_DATA_FOR_REHYDRATION__["'][^>]*>([\s\S]*?)<\/script>/i.exec(input)?.[1];
    root = record(JSON.parse(json ?? ''));
  } catch { return failure({}); }
  const scope = record(root.__DEFAULT_SCOPE__);
  // Mobile WebView receives the reflow route, even at a canonical /video URL.
  // Prefer a matching item rather than an unrelated or empty route's payload.
  const details = ['webapp.video-detail', 'webapp.reflow.video.detail']
    .map(key => record(scope[key])).filter(detail => Object.keys(detail).length > 0);
  const detail = details.find(detail => Number(detail.statusCode) === 0 &&
    text(record(record(detail.itemInfo).itemStruct).id) === wanted) ?? details[0] ?? {};
  const item = record(record(detail.itemInfo).itemStruct);
  if (Number(detail.statusCode) !== 0 || !Object.keys(item).length) return failure(detail);
  const id = text(item.id);
  if (!id || !/^\d+$/.test(id) || id !== wanted) return failure({});
  const imagePost = record(item.imagePost);
  let items: TiktokItem[];
  if (Array.isArray(imagePost.images)) {
    items = imagePost.images.map(raw => {
      const image = record(raw), addr = record(image.imageURL);
      const candidates = urls(addr.urlList);
      return { type: 'image' as const, url: candidates[0], fallbacks: candidates.slice(1),
        width: number(image.imageWidth) || undefined, height: number(image.imageHeight) || undefined };
    });
    if (items.some(i => !i.url)) return failure({});
  } else {
    const video = selectTiktokVideo(item.video);
    items = video ? [video] : [];
  }
  if (!items.length) return failure({});
  const author = record(item.author), authorId = text(author.id);
  const created = Number(item.createTime);
  const date = new Date(created * 1000);
  return { ok: true, data: { platform: 'tiktok', id,
    url: `https://www.tiktok.com/@/video/${id}`,
    author: { name: text(author.nickname), id: authorId && /^\d+$/.test(authorId) ? authorId : undefined },
    caption: text(item.desc), title: text(imagePost.title),
    aiLabel: tiktokAiLabel(item.aigcLabelType, id),
    publishedAt: created > 0 && !isNaN(date.getTime()) ? date.toISOString().replace('.000Z', 'Z') : undefined,
    items } };
}
