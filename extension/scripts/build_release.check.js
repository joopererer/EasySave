import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { buildRelease, createPayload } from './build_release.js';
import { verifyRelease } from './verify_release.js';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
function fixture(t) {
  const root = mkdtempSync(resolve(tmpdir(), 'easysave-v2-release-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const seed = privateKey.export({ format: 'der', type: 'pkcs8' }).subarray(-32).toString('hex');
  const pub = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('hex');
  for (const name of ['config/sites.json', 'config/parser-release.json', 'spec/sites-manifest.schema.json', 'spec/PARSER_VERSION']) {
    mkdirSync(dirname(resolve(root, name)), { recursive: true });
    writeFileSync(resolve(root, name), readFileSync(resolve(repo, name)));
  }
  for (const [name, value] of Object.entries({
    'app/lib/services/update_service.dart': "const kDefaultParserPublicKeyHex = '" + pub + "';",
    'app/assets/parser/parser.js': '/* parser test fixture */',
    'spec/manifest.json': 'frozen manifest', 'spec/parser.js': 'frozen parser',
  })) {
    mkdirSync(dirname(resolve(root, name)), { recursive: true });
    writeFileSync(resolve(root, name), value);
  }
  const payload = createPayload(root);
  for (const [name, value] of Object.entries({
    'app/assets/parser/builtin-manifest.json': JSON.stringify(payload),
    'app/assets/parser/sites-manifest.schema.json': readFileSync(resolve(root, 'spec/sites-manifest.schema.json')),
    'app/lib/generated/builtin_sites.dart': 'const builtinSitesJson = ' + JSON.stringify(JSON.stringify(payload.sites)) + ';',
    'app/android/app/src/main/assets/link-recognition.json': JSON.stringify({sites:payload.sites.filter(s=>s.enabled).map(s=>({id:s.id,routes:s.match.routes}))}),
  })) {
    mkdirSync(dirname(resolve(root, name)), { recursive: true });
    writeFileSync(resolve(root, name), value);
  }
  return { root, seed, publicKey };
}

for (const seed of [undefined, '', ' ', 'zz'.repeat(32), '01'.repeat(31), '01'.repeat(33)]) {
  test('invalid or missing signing key produces no artifacts: ' + String(seed?.length), (t) => {
    const { root } = fixture(t);
    assert.throws(() => buildRelease({ root, seed: seed ?? '' }), /64 hex/);
    assert.equal(existsSync(resolve(root, 'extension/dist')), false);
    assert.equal(readFileSync(resolve(root, 'spec/manifest.json'), 'utf8'), 'frozen manifest');
    assert.equal(readFileSync(resolve(root, 'spec/parser.js'), 'utf8'), 'frozen parser');
  });
}
test('wrong key is rejected before mkdir or overwriting prior artifacts', (t) => {
  const { root, seed } = fixture(t);
  const dist = resolve(root, 'extension/dist/release');
  mkdirSync(dist, { recursive: true });
  writeFileSync(resolve(dist, 'manifest.json'), 'prior output');
  assert.throws(() => buildRelease({ root, seed: (seed.startsWith('00') ? '01' : '00') + seed.slice(2) }), /public key/);
  assert.equal(readFileSync(resolve(dist, 'manifest.json'), 'utf8'), 'prior output');
  assert.equal(existsSync(resolve(dist, 'parser.js')), false);
});
test('valid signature covers the exact UTF-8 payload and binds parser bytes', (t) => {
  const { root, seed, publicKey } = fixture(t);
  const { envelope, payload, directory } = buildRelease({ root, seed });
  assert.equal(crypto.verify(null, Buffer.from(envelope.payload), publicKey, Buffer.from(envelope.signature, 'hex')), true);
  assert.equal(crypto.verify(null, Buffer.from(envelope.payload + ' '), publicKey, Buffer.from(envelope.signature, 'hex')), false);
  assert.equal(payload.sha256, crypto.createHash('sha256').update(readFileSync(resolve(directory, 'parser.js'))).digest('hex'));
  assert.match(payload.parserUrl, /\/releases\/download\/parser-v[0-9.]+\/parser\.js$/);
  assert.equal(payload.sites.length, 5);
  assert.equal(readFileSync(resolve(root, 'spec/manifest.json'), 'utf8'), 'frozen manifest');
  assert.equal(readFileSync(resolve(root, 'spec/parser.js'), 'utf8'), 'frozen parser');
});
test('candidate is unsigned and separate from release', (t) => {
  const { root } = fixture(t);
  const { envelope, directory } = buildRelease({ root, candidate: true, seed: 'invalid' });
  assert.equal(Object.hasOwn(envelope, 'signature'), false);
  assert.equal(directory, resolve(root, 'extension/dist/candidate'));
  assert.equal(existsSync(resolve(root, 'extension/dist/release')), false);
});

for (const name of ['app/assets/parser/builtin-manifest.json',
  'app/android/app/src/main/assets/link-recognition.json',
  'app/assets/parser/sites-manifest.schema.json', 'app/lib/generated/builtin_sites.dart']) {
  test('release refuses divergent APK configuration: ' + name, (t) => {
    const { root } = fixture(t);
    writeFileSync(resolve(root, name), name.endsWith('.dart') ? 'const builtinSitesJson = "[]";' : '{}');
    assert.throws(() => buildRelease({ root, candidate: true }));
    assert.equal(existsSync(resolve(root, 'extension/dist')), false);
  });
}
test('only manifest/parser version metadata may differ from builtin configuration', (t) => {
  const { root } = fixture(t);
  const file = resolve(root, 'app/assets/parser/builtin-manifest.json');
  const builtin = JSON.parse(readFileSync(file));
  builtin.parserVersion = '0.0.1'; builtin.manifestVersion = 1;
  writeFileSync(file, JSON.stringify(builtin));
  assert.doesNotThrow(() => buildRelease({ root, candidate: true }));
});
test('configuration errors cannot create signed artifacts', (t) => {
  const { root, seed } = fixture(t);
  const path = resolve(root, 'config/sites.json');
  const sites = JSON.parse(readFileSync(path));
  sites[0].download.headers.Cookie = 'forbidden';
  writeFileSync(path, JSON.stringify(sites));
  assert.throws(() => buildRelease({ root, seed }), /Invalid manifest/);
  assert.equal(existsSync(resolve(root, 'extension/dist')), false);
});

test('canonical templates must be unchanged by actual provenance_dart before output', (t) => {
  const { root, seed } = fixture(t);
  const path = resolve(root, 'config/sites.json');
  const sites = JSON.parse(readFileSync(path));
  sites[1].normalize.canonicalTemplate = 'https://www.instagram.com/reel/{id}/';
  writeFileSync(path, JSON.stringify(sites));
  assert.throws(() => buildRelease({ root, seed }), /canonicalTemplate/);
  assert.equal(existsSync(resolve(root, 'extension/dist')), false);
});
test('CLI missing-key failure has nonzero status', () => {
  const env = { ...process.env };
  delete env.PARSER_SIGNING_KEY;
  const result = spawnSync(process.execPath, [resolve(repo, 'extension/scripts/build_release.js')], { env, encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /PARSER_SIGNING_KEY/);
});

test('frozen v1.2.4 channel bytes remain unchanged', () => {
  for (const [name, hash] of Object.entries({
    'spec/manifest.json': '7e04cdf8d489b9f03482884fe5da0d23f92465415a95d3af4d1766408101912b',
    'spec/parser.js': 'db469d347e2ffd54264ac0ac88f74ca935dfe60df14d57241e043d9e04b42a66',
  })) assert.equal(crypto.createHash('sha256').update(readFileSync(resolve(repo, name))).digest('hex'), hash);
});

test('APK-bundled manifest is generated from current configuration and parser bytes', () => {
  assert.equal(readFileSync(resolve(repo, 'app/assets/parser/builtin-manifest.json'), 'utf8'), JSON.stringify(createPayload(repo)));
});

test('Dart registry and Kotlin fallback view are generated from the same builtin sites', () => {
  const sites = createPayload(repo).sites;
  const view = JSON.parse(readFileSync(resolve(repo, 'app/android/app/src/main/assets/link-recognition.json')));
  assert.deepEqual(view, { sites: sites.filter((s) => s.enabled).map((s) => ({ id: s.id, routes: s.match.routes })) });
  const source = readFileSync(resolve(repo, 'app/lib/generated/builtin_sites.dart'), 'utf8');
  const literal = source.split('const builtinSitesJson = ')[1].trim().slice(0, -1).replaceAll('\\$', '$');
  assert.deepEqual(JSON.parse(JSON.parse(literal)), sites);
});

test('shared signature vector covers UTF-8 payload verbatim', () => {
  const vector = JSON.parse(readFileSync(resolve(repo, 'spec/test-vectors/parser-manifest-v2.json')));
  const pub = crypto.createPublicKey({ type: 'spki', format: 'der', key: Buffer.concat([
    Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(vector.publicKeyHex, 'hex'),
  ]) });
  assert.equal(crypto.verify(null, Buffer.from(vector.envelope.payload), pub, Buffer.from(vector.envelope.signature, 'hex')), true);
});

test('readback verification accepts matching signed artifacts and rejects changed bytes', (t) => {
  const { root, seed } = fixture(t);
  const { directory } = buildRelease({ root, seed });
  const downloaded = resolve(root, 'downloaded');
  mkdirSync(downloaded);
  for (const name of ['manifest.json', 'parser.js']) writeFileSync(resolve(downloaded, name), readFileSync(resolve(directory, name)));
  assert.equal(verifyRelease({ root, downloadDirectory: downloaded }).manifestVersion, 4);
  writeFileSync(resolve(downloaded, 'parser.js'), 'unexpected parser bytes');
  assert.throws(() => verifyRelease({ root, downloadDirectory: downloaded }), /differs/);
  writeFileSync(resolve(downloaded, 'parser.js'), readFileSync(resolve(directory, 'parser.js')));
  writeFileSync(resolve(downloaded, 'manifest.json'), readFileSync(resolve(directory, 'manifest.json'), 'utf8') + ' ');
  assert.throws(() => verifyRelease({ root, downloadDirectory: downloaded }), /differs/);
});

test('readback verifies signature and hash even if both local and remote are changed', (t) => {
  const { root, seed } = fixture(t);
  const { directory, envelope } = buildRelease({ root, seed });
  envelope.signature = '0'.repeat(128);
  writeFileSync(resolve(directory, 'manifest.json'), JSON.stringify(envelope));
  assert.throws(() => verifyRelease({ root, downloadDirectory: directory }), /signature/);
  buildRelease({ root, seed });
  writeFileSync(resolve(directory, 'parser.js'), 'changed');
  assert.throws(() => verifyRelease({ root, downloadDirectory: directory }), /hash/);
});

test('unknown header fields cannot bypass closed schema through inherited names', (t) => {
  const { root, seed } = fixture(t);
  const path = resolve(root, 'config/sites.json');
  const sites = JSON.parse(readFileSync(path));
  sites[0].download.headers.toString = 'forbidden';
  writeFileSync(path, JSON.stringify(sites));
  assert.throws(() => buildRelease({ root, seed }), /Invalid manifest/);
});

test('workflow publishes channel only after upload and readback; release jobs never cancel each other', () => {
  const workflow = readFileSync(resolve(repo, '.github/workflows/release_parser.yml'), 'utf8');
  const steps = ['Run all tests', 'Require signing key', 'Build and sign v2 release',
    'Upload Release attachments', 'Read back and verify Release attachments', 'Commit v2 channel manifest to master'];
  const positions = steps.map((s) => workflow.indexOf('name: ' + s));
  assert.equal(positions.every((p, i) => p >= 0 && (i === 0 || p > positions[i - 1])), true);
  assert.match(workflow, /cancel-in-progress: false/);
  assert.match(workflow, /overwrite_files: false/);
  assert.match(workflow, /git add spec\/v2\/manifest\.json/);
  assert.match(workflow, /git worktree add --detach/);
  assert.match(workflow, /readFileSync\(process\.env\.PARSER_BUILT_MANIFEST\)/);
  assert.doesNotMatch(workflow, /git checkout -B master/);
  assert.doesNotMatch(workflow, /git add spec\/manifest\.json|always\(\)|continue-on-error/);
});

test('resource defaults cannot widen cookies or inject headers', async () => {
  const { validatePayload } = await import('./sites_config.js');
  const schema = JSON.parse(readFileSync(resolve(repo, 'spec/sites-manifest.schema.json'), 'utf8'));
  for (const invalid of [
    { headers: { Cookie: 'secret' } },
    { headers: { Referer: 'bad\r\nvalue' } },
    { cookieDomains: ['com'] },
    { cookieDomains: ['instagram.com'] },
  ]) {
    const payload = createPayload();
    payload.sites.find(s => s.id === 'tiktok').download.resourceDefaults.image = invalid;
    assert.throws(() => validatePayload(payload, schema));
  }
});

test('channel worktree stays clean when dependency resolution changes the tagged checkout lockfile', () => {
  // Retained in the test temp root for diagnostics; no real remote or branch is touched.
  const root = mkdtempSync(resolve(tmpdir(), 'easysave-v2-channel-worktree-'));
  const source = resolve(root, 'source');
  const channel = resolve(root, 'channel');
  mkdirSync(source);
  const git = (cwd, ...args) => {
    const result = spawnSync('git', args, {cwd,encoding:'utf8'});
    assert.equal(result.status,0,result.stderr);
    return result.stdout.trim();
  };
  git(source,'init','--initial-branch=channel-base');
  git(source,'config','user.name','Release Test');
  git(source,'config','user.email','release-test@example.invalid');
  mkdirSync(resolve(source,'app'));
  writeFileSync(resolve(source,'app/pubspec.lock'),'locked baseline\n');
  git(source,'add','app/pubspec.lock');
  git(source,'commit','-m','fixture baseline');
  const baseline = git(source,'rev-parse','HEAD');
  writeFileSync(resolve(source,'app/pubspec.lock'),'changed by dependency resolution\n');
  git(source,'worktree','add','--detach',channel,'channel-base');
  assert.equal(git(channel,'status','--porcelain'),'');
  mkdirSync(resolve(channel,'spec/v2'),{recursive:true});
  writeFileSync(resolve(channel,'spec/v2/manifest.json'),'signed-envelope-fixture\n');
  git(channel,'add','spec/v2/manifest.json');
  git(channel,'commit','-m','fixture channel manifest');
  assert.equal(git(channel,'diff','--name-only',baseline,'HEAD'),'spec/v2/manifest.json');
  assert.equal(readFileSync(resolve(source,'app/pubspec.lock'),'utf8'),'changed by dependency resolution\n');
});
