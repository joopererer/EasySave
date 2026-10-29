// v2-only adapter. The legacy parse ABI and fixture output remain unchanged.
type Role = 'image' | 'video' | 'motion' | 'poster';
export function withMediaResources(
  result: any, site: any, expiry: (url: string) => string | undefined = () => undefined,
): any {
  if (!result?.ok || !Array.isArray(result.data?.items)) return result;
  const defaults = site.download;
  const request = (role: Role, url: string) => {
    const extra = defaults.resourceDefaults?.[role] ?? {};
    return {
      headers: { ...defaults.headers, ...extra.headers },
      cookieDomains: [...(extra.cookieDomains ?? defaults.cookieDomains)],
      expiresAt: expiry(url),
      transport: extra.transport ?? defaults.transport,
      resumable: extra.resumable ?? defaults.resumable,
    };
  };
  return { ...result, data: { ...result.data, items: result.data.items.map((item: any) => {
    const video = item.type === 'video';
    const primary: Role = video
      ? (item.videoUrl && item.videoUrl !== item.url ? 'poster' : 'video') : 'image';
    const resources: any[] = [{ role: primary, url: item.url, request: request(primary, item.url) }];
    if (item.videoUrl && (!video || item.videoUrl !== item.url)) {
      const role: Role = video ? 'video' : 'motion';
      resources.push({ role, url: item.videoUrl, request: request(role, item.videoUrl) });
    }
    if (item.posterUrl) resources.push({
      role: 'poster', url: item.posterUrl, request: request('poster', item.posterUrl),
    });
    for (const url of item.fallbacks ?? []) resources.push({
      role: 'fallback', fallbackFor: primary, url, request: request(primary, url),
    });
    return { ...item, resources };
  }) } };
}
