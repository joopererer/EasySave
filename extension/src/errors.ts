// Chinese user-facing messages for parser error codes.
// Content follows the code -> message -> action table in spec/parsing.md.

import type { ParseErrorCode } from "./index";

export type ErrorAction = "goLogin" | "backHome" | "retry" | "repaste";

export interface ErrorCopy {
  message: string;
  action: ErrorAction;
}

export const ERROR_COPY: Record<ParseErrorCode, ErrorCopy> = {
  DELETED: { message: '该 TikTok 帖子已删除或不存在', action: 'backHome' },
  PRIVATE: { message: '该 TikTok 帖子或账号为私密', action: 'backHome' },
  REGION_RESTRICTED: { message: '该 TikTok 帖子受地区或 IP 限制', action: 'backHome' },
  UNKNOWN: { message: '无法读取 TikTok 帖子，请重新解析', action: 'retry' },
  LOGIN_REQUIRED: { message: "需要先登录小红书/Instagram", action: "goLogin" },
  PRIVATE_OR_UNAVAILABLE: { message: "该帖子不存在、私密或已删除", action: "backHome" },
  BLOCKED: { message: "请求被对方限制，请稍后再试", action: "retry" },
  INVALID_PAGE: { message: "页面内容无法识别，可能已改版", action: "retry" },
  UNSUPPORTED_URL: {
    message: "不支持的链接，请粘贴小红书/Instagram 帖子链接",
    action: "repaste",
  },
  TIMEOUT: { message: "网络超时，请检查网络后重试", action: "retry" },
};

export const ERROR_MESSAGES: Record<ParseErrorCode, string> = {
  DELETED: ERROR_COPY.DELETED.message,
  PRIVATE: ERROR_COPY.PRIVATE.message,
  REGION_RESTRICTED: ERROR_COPY.REGION_RESTRICTED.message,
  UNKNOWN: ERROR_COPY.UNKNOWN.message,
  LOGIN_REQUIRED: ERROR_COPY.LOGIN_REQUIRED.message,
  PRIVATE_OR_UNAVAILABLE: ERROR_COPY.PRIVATE_OR_UNAVAILABLE.message,
  BLOCKED: ERROR_COPY.BLOCKED.message,
  INVALID_PAGE: ERROR_COPY.INVALID_PAGE.message,
  UNSUPPORTED_URL: ERROR_COPY.UNSUPPORTED_URL.message,
  TIMEOUT: ERROR_COPY.TIMEOUT.message,
};

export function errorMessage(code: ParseErrorCode): string {
  return ERROR_MESSAGES[code];
}

export function errorCopy(code: ParseErrorCode): ErrorCopy {
  return ERROR_COPY[code];
}
