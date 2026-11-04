import { describe, it, expect } from 'vitest';
import { buildNoteFromRecord } from '../src/xhs';
import { buildPostFromProduct } from '../src/instagram';
import sites from '../../config/sites.json';

describe('declared thumbnail variants leave original downloads intact', () => {
  it('XHS selects configured preview scene verbatim and omits when unavailable', () => {
    const scenes = sites.find(s => s.id === 'xhs')!.download.thumbnailScenes;
    const entry = {urlDefault:'https://sns-img-qc.xhscdn.com/synthetic!large', infoList:[
      {imageScene:'WB_DFT',url:'https://sns-img-qc.xhscdn.com/synthetic!large'},
      {imageScene:'WB_PRV',url:'https://sns-img-qc.xhscdn.com/synthetic!small'}]};
    const record = {noteId:'123456789012345678901234', imageList:[entry]};
    const result = buildNoteFromRecord(record, record.noteId, undefined, scenes);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.data.items[0].thumbnailUrl).toBe(entry.infoList[1].url);
    expect(result.data.items[0].url).toBe('https://sns-img-bd.xhscdn.com/synthetic');
    const fallback = buildNoteFromRecord(record, record.noteId, undefined, ['UNKNOWN']);
    if (fallback.ok) expect(fallback.data.items[0].thumbnailUrl).toBeUndefined();
  });
  it('Instagram uses smallest supplied candidate only when enabled', () => {
    const product = {user:{}, image_versions2:{candidates:[
      {url:'https://scontent.cdninstagram.com/large',width:1080,height:1620},
      {url:'https://scontent.cdninstagram.com/small',width:320,height:480}]}};
    expect(sites.find(s=>s.id==='instagram')!.download.thumbnailVariant).toBe('smallestCandidate');
    const result = buildPostFromProduct(product, 'synthetic', true);
    if (!result.ok) throw Error('parse failed');
    expect(result.data.items[0].url).toBe(product.image_versions2.candidates[0].url);
    expect(result.data.items[0].thumbnailUrl).toBe(product.image_versions2.candidates[1].url);
    const legacy = buildPostFromProduct(product, 'synthetic');
    if (legacy.ok) expect(legacy.data.items[0].thumbnailUrl).toBeUndefined();
  });
});
