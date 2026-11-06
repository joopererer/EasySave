import { expect, it } from 'vitest';
import { parseX } from '../src/x';
import { readFileSync } from 'node:fs';

for (const input of [
  { errors: [{ message: 'You must be logged in to view this content', code: 32 }] },
  { __typename: 'TweetUnavailable', reason: 'NsfwLoggedOut' },
  { __typename: 'TweetTombstone', tombstone: { text: { text: 'Age-restricted content' } } },
]) {
  it(`distinguishes explicit restriction ${JSON.stringify(input)}`, () => {
    const result = parseX(input, 'https://x.com/test/status/123');
    expect(result).toEqual({ ok: false, error: {
      code: 'LOGIN_REQUIRED', message: '该内容需要登录 X 才能查看',
    } });
  });
}
it('does not invent a login restriction for an empty public response', () => {
  expect(parseX('', 'https://x.com/test/status/123')).toMatchObject({
    ok: false, error: { code: 'PRIVATE_OR_UNAVAILABLE' },
  });
});
it('recognizes an explicit HTML access gate without using generic sign-in navigation', () => {
  const html = readFileSync(new URL('../../spec/fixtures/x/build28-login-gate.html', import.meta.url), 'utf8');
  const expected = JSON.parse(readFileSync(new URL('../../spec/fixtures/x/build28-login-gate.expected.json', import.meta.url), 'utf8'));
  expect(parseX(html, 'https://x.com/test/status/123')).toEqual({ ok: false, ...expected });
  expect(parseX('<nav>Log in</nav><main>This post was deleted</main>', 'https://x.com/test/status/123'))
    .toMatchObject({ ok: false, error: { code: 'PRIVATE_OR_UNAVAILABLE' } });
});
