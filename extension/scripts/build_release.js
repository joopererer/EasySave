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

const sha256Hex = crypto.createHash('sha256').update(parserBytes).digest('hex');

// 2. Sign with Ed25519 if private key is provided in env
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
    const sig = crypto.sign(null, parserBytes, privKeyObj);
    signatureHex = sig.toString('hex');
    console.log(`Successfully signed parser.js with Ed25519 (signature length: ${signatureHex.length / 2} bytes)`);
  } catch (err) {
    console.error('Error signing parser release:', err.message);
    process.exit(1);
  }
} else {
  console.warn('WARNING: PARSER_SIGNING_KEY not set. Generating release with empty signature for dry-run.');
}

// 3. Generate manifest.json
const manifest = {
  parserVersion: version,
  minAppVersion: '1.0.0',
  sha256: sha256Hex,
  signature: signatureHex,
  platforms: {
    xhs: {
      enabled: true,
      notice: '小红书解析服务维护中，请稍后再试',
    },
    instagram: {
      enabled: true,
      notice: 'Instagram 解析服务维护中，请稍后再试',
    },
  },
  headers: {
    xhs: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    },
    instagram: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    },
  },
};

writeFileSync(manifestOutFile, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
console.log(`Generated manifest: ${manifestOutFile}`);

const specManifestFile = resolve(rootDir, 'spec', 'manifest.json');
writeFileSync(specManifestFile, JSON.stringify(manifest, null, 2) + '\n', 'utf8');
console.log(`Updated spec manifest: ${specManifestFile}`);
console.log(`Bundle SHA256: ${sha256Hex}`);
