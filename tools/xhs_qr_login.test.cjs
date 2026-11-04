const { readFileSync } = require('node:fs');
const { runInNewContext } = require('node:vm');
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { resolve } = require('node:path');

const source = readFileSync(resolve(__dirname, '../app/lib/services/login_navigation.dart'), 'utf8')
  .match(/const xhsPreferQrLogin = r'''([\s\S]*?)''';/)[1];

function page(href, tabs) {
  let clicks = 0;
  let mutation;
  let disconnected = false;
  const context = {
    location: { href }, window: {},
    document: { documentElement: {}, querySelectorAll: () => tabs },
    MutationObserver: class {
      constructor(callback) { mutation = callback; }
      observe() {}
      disconnect() { disconnected = true; }
    },
    setTimeout() {},
  };
  const tab = (text, width = 100) => ({
    textContent: text, offsetWidth: width, childElementCount: 0,
    click() { clicks++; },
  });
  return { context, tab, run: () => runInNewContext(source, context),
    clicks: () => clicks, mutate: () => mutation(), disconnected: () => disconnected };
}

test('desktop login selects the visible QR tab', () => {
  const tabs = [];
  const state = page('https://www.xiaohongshu.com/login', tabs);
  tabs.push(state.tab('密码登录'), state.tab('扫码登录'));
  state.run();
  assert.equal(state.clicks(), 1);
});

test('late QR tab is selected once and observer stops', () => {
  const tabs = [];
  const state = page('https://www.xiaohongshu.com/login', tabs);
  state.run();
  tabs.push(state.tab('二维码登录'));
  state.mutate();
  assert.equal(state.clicks(), 1);
  assert.equal(state.disconnected(), true);
});

test('hidden QR tab is not clicked', () => {
  const tabs = [];
  const state = page('https://www.xiaohongshu.com/login', tabs);
  tabs.push(state.tab('扫码登录', 0));
  state.run();
  assert.equal(state.clicks(), 0);
});

test('rednote and misleading hosts are not modified', () => {
  for (const href of ['https://www.rednote.com/login', 'https://www.xiaohongshu.com.evil.test/login']) {
    const tabs = [];
    const state = page(href, tabs);
    tabs.push(state.tab('扫码登录'));
    state.run();
    assert.equal(state.clicks(), 0);
  }
});
