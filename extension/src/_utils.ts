export function hostnameOf(url: string): string | null {
  try {
    const { hostname } = new URL(url);
    return hostname ?? null;
  } catch {
    return null;
  }
}

export function isXhsHost(host: string): boolean {
  return /xiaohongshu\.com|xhslink\.com/.test(host);
}

export function isInstagramHost(host: string): boolean {
  return /instagram\.com|instagr\.am/.test(host);
}