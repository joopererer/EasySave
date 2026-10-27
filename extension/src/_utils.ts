export function hostnameOf(url: string): string | null {
  try {
    const { hostname } = new URL(url);
    return hostname ?? null;
  } catch {
    return null;
  }
}

export function isXhsHost(host: string): boolean {
  return /xiaohongshu\.com|rednote\.com|xhslink\.com|xhslink\.cn|xhs\.cn/.test(host);
}

export function isInstagramHost(host: string): boolean {
  return /instagram\.com|instagr\.am/.test(host);
}

export function isXHost(host: string): boolean {
  return /x\.com|twitter\.com/.test(host);
}