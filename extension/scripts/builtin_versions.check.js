import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkBuiltinVersions } from './check_builtin_versions.js';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');

function copyFixture(t) {
  const root = mkdtempSync(resolve(tmpdir(), 'easysave-builtin-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const parser = readFileSync(resolve(repo, 'app/assets/parser/parser.js'));
  const release = JSON.parse(readFileSync(resolve(repo, 'config/parser-release.json'), 'utf8'));
  const parserVersion = readFileSync(resolve(repo, 'spec/PARSER_VERSION'), 'utf8').trim();
  const manifest = {
    ...JSON.parse(readFileSync(resolve(repo, 'app/assets/parser/builtin-manifest.json'), 'utf8')),
    manifestVersion: release.manifestVersion,
    parserVersion,
    sha256: crypto.createHash('sha256').update(parser).digest('hex'),
    parserUrl: release.parserUrlTemplate.replaceAll('{parserVersion}', parserVersion),
  };
  const files = {
    'config/parser-release.json': JSON.stringify(release),
    'spec/PARSER_VERSION': parserVersion + '\n',
    'app/assets/parser/parser.js': parser,
    'app/assets/parser/builtin-manifest.json': JSON.stringify(manifest),
    'app/lib/generated/parser_version.dart':
      `// GENERATED FILE - DO NOT EDIT\nclass ParserVersion {\n  static const String version = '${parserVersion}';\n}\n`,
  };
  for (const [name, value] of Object.entries(files)) {
    mkdirSync(dirname(resolve(root, name)), { recursive: true });
    writeFileSync(resolve(root, name), value);
  }
  return { root, manifest, parser };
}

test('the repository bundle matches config/parser-release.json and spec/PARSER_VERSION', () => {
  const result = checkBuiltinVersions(repo);
  assert.equal(result.manifestVersion, JSON.parse(readFileSync(resolve(repo, 'config/parser-release.json'), 'utf8')).manifestVersion);
  assert.equal(result.parserVersion, readFileSync(resolve(repo, 'spec/PARSER_VERSION'), 'utf8').trim());
});

test('an outdated manifestVersion in the bundled manifest fails the check', (t) => {
  const { root, manifest } = copyFixture(t);
  writeFileSync(resolve(root, 'app/assets/parser/builtin-manifest.json'),
    JSON.stringify({ ...manifest, manifestVersion: manifest.manifestVersion - 1 }));
  assert.throws(() => checkBuiltinVersions(root), /manifestVersion/);
});

test('an outdated parserVersion in the bundled manifest fails the check', (t) => {
  const { root, manifest } = copyFixture(t);
  writeFileSync(resolve(root, 'app/assets/parser/builtin-manifest.json'),
    JSON.stringify({ ...manifest, parserVersion: '0.0.1' }));
  assert.throws(() => checkBuiltinVersions(root), /parserVersion/);
});

test('a parser.js whose sha256 no longer matches the manifest fails the check', (t) => {
  const { root } = copyFixture(t);
  writeFileSync(resolve(root, 'app/assets/parser/parser.js'), '/* rebuilt but manifest not regenerated */');
  assert.throws(() => checkBuiltinVersions(root), /sha256/);
});

test('a stale generated parser_version.dart fails the check', (t) => {
  const { root } = copyFixture(t);
  writeFileSync(resolve(root, 'app/lib/generated/parser_version.dart'),
    "// GENERATED FILE - DO NOT EDIT\nclass ParserVersion {\n  static const String version = '0.0.1';\n}\n");
  assert.throws(() => checkBuiltinVersions(root), /parser_version\.dart/);
});
