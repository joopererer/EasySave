// Runs one parser bundle the way the App does: EasySaveParser.moduleCall on the
// loaded page. Used only by the v1.10.2 compatibility test in this worktree.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const [bundlePath, htmlPath, url, hook, capsFlag] = process.argv.slice(2);
if (!bundlePath || !htmlPath || !url || !hook) {
  process.stderr.write('usage: harness.mjs <bundle> <html> <url> <hook> [caps|nocaps]\n');
  process.exit(2);
}

const html = readFileSync(htmlPath, 'utf8');
const source = readFileSync(bundlePath, 'utf8');
const consoleLines = [];

const page = { location: { href: url } };
const sandbox = {
  URL, JSON, Date, Math, BigInt, RegExp, Object, Array, String, Number,
  Boolean, Error, TypeError, RangeError, Promise, Set, Map, Symbol, Intl,
  parseInt, parseFloat, isNaN, encodeURIComponent, decodeURIComponent,
  console: {
    info: (...parts) => consoleLines.push(parts.join(' ')),
    log: () => {},
    warn: () => {},
    error: () => {},
  },
  window: page,
  self: page,
  location: page.location,
  document: {
    documentElement: { outerHTML: html },
    querySelectorAll: () => [],
    querySelector: () => null,
  },
};

vm.createContext(sandbox);
vm.runInContext(source, sandbox, { filename: bundlePath });
const parser = sandbox.EasySaveParser || page.EasySaveParser;
if (!parser || typeof parser.moduleCall !== 'function') {
  throw new Error('bundle did not define EasySaveParser.moduleCall');
}

// The App sends its verified site definition; only fields read by moduleCall
// for a failed Instagram parse are needed here.
const site = {
  id: 'instagram',
  platform: 'instagram',
  displayName: 'Instagram',
  auth: { mode: 'optional' },
  download: {
    headers: { Referer: 'https://www.instagram.com/' },
    cookieDomains: [],
    transport: 'background',
    resumable: true,
  },
};
const context = { url, site };
if (capsFlag === 'caps') context.caps = ['media_unavailable'];

const raw = parser.moduleCall('instagram', hook, context);
process.stdout.write(
  JSON.stringify({
    version: typeof parser.parse === 'function' ? 'bundle-loaded' : 'missing',
    console: consoleLines,
    value: JSON.parse(raw).value,
  }),
);
