import { afterEach, describe, expect, it, vi } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { moduleCall } from '../src/_parse_page';
import {
  classifyXUnavailable, parseX, parseXGraphql, xProbe,
  X_ERROR_COPY, X_SENSITIVE_MEDIA_HINT, X_SESSION_EXPIRED,
} from '../src/x';
import sites from '../../config/sites.json';

const fixtureRoot = fileURLToPath(new URL('../../spec/fixtures/x/', import.meta.url));
const graphqlDir = join(fixtureRoot, 'graphql');
const pageUrl = 'https://x.com/i/status/1234567890123456789';
const read = (path: string) => JSON.parse(readFileSync(path, 'utf8'));
const site = sites.find((s) => s.id === 'x')!;
const call = (hook: string, extra: any = {}) =>
  JSON.parse(moduleCall('x', hook, { url: pageUrl, site, ...extra })).value;
afterEach(() => vi.unstubAllGlobals());

describe('X GraphQL fixtures', () => {
  const cases = readdirSync(graphqlDir)
    .filter((name) => name.endsWith('.json') && !name.endsWith('.expected.json'))
    .map((name) => name.replace(/\.json$/, ''))
    .sort();
  it('covers every unavailable shape and the success shapes', () => {
    expect(cases).toEqual([
      'age-restricted-tombstone', 'deleted-tombstone', 'no-stated-age', 'nsfw-logged-out',
      'protected', 'tweet-detail-visibility', 'tweet-result-media',
    ]);
  });
  for (const name of cases) {
    it(`${name}.json matches ${name}.expected.json`, () => {
      const expected = read(join(graphqlDir, `${name}.expected.json`));
      const result = parseXGraphql([read(join(graphqlDir, `${name}.json`))], pageUrl);
      expect(result).toEqual('error' in expected
        ? { ok: false, error: expected.error }
        : { ok: true, data: expected });
    });
  }
  it('ignores other captured posts when the focal post is absent', () => {
    const other = { data: { tweetResult: undefined, threaded_conversation_with_injections_v2: {
      instructions: [{ entries: [{ entryId: 'tweet-1', content: {} }] }] } } };
    expect(parseXGraphql([other], pageUrl)).toMatchObject({ ok: false, error: { code: 'INVALID_PAGE' } });
  });
});

describe('X unavailable reasons', () => {
  const cases: Array<[Record<string, unknown>, string]> = [
    [{ __typename: 'TweetUnavailable', reason: 'NsfwLoggedOut' }, 'LOGIN_REQUIRED'],
    [{ __typename: 'TweetUnavailable', reason: 'NsfwViewerHasNoStatedAge' }, 'AGE_NOT_SET'],
    [{ __typename: 'TweetUnavailable', reason: 'NsfwViewerIsUnderage' }, 'AGE_RESTRICTED'],
    [{ __typename: 'TweetUnavailable', reason: 'Protected' }, 'PROTECTED'],
    [{ __typename: 'TweetUnavailable', reason: 'Suspended' }, 'PRIVATE_OR_UNAVAILABLE'],
    [{ __typename: 'TweetTombstone', tombstone: { text: { text: 'Age-restricted adult content.' } } }, 'AGE_RESTRICTED'],
    [{ __typename: 'TweetTombstone', tombstone: { text: { text: 'This Post was deleted by the Post author.' } } }, 'PRIVATE_OR_UNAVAILABLE'],
  ];
  for (const [input, code] of cases) {
    it(`maps ${JSON.stringify(input)} to ${code} with its copy`, () => {
      const expected = { ok: false, error: { code, message: X_ERROR_COPY[code as keyof typeof X_ERROR_COPY].zh } };
      expect(classifyXUnavailable(input)).toEqual(expected);
      expect(parseX(input, pageUrl)).toEqual(expected);
    });
  }
  it('gives every code Chinese and English copy', () => {
    for (const copy of [...Object.values(X_ERROR_COPY), X_SENSITIVE_MEDIA_HINT, X_SESSION_EXPIRED]) {
      expect(copy.zh).toMatch(/[一-鿿]/);
      expect(copy.en).toMatch(/^[\x20-\x7e→]+$/);
    }
  });
  it('rewrites the ambiguous unavailable copy', () => {
    expect(parseX('', pageUrl)).toEqual({ ok: false, error: {
      code: 'PRIVATE_OR_UNAVAILABLE', message: '帖子不可用：可能已删除、设为私密，或需要登录 X 才能查看' } });
  });
  it('keeps syndication fixtures at top level with their new codes', () => {
    for (const name of ['build29-no-stated-age', 'build29-protected', 'build29-age-restricted-tombstone', 'build29-unavailable-other']) {
      const expected = read(join(fixtureRoot, `${name}.expected.json`));
      expect(parseX(readFileSync(join(fixtureRoot, `${name}.json`), 'utf8'), pageUrl))
        .toEqual({ ok: false, error: expected.error });
    }
  });
});

describe('X probe', () => {
  it('records type names, reason and the first 40 tombstone characters only', () => {
    const tombstone = read(join(graphqlDir, 'age-restricted-tombstone.json'));
    expect(xProbe([tombstone], 'graphql', pageUrl)).toEqual({
      source: 'graphql', shape: 'tombstone', typename: 'TweetTombstone',
      tombstone: 'Age-restricted adult content. This conte', fields: ['__typename', 'tombstone'],
    });
    expect(xProbe('{"__typename":"TweetUnavailable","reason":"NsfwLoggedOut"}', 'syndication', pageUrl))
      .toEqual({ source: 'syndication', shape: 'unavailable', typename: 'TweetUnavailable',
        reason: 'NsfwLoggedOut', fields: ['__typename', 'reason'] });
    expect(xProbe('', 'syndication', pageUrl)).toEqual({ source: 'syndication', shape: 'empty', fields: [] });
    expect(xProbe([], 'graphql', pageUrl)).toEqual({ source: 'graphql', shape: 'none', fields: [] });
  });
  it('describes a visibility-wrapped tweet without its text', () => {
    const probe = xProbe([read(join(graphqlDir, 'tweet-detail-visibility.json'))], 'graphql', pageUrl);
    expect(probe).toMatchObject({ shape: 'tweet', typename: 'Tweet', wrapped: true, mediaCount: 1 });
    expect(JSON.stringify(probe)).not.toContain('Long note');
  });
});

describe('X logged-in page hooks', () => {
  const stubPage = (captured: Array<{ op: string; text: string }>) => {
    vi.stubGlobal('location', { hostname: 'x.com' });
    vi.stubGlobal('window', { __easysaveXGraphql: captured });
  };
  it('waits for the focal GraphQL response and parses it', () => {
    stubPage([]);
    expect(call('ready')).toBe(false);
    const media = readFileSync(join(graphqlDir, 'tweet-result-media.json'), 'utf8');
    stubPage([{ op: 'TweetResultByRestId', text: media }]);
    expect(call('ready')).toBe(true);
    const parsed = call('parsePage');
    expect(parsed.ok).toBe(true);
    expect(parsed.data.items.map((item: any) => item.type)).toEqual(['image', 'video']);
    expect(call('probe')).toMatchObject({ tag: 'XProbe', source: 'graphql', shape: 'tweet' });
  });
  it('switches to the session data after a guest age restriction', () => {
    // Guest syndication answer: restricted.
    const guest = call('parse', { input: '{"__typename":"TweetUnavailable","reason":"NsfwLoggedOut"}' });
    expect(guest.error.code).toBe('LOGIN_REQUIRED');
    // Logged-in page answer for the same post: the full tweet.
    stubPage([{ op: 'TweetResultByRestId', text: readFileSync(join(graphqlDir, 'tweet-result-media.json'), 'utf8') }]);
    expect(call('parsePage')).toMatchObject({ ok: true, data: { id: '1234567890123456789' } });
  });
  it('adds the sensitive-media hint only for a logged-in page age restriction', () => {
    const error = { code: 'AGE_RESTRICTED', message: X_ERROR_COPY.AGE_RESTRICTED.zh };
    // A guest answer while logged in does not prove the session is restricted.
    expect(call('classify', { error, loggedIn: true })).toEqual(error);
    stubPage([]);
    expect(call('classify', { error, loggedIn: false })).toEqual(error);
    expect(call('classify', { error, loggedIn: true }))
      .toEqual({ code: 'AGE_RESTRICTED', message: X_SENSITIVE_MEDIA_HINT.zh });
    expect(call('classify', { error: { code: 'LOGIN_REQUIRED', message: '' }, loggedIn: true }))
      .toEqual({ code: 'LOGIN_REQUIRED', message: X_SESSION_EXPIRED.zh });
  });
  it('installs the GraphQL sniff only on X pages', () => {
    vi.stubGlobal('location', { hostname: 'example.test' });
    const window = {} as any;
    vi.stubGlobal('window', window);
    call('install');
    expect(window.__easysaveXSniffInstalled).toBeUndefined();
  });
});
