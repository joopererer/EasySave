import { parseXhs, parseXhsState } from './xhs';
import { parseInstagram } from './instagram';
import { hostnameOf, isXhsHost, isInstagramHost } from './_utils';

export function parsePage(): string {
  const url = window.location.href;
  let html = document.documentElement.outerHTML;
  if (isXhsHost(url)) {
    const stateJson = (window as any).__INITIAL_STATE__;
    if (stateJson) {
      try {
        const result = parseXhsState(stateJson, url);
        return JSON.stringify(result);
      } catch (_) {
        // fall through to regular parsing
      }
    }
  }
  if (isXhsHost(url)) {
    return JSON.stringify(parseXhs(html, url));
  }
  if (isInstagramHost(url)) {
    return JSON.stringify(parseInstagram(html, url));
  }
  return JSON.stringify({ ok: false, error: { code: 'UNSUPPORTED_URL', message: `Unsupported host: ${url}` } });
}

export function parse(html: string, pageUrl: string): string {
  const host = hostnameOf(pageUrl);
  if (!host) {
    return JSON.stringify({ ok: false, error: { code: 'UNSUPPORTED_URL', message: `Cannot parse URL: ${pageUrl}` } });
  }
  if (isXhsHost(host)) {
    return JSON.stringify(parseXhs(html, pageUrl));
  }
  if (isInstagramHost(host)) {
    return JSON.stringify(parseInstagram(html, pageUrl));
  }
  return JSON.stringify({ ok: false, error: { code: 'UNSUPPORTED_URL', message: `Unsupported host: ${host}` } });
}