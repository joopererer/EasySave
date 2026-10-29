import { afterEach, describe, expect, it, vi } from 'vitest';
import { moduleCall } from '../src/_parse_page';
import { calculateToken } from '../src/x';
import sites from '../../config/sites.json';
const call = (id: string, hook: string, extra: any = {}) => JSON.parse(moduleCall(id, hook,
  {url: '', site: sites.find(s => s.id === id), ...extra})).value;
afterEach(() => vi.unstubAllGlobals());

describe('manifest-selected parser hooks', () => {
  it('rejects unknown modules and prototype property names', () => {
    for (const id of ['new-site', '__proto__', 'constructor', 'toString']) {
      expect(() => call(id, 'ready')).toThrow('UNSUPPORTED_MODULE');
    }
    expect(() => call('x', 'constructor')).toThrow('UNSUPPORTED_HOOK');
  });
  it('builds syndication JSON requests from signed options and the TS token implementation', () => {
    const id = '1234567890123456789';
    const site = {load: {endpointTemplate: 'https://api.example.test/{id}?token={token}', headers: {Accept: 'application/json'}}};
    expect(call('x', 'request', {url: 'https://x.com/user/status/' + id, site}))
      .toEqual({url: 'https://api.example.test/' + id + '?token=' + calculateToken(id), headers: site.load.headers});
    expect(() => call('x', 'request', {url: 'https://x.com/user'})).toThrow('UNSUPPORTED_URL');
    expect(call('x', 'parse', {statusCode:404}).error.code).toBe('PRIVATE_OR_UNAVAILABLE');
  });
  it('waits for the requested note, not stale state for a different note', () => {
    vi.stubGlobal('window', {__INITIAL_STATE__: {note: {noteDetailMap: {abc: {}}}}});
    expect(call('xhs', 'ready', {url:'https://www.xiaohongshu.com/explore/xyz'})).toBe(false);
    expect(call('xhs', 'ready', {url:'https://www.xiaohongshu.com/explore/abc'})).toBe(true);
  });
  it('reads optional account state without returning cookies', () => {
    vi.stubGlobal('window', {__INITIAL_STATE__: {user: {loggedIn:true, userInfo: {userId:'123', nickname:'User'}}}});
    expect(call('xhs', 'account')).toEqual({state:'user', userId:'123', nickname:'User'});
    vi.stubGlobal('window', {__INITIAL_STATE__: {user: {loggedIn:false}}});
    expect(call('xhs', 'account')).toEqual({state:'guest'});
    vi.stubGlobal('window', {});
    expect(call('xhs', 'account')).toEqual({state:'unknown'});
    expect(call('instagram', 'account')).toBeNull();
  });
  it('waits for short links, then navigates using the declared canonical template', () => {
    expect(call('tiktok','navigate',{url:'https://vm.tiktok.com/short/'})).toEqual({wait:true});
    expect(call('tiktok','navigate',{url:'https://www.tiktok.com/@user/photo/12345'}))
      .toEqual({url:'https://www.tiktok.com/@/video/12345'});
  });
  it('keeps optional feed probe interpretation in the signed module', () => {
    expect(call('xhs', 'probeSession', {statusCode:302, location:'/login'})).toBe(false);
    expect(call('xhs', 'probeSession', {statusCode:302, location:'/explore'})).toBe(true);
    expect(call('xhs', 'probeSession', {statusCode:200, input:'{"loggedIn":false}'})).toBe(false);
    expect(call('xhs', 'probeSession', {statusCode:200, input:'{"loggedIn":true}'})).toBe(true);
    expect(call('xhs', 'probeSession', {statusCode:503})).toBe(true);
  });
  it('accepts TikTok hydrated data and terminal page errors', () => {
    vi.stubGlobal('document', {getElementById:()=>null});
    vi.stubGlobal('window', {});
    expect(call('tiktok','ready')).toBe(false);
    vi.stubGlobal('window', {__UNIVERSAL_DATA_FOR_REHYDRATION__:{__DEFAULT_SCOPE__:{'webapp.video-detail':{itemInfo:{itemStruct:{id:'1'}}}}}});
    expect(call('tiktok','ready')).toBe(true);
    vi.stubGlobal('window', {__UNIVERSAL_DATA_FOR_REHYDRATION__:{__DEFAULT_SCOPE__:{'webapp.reflow.video.detail':{statusCode:10216}}}});
    expect(call('tiktok','ready')).toBe(true);
  });
  it('retains Instagram network products and dismisses page warnings', async () => {
    const product = {shortcode:'abc', video_url:'https://cdn.test/video.mp4'};
    const fetch = vi.fn(async () => ({clone:()=>({text:async()=>JSON.stringify({data:product})})}));
    const window: any = {fetch};
    vi.stubGlobal('window',window);
    call('instagram','install');
    const installed = window.fetch;
    call('instagram','install');
    expect(window.fetch).toBe(installed);
    await window.fetch('https://www.instagram.com/api/data');
    await Promise.resolve();
    expect(window.__easysaveIgProducts.abc).toEqual(product);
    const click = vi.fn();
    vi.stubGlobal('document', {querySelectorAll:()=>[{textContent:'View Post',click}], querySelector:()=>null});
    expect(call('instagram','ready',{url:'https://www.instagram.com/p/abc/'})).toBe(true);
    expect(call('instagram','prepare')).toBe(true);
    expect(click).toHaveBeenCalledOnce();
  });
  it('classifies login walls using module behavior and session context', () => {
    const error = {code:'LOGIN_REQUIRED',message:'Login'};
    expect(call('xhs','classify',{error,loggedIn:true}).code).toBe('PRIVATE_OR_UNAVAILABLE');
    expect(call('xhs','classify',{error,loggedIn:false}).code).toBe('LOGIN_REQUIRED');
    expect(call('xhs','classify',{error:{code:'PRIVATE_OR_UNAVAILABLE'},loggedIn:false}).code).toBe('LOGIN_REQUIRED');
    expect(call('instagram','classify',{error,loggedIn:true}).code).toBe('PRIVATE_OR_UNAVAILABLE');
    expect(call('tiktok','classify',{error:{code:'PRIVATE_OR_UNAVAILABLE'},loggedIn:false}).code).toBe('LOGIN_REQUIRED');
    expect(call('x','classify',{error:{code:'PRIVATE_OR_UNAVAILABLE'},loggedIn:false}).code).toBe('PRIVATE_OR_UNAVAILABLE');
  });
});
