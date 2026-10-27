// Platform dispatcher: picks the right pure parser from the page URL.

import { parseInstagram, type InstagramResult } from "./instagram";
import { parseXhs, type XhsResult } from "./xhs";
import { parseX, type XResult } from "./x";

export type ParseErrorCode =
  | "LOGIN_REQUIRED"
  | "PRIVATE_OR_UNAVAILABLE"
  | "BLOCKED"
  | "INVALID_PAGE"
  | "UNSUPPORTED_URL"
  | "TIMEOUT";

export interface ParseError {
  code: ParseErrorCode;
  message: string;
}

export type ParseResult =
  | XhsResult
  | InstagramResult
  | XResult
  | { ok: false; error: ParseError };

function hostnameOf(pageUrl: string): string | undefined {
  try {
    return new URL(pageUrl).hostname.toLowerCase();
  } catch {
    return undefined;
  }
}

function isXhsHost(host: string): boolean {
  return (
    host === "xiaohongshu.com" ||
    host.endsWith(".xiaohongshu.com") ||
    host === "rednote.com" ||
    host.endsWith(".rednote.com") ||
    host === "xhslink.com" ||
    host.endsWith(".xhslink.com") ||
    host === "xhslink.cn" ||
    host.endsWith(".xhslink.cn") ||
    host === "xhs.cn" ||
    host.endsWith(".xhs.cn")
  );
}

function isInstagramHost(host: string): boolean {
  return (
    host === "instagram.com" ||
    host.endsWith(".instagram.com") ||
    host === "instagr.am" ||
    host.endsWith(".instagr.am")
  );
}

function isXHost(host: string): boolean {
  return (
    host === "x.com" ||
    host.endsWith(".x.com") ||
    host === "twitter.com" ||
    host.endsWith(".twitter.com")
  );
}

/**
 * Parse a supported post page. Unsupported hosts fail with UNSUPPORTED_URL;
 * every other failure comes from the platform parser's own error model.
 */
export function parse(input: string, pageUrl: string): ParseResult {
  const host = hostnameOf(pageUrl);
  if (!host) {
    return {
      ok: false,
      error: { code: "UNSUPPORTED_URL", message: `Cannot parse URL: ${pageUrl}` },
    };
  }
  if (isXhsHost(host)) return parseXhs(input, pageUrl);
  if (isInstagramHost(host)) return parseInstagram(input, pageUrl);
  if (isXHost(host)) return parseX(input, pageUrl);
  return {
    ok: false,
    error: { code: "UNSUPPORTED_URL", message: `Unsupported host: ${host}` },
  };
}

export { parseXhs, parseInstagram, parseX };
