// Runs one parser bundle the way an installed App does: EasySaveParser.moduleCall
// on the loaded page, with the App's own verified site definition.
//
// Used by the parser 1.4.17 compatibility tests on this branch and, unchanged,
// inside the v1.10.3 / v1.11.0 worktrees.
//
// usage: harness.mjs <bundle> <platform> <html> <url> <hook> [loggedIn:0|1] [errorCode] [errorMessage]
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const [bundlePath, platform, htmlPath, url, hook, loggedInFlag, errorCode, errorMessage] =
  process.argv.slice(2);
if (!bundlePath || !platform || !htmlPath || !url || !hook) {
  process.stderr.write(
    'usage: harness.mjs <bundle> <platform> <html> <url> <hook> [loggedIn:0|1] [errorCode] [errorMessage]\n',
  );
  process.exit(2);
}

const sites = JSON.parse(
  readFileSync(new URL('../../../config/sites.json', import.meta.url), 'utf8'),
);
const site = sites.find((entry) => entry.id === platform);
if (!site) throw new Error(`unknown platform ${platform}`);
const html = readFileSync(htmlPath, 'utf8');
const source = readFileSync(bundlePath, 'utf8');
const consoleLines = [];

/** The object literal assigned to `window.__INITIAL_STATE__`, if the page has one. */
function initialStateOf(page) {
  const marker = page.indexOf('__INITIAL_STATE__');
  if (marker < 0) return undefined;
  const start = page.indexOf('{', marker);
  if (start < 0) return undefined;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < page.length; i += 1) {
    const char = page[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') inString = true;
    else if (char === '{') depth += 1;
    else if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        try {
          return JSON.parse(page.slice(start, i + 1));
        } catch (_) {
          return undefined;
        }
      }
    }
  }
  return undefined;
}

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

const state = initialStateOf(html);
if (state !== undefined) page.__INITIAL_STATE__ = state;

vm.createContext(sandbox);
vm.runInContext(source, sandbox, { filename: bundlePath });
const parser = sandbox.EasySaveParser || page.EasySaveParser;
if (!parser || typeof parser.moduleCall !== 'function') {
  throw new Error('bundle did not define EasySaveParser.moduleCall');
}

const context = { url, site };
if (loggedInFlag === '1' || loggedInFlag === '0') context.loggedIn = loggedInFlag === '1';
if (errorCode) context.error = { code: errorCode, message: errorMessage ?? '' };

const raw = parser.moduleCall(platform, hook, context);
process.stdout.write(
  JSON.stringify({ console: consoleLines, value: JSON.parse(raw).value }),
);
