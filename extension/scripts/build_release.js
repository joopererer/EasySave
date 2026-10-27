import esbuild from 'esbuild';
import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { dirname, resolve } from 'path';
import { fileURLToPath } from 'url';
import crypto from 'crypto';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const rootDir = resolve(__dirname, '..', '..');
const versionPath = resolve(rootDir, 'spec', 'PARSER_VERSION');
const version = readFileSync(versionPath, 'utf8').trim();

const distDir = resolve(__dirname, '..', 'dist');
mkdirSync(distDir, { recursive: true });

const parserOutFile = resolve(distDir, 'parser.js');
const manifestOutFile = resolve(distDir, 'manifest.json');

// 1. Copy committed parser.js for release (matches committed app/assets/parser/parser.js)
const appParserFile = resolve(rootDir, 'app', 'assets', 'parser', 'parser.js');
const parserBytes = readFileSync(appParserFile);
writeFileSync(parserOutFile, parserBytes);
writeFileSync(resolve(rootDir, 'spec', 'parser.js'), parserBytes);

const sha256Hex = crypto.createHash('sha256').update(parserBytes).digest('hex');

// 2. Prepare manifest structure
const manifest = {
  parserVersion: version,
  minAppVersion: '1.9.0',
  sha256: sha256Hex,
  signature: '',
  platforms: {
    tiktok: {
      enabled: true,
      notice: 'TikTok 解析服务维护中，请稍后再试',
    },
    xhs: {
      enabled: true,
      notice: '小红书解析服务维护中，请稍后再试',
    },
    instagram: {
      enabled: true,
      notice: 'Instagram 解析服务维护中，请稍后再试',
    },
    x: {
      enabled: true,
      notice: 'X 解析服务维护中，请稍后再试',
      endpoint: 'https://cdn.syndication.twimg.com/tweet-result?id={id}&lang=en&token={token}',
    },
  },
  headers: {
    tiktok: {
      Referer: 'https://www.tiktok.com/',
    },
    xhs: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    },
    instagram: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    },
    x: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    },
  },
};

export function canonicalizeManifest(val) {
  function sortObj(v) {
    if (v === null || typeof v !== 'object' || Array.isArray(v)) return v;
    const sorted = {};
    for (const key of Object.keys(v).sort()) {
      if (key === 'signature') continue;
      sorted[key] = sortObj(v[key]);
    }
    return sorted;
  }
  return JSON.stringify(sortObj(val));
}

const canonicalManifestString = canonicalizeManifest(manifest);
const canonicalBytes = Buffer.from(canonicalManifestString, 'utf8');

// 3. Sign canonical manifest with Ed25519 if private key is provided in env
let signatureHex = '';
const privateKeyHex = (process.env.PARSER_SIGNING_KEY || '').trim();

if (privateKeyHex) {
  try {
    const rawKey = Buffer.from(privateKeyHex, 'hex');
    if (rawKey.length !== 32) {
      throw new Error(`Invalid private key length: expected 32 bytes (64 hex chars), got ${rawKey.length} bytes`);
    }
    // PKCS8 header for Ed25519 private key: 302e020100300506032b657004220420
    const pkcs8Key = Buffer.concat([
      Buffer.from('302e020100300506032b657004220420', 'hex'),
      rawKey,
    ]);
    const privKeyObj = crypto.createPrivateKey({
      key: pkcs8Key,
      format: 'der',
      type: 'pkcs8',
    });
    const sig = crypto.sign(null, canonicalBytes, privKeyObj);
    signatureHex = sig.toString('hex');
    manifest.signature = signatureHex;
    console.log(`Successfully signed canonical manifest with Ed25519 (signature length: ${signatureHex.length / 2} bytes)`);
  } catch (err) {
    console.error('Error signing parser release:', err.message);
    process.exit(1);
  }
} else {
  console.warn('WARNING: PARSER_SIGNING_KEY not set. Generating release with empty signature for dry-run.');
}

writeFileSync(manifestOutFile, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
console.log(`Generated manifest: ${manifestOutFile}`);

const specManifestFile = resolve(rootDir, 'spec', 'manifest.json');
writeFileSync(specManifestFile, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
console.log(`Updated spec manifest: ${specManifestFile}`);
console.log(`Bundle SHA256: ${sha256Hex}`);
