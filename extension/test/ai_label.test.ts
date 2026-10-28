import { describe, it, expect, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { xhsAiLabel, tiktokAiLabel } from '../src/ai-label';
import { parseXhs } from '../src/xhs';
import { parseTiktok } from '../src/tiktok';

const fixture = (name: string) => readFileSync(new URL(`../../spec/fixtures/ai-label/${name}.json`, import.meta.url), 'utf8');

describe('AI label mapping', () => {
  it.each(['platform', 'author', 'normal'])('XHS anonymous %s fixture', kind => {
    const input = fixture(`xhs-${kind}`);
    const result = parseXhs(`<script>window.__INITIAL_STATE__=${input}</script>`, 'https://www.xiaohongshu.com/explore/000000000000000000000001');
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.data.aiLabel).toEqual(kind === 'normal' ? undefined : {
      text: kind === 'platform' ? '可能含AI生成内容' : '作者声明：含ai生成内容', source: kind,
    });
  });
  it.each(['platform', 'author'])('TikTok anonymous %s fixture', kind => {
    const result = parseTiktok(fixture(`tiktok-${kind}`), 'https://www.tiktok.com/@/video/1234567890123456789');
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.data.aiLabel).toEqual({ source: kind, text: kind === 'platform' ? 'Contains AI-generated media' : 'Creator labeled as AI-generated' });
  });
  it.each(['AI', '含AI内容', '可能含AI生成内容 ', '作者声明：原创', '普通说明'])('unknown desc %s is diagnostic only', desc => {
    const log = vi.spyOn(console, 'info').mockImplementation(() => {});
    expect(xhsAiLabel(desc, '123')).toBeUndefined();
    expect(log).toHaveBeenCalledWith('EasySaveAiLabel:' + JSON.stringify({ id: '123', value: desc }));
    log.mockRestore();
  });
  it.each([0, 3, -1, '01', 'unknown', false])('unknown type %s is diagnostic only', value => {
    const log = vi.spyOn(console, 'info').mockImplementation(() => {});
    expect(tiktokAiLabel(value, '123')).toBeUndefined();
    expect(log).toHaveBeenCalledWith('EasySaveAiLabel:' + JSON.stringify({ id: '123', value }));
    log.mockRestore();
  });
  it('preserves author text exactly and matches AI case insensitively', () => {
    expect(xhsAiLabel('作者声明：含 Ai 内容  ', '123')).toEqual({ text: '作者声明：含 Ai 内容  ', source: 'author' });
  });
  it.each([1, 2])('maps numeric enum %s', value => {
    expect(tiktokAiLabel(value, '123')?.source).toBe(value === 1 ? 'platform' : 'author');
  });
  it('ignores absent and empty values', () => {
    const log = vi.spyOn(console, 'info').mockImplementation(() => {});
    for (const value of [undefined, null, '', '  ']) {
      expect(xhsAiLabel(value, '123')).toBeUndefined();
      expect(tiktokAiLabel(value, '123')).toBeUndefined();
    }
    expect(log).not.toHaveBeenCalled();
    log.mockRestore();
  });
  it('never uses obsolete TikTok fields', () => {
    const root = JSON.parse(fixture('tiktok-platform'));
    const item = root.__DEFAULT_SCOPE__['webapp.video-detail'].itemInfo.itemStruct;
    delete item.aigcLabelType;
    item.IsAigc = true;
    item.AIGCDescription = 'AI';
    const result = parseTiktok(JSON.stringify(root), 'https://www.tiktok.com/@/video/1234567890123456789');
    expect(result.ok && result.data.aiLabel).toBeUndefined();
  });
});
