import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import crypto from 'node:crypto';
import { validateSchema, validatePayload } from './sites_config.js';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
export function verifyRelease({ root = repository, downloadDirectory }) {
  const expected = resolve(root, 'extension/dist/release');
  const actualManifest = readFileSync(resolve(downloadDirectory, 'manifest.json'));
  const actualParser = readFileSync(resolve(downloadDirectory, 'parser.js'));
  if (!actualManifest.equals(readFileSync(resolve(expected, 'manifest.json'))) ||
      !actualParser.equals(readFileSync(resolve(expected, 'parser.js')))) {
    throw new Error('Release readback differs from the built artifacts');
  }
  const schema = JSON.parse(readFileSync(resolve(root, 'spec/sites-manifest.schema.json'), 'utf8'));
  const envelope = JSON.parse(actualManifest);
  validateSchema(envelope, schema, schema);
  const source = readFileSync(resolve(root, 'app/lib/services/update_service.dart'), 'utf8');
  const key = /kDefaultParserPublicKeyHex\s*=\s*'([a-f0-9]{64})'/.exec(source)?.[1];
  if (!key) throw new Error('Cannot read App public key');
  const publicKey = crypto.createPublicKey({ type: 'spki', format: 'der', key: Buffer.concat([
    Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(key, 'hex'),
  ]) });
  if (!crypto.verify(null, Buffer.from(envelope.payload, 'utf8'), publicKey, Buffer.from(envelope.signature, 'hex'))) {
    throw new Error('Invalid Release manifest signature');
  }
  const payload = JSON.parse(envelope.payload);
  validatePayload(payload, schema);
  if (crypto.createHash('sha256').update(actualParser).digest('hex') !== payload.sha256) {
    throw new Error('Release parser hash mismatch');
  }
  return payload;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 3) throw new Error('Provide the Release readback directory');
    verifyRelease({ downloadDirectory: resolve(process.argv[2]) });
    console.log('Release readback signature, bytes and hash verified');
  } catch (error) {
    console.error('Release verification refused: ' + error.message);
    process.exitCode = 1;
  }
}
