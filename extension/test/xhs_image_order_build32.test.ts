import { describe, expect, it, vi, afterEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { moduleCall } from '../src/_parse_page';
import { xhsImageDownloadOrder, xhsImageProbe, xhsImageVariant } from '../src/xhs';
import sites from '../../config/sites.json';

afterEach(() => vi.unstubAllGlobals());

const token = 'notes_pre_post/1040g3k83264voo1al0dg5o2e1l408pfcf1dl208';
const original = `https://sns-img-bd.xhscdn.com/${token}`;
const jpeg = `https://ci.xiaohongshu.com/${token}?imageView2/format/jpg`;
const preview = `https://sns-webpic-qc.xhscdn.com/202610112129/a657f0bce4b0d577975cf2d1df487c06/${token}!nd_prv_wlteh_webp_3`;
const dft = `https://sns-webpic-qc.xhscdn.com/202610112129/eb1fb79a62c72f9dbe14dd2909e2d83c/${token}!nd_dft_wlteh_webp_3`;
const ciBare = `https://ci.xiaohongshu.com/${token}`;

describe('XHS image download candidates', () => {
  it('classifies every variant', () => {
    expect(xhsImageVariant(original)).toBe('original');
    expect(xhsImageVariant(jpeg)).toBe('jpeg');
    expect(xhsImageVariant(preview)).toBe('preview');
    expect(xhsImageVariant(dft)).toBe('default');
    expect(xhsImageVariant(ciBare)).toBe('original_ci');
    expect(xhsImageVariant(`https://sns-webpic-qc.xhscdn.com/x/${token}!h5_prv_webp`)).toBe('preview');
  });

  it('orders original resolution first and never includes a preview', () => {
    // The fixture order: url = original, fallbacks = jpeg, preview, default, ci.
    expect(xhsImageDownloadOrder(original, [jpeg, preview, dft, ciBare]))
      .toEqual([jpeg, original, ciBare, dft]);
  });

  it('falls back to the largest variant when no original is offered', () => {
    expect(xhsImageDownloadOrder(preview, [dft])).toEqual([dft]);
    expect(xhsImageDownloadOrder(dft, [preview])).toEqual([dft]);
  });

  it('adds downloadOrder to App results without changing the legacy fields', () => {
    const html = readFileSync(new URL('../../spec/fixtures/xhs/xhs_multi.html', import.meta.url), 'utf8');
    const expected = JSON.parse(readFileSync(new URL('../../spec/fixtures/xhs/xhs_multi.expected.json', import.meta.url), 'utf8'));
    const site = sites.find((s) => s.id === 'xhs');
    const value = JSON.parse(moduleCall('xhs', 'parse', {
      url: `https://www.xiaohongshu.com/explore/${expected.id}`, site, input: html,
    })).value;
    expect(value.ok).toBe(true);
    value.data.items.forEach((item: any, i: number) => {
      expect(item.url).toBe(expected.items[i].url);
      expect(item.fallbacks).toEqual(expected.items[i].fallbacks);
      if (item.type === 'video') return;
      expect(item.downloadOrder.length).toBeGreaterThan(0);
      expect(item.downloadOrder.some((u: string) => xhsImageVariant(u) === 'preview')).toBe(false);
      expect(xhsImageVariant(item.downloadOrder[0])).toBe('jpeg');
    });
    expect(() => moduleCall('xhs', 'decorate', { url: '', site })).toThrow('UNSUPPORTED_HOOK');
  });

  it('probes field names, scenes, declared size and the selected variant', () => {
    const note = { imageList: [
      { urlDefault: dft, urlPre: preview, width: 1290, height: 1608, traceId: 't1',
        infoList: [{ imageScene: 'WB_PRV', url: preview }, { imageScene: 'WB_DFT', url: dft }] },
      { urlDefault: preview, width: 800, height: 600,
        infoList: [{ imageScene: 'WB_PRV', url: preview }] },
    ] };
    const probe = xhsImageProbe(note);
    expect(probe[0]).toMatchObject({ index: 1, width: 1290, height: 1608, selected: 'jpeg',
      fields: ['urlDefault', 'urlPre', 'infoList', 'traceId'], scenes: ['WB_PRV', 'WB_DFT'] });
    expect(probe[0].candidates).not.toContain('preview');
    expect(probe[1].candidates).not.toContain('preview');
    expect(JSON.stringify(probe)).not.toContain('http');
  });
});
