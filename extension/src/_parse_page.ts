import { parseXhs, findNoteInStates, buildNoteFromRecord } from './xhs';
import { parseInstagram } from './instagram';
import { hostnameOf, isXhsHost, isInstagramHost } from './_utils';

function noteIdFromUrl(url: string): string | undefined {
  const m = /\/(?:explore|discovery\/item|user\/profile\/[^/]+)\/([a-f0-9]{24})/i.exec(url);
  return m ? m[1].toLowerCase() : undefined;
}

export function parsePage(): string {
  const url = window.location.href;
  const html = document.documentElement.outerHTML;
  if (isXhsHost(url)) {
    const state = (window as any).__INITIAL_STATE__;
    if (state !== undefined) {
      try {
        const wantedId = noteIdFromUrl(url);
        const note = findNoteInStates([state], wantedId);
        if (note) {
          const noteId =
            typeof note["noteId"] === "string" && (note["noteId"] as string).length > 0
              ? (note["noteId"] as string)
              : (wantedId ?? "");
          if (noteId) {
            return JSON.stringify(buildNoteFromRecord(note, noteId));
          }
        }
      } catch (_) {
        // fall through to regular parsing
      }
    }
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