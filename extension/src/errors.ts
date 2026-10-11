// Chinese user-facing messages for parser error codes.

import type { ParseErrorCode } from "./index";

export const ERROR_MESSAGES: Record<ParseErrorCode, string> = {
  LOGIN_REQUIRED: "需要登录后才能下载，请先在当前网站登录后再试。",
  PRIVATE_OR_UNAVAILABLE: "该内容为私密、已删除或不可用，无法下载。",
  BLOCKED: "触发了网站的验证机制，请稍后重试。",
  INVALID_PAGE: "当前页面没有可下载的内容。",
  UNSUPPORTED_URL: "当前页面不受支持。",
};

export function errorMessage(code: ParseErrorCode): string {
  return ERROR_MESSAGES[code];
}
