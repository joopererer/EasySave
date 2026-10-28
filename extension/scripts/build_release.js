import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import crypto from 'node:crypto';
import { validatePayload } from './sites_config.js';
import { validateCanonicalTemplates } from './validate_canonical.js';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const json = (path) => JSON.parse(readFileSync(path, 'utf8'));

export function createPayload(root = repository) {
  const { parserUrlTemplate, ...settings } = json(resolve(root, 'config/parser-release.json'));
  const parserVersion = readFileSync(resolve(root, 'spec/PARSER_VERSION'), 'utf8').trim();
  const parser = readFileSync(resolve(root, 'app/assets/parser/parser.js'));
  return { ...settings, parserVersion,
    parserUrl: parserUrlTemplate.replaceAll('{parserVersion}', parserVersion),
    sha256: crypto.createHash('sha256').update(parser).digest('hex'),
    sites: json(resolve(root, 'config/sites.json')) };
}

export function signingKey(seed, publicKeyHex) {
  if (!/^[a-fA-F0-9]{64}$/.test(seed ?? '')) {
    throw new Error('PARSER_SIGNING_KEY must contain exactly 64 hex characters');
  }
  const key = crypto.createPrivateKey({
    key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.from(seed, 'hex')]),
    type: 'pkcs8', format: 'der',
  });
  const actual = crypto.createPublicKey(key).export({ type: 'spki', format: 'der' }).subarray(-32).toString('hex');
  if (actual !== publicKeyHex) throw new Error('Signing key does not match the App public key');
  return key;
}

// No writes (including mkdir) occur until the key, inputs and complete output validate.
export function buildRelease({ root = repository, candidate = false, seed = process.env.PARSER_SIGNING_KEY } = {}) {
  const appSource = readFileSync(resolve(root, 'app/lib/services/update_service.dart'), 'utf8');
  const publicKey = /kDefaultParserPublicKeyHex\s*=\s*'([a-f0-9]{64})'/.exec(appSource)?.[1];
  if (!publicKey) throw new Error('Cannot read App public key');
  const key = candidate ? null : signingKey(seed, publicKey);
  const payloadObject = createPayload(root);
  const { parserVersion } = payloadObject;
  if (process.env.GITHUB_REF_TYPE === 'tag' && process.env.GITHUB_REF_NAME !== 'parser-v' + parserVersion) {
    throw new Error('Release tag must match spec/PARSER_VERSION');
  }
  const parser = readFileSync(resolve(root, 'app/assets/parser/parser.js'));
  validatePayload(payloadObject, json(resolve(root, 'spec/sites-manifest.schema.json')));
  validateCanonicalTemplates(payloadObject.sites);
  const payload = JSON.stringify(payloadObject);
  const envelope = { schemaVersion: 2, payload };
  // Candidates deliberately have no signature field and are never accepted by the App.
  if (key) envelope.signature = crypto.sign(null, Buffer.from(payload, 'utf8'), key).toString('hex');
  const directory = resolve(root, candidate ? 'extension/dist/candidate' : 'extension/dist/release');
  mkdirSync(directory, { recursive: true });
  writeFileSync(resolve(directory, 'parser.js'), parser);
  writeFileSync(resolve(directory, 'manifest.json'), JSON.stringify(envelope, null, 2) + '\n');
  return { directory, envelope, payload: payloadObject };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const flags = process.argv.slice(2);
    if (flags.some((flag) => flag !== '--candidate')) throw new Error('Unknown release option');
    const { directory } = buildRelease({ candidate: flags.includes('--candidate') });
    console.log('Parser artifact generated: ' + directory);
  } catch (error) {
    console.error('Parser release refused: ' + error.message);
    process.exitCode = 1;
  }
}
