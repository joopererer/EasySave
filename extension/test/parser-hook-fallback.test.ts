import { afterEach, expect, it, vi } from 'vitest';
import { moduleCall } from '../src/_parse_page';
afterEach(() => vi.unstubAllGlobals());
it('falls back to HTML when a page state getter throws during page extraction', () => {
  const url = 'https://www.xiaohongshu.com/explore/670f1a2b000000001e028b12';
  const page = {location:{href:url}};
  Object.defineProperty(page, '__INITIAL_STATE__', {get() {throw new Error('stale page state');}});
  vi.stubGlobal('window',page);
  vi.stubGlobal('document',{documentElement:{outerHTML:'<html></html>'}});
  const result = JSON.parse(moduleCall('xhs','parsePage',{url,site:{}})).value;
  expect(result.ok).toBe(false);
  expect(result.error.code).toBe('LOGIN_REQUIRED');
});
