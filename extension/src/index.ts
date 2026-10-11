// Platform dispatcher: picks the right pure parser from the page URL.

import { parseInstagram, type InstagramResult } from "./instagram";
import { parseXhs, type XhsResult } from "./xhs";

export type ParseErrorCode =
  | "LOGIN_REQUIRED"
  | "PRIVATE_OR_UNAVAILABLE"
  | "BLOCKED"
  | "INVALID_PAGE"
  | "UNSUPPORTED_URL";

export interface ParseError {
  code: ParseErrorCode;
  message: string;
}

export type ParseResult = XhsResult | InstagramResult | { ok: false; error: ParseError };

function hostnameOf(pageUrl: string): string | undefined {
  try {
    return new URL(pageUrl).hostname.toLowerCase();
  } catch {
    return undefined;
  }
}

function isXhsHost(host: string): boolean {
  return host === "xiaohongshu.com" || host.endsWith(".xiaohongshu.com") || host === "xhslink.com" || host.endsWith(".xhslink.com");
}

function isInstagramHost(host: string): boolean {
  return host === "instagram.com" || host.endsWith(".instagram.com") || host === "instagr.am" || host.endsWith(".instagr.am");
}

/**
 * Parse a supported post page. Unsupported hosts fail with UNSUPPORTED_URL;
 * every other failure comes from the platform parser's own error model.
 */
export function parse(html: string, pageUrl: string): ParseResult {
  const host = hostnameOf(pageUrl);
  if (!host) {
    return { ok: false, error: { code: "UNSUPPORTED_URL", message: `Cannot parse URL: ${pageUrl}` } };
  }
  if (isXhsHost(host)) return parseXhs(html, pageUrl);
  if (isInstagramHost(host)) return parseInstagram(html, pageUrl);
  return {
    ok: false,
    error: { code: "UNSUPPORTED_URL", message: `Unsupported host: ${host}` },
  };
}
