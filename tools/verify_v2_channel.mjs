// Independent, public-key-only verification of downloaded Release and channel bytes.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { validateSchema, validatePayload } from '../extension/scripts/sites_config.js';

const [directory, channelFile, parserVersion, versionText] = process.argv.slice(2);
assert(directory && channelFile && parserVersion && versionText,
  'Usage: node tools/verify_v2_channel.mjs <release-dir> <master-manifest> <parser-version> <manifest-version>');
const keyHex = 'ca4f1c302d00220e32178d2e9b47fd589dffc38e8c9711fe93327a44aa199ded';
const source = readFileSync('app/lib/services/update_service.dart', 'utf8');
assert(source.includes(keyHex), 'Expected public key must match App source');
const key = crypto.createPublicKey({type:'spki',format:'der',key:Buffer.concat([
  Buffer.from('302a300506032b6570032100','hex'),Buffer.from(keyHex,'hex')])});
const schema = JSON.parse(readFileSync('spec/sites-manifest.schema.json','utf8'));
const releaseBytes = readFileSync(resolve(directory,'manifest.json'));
const masterBytes = readFileSync(channelFile);
assert(releaseBytes.equals(masterBytes), 'Master channel differs from Release envelope bytes');
const parserBytes = readFileSync(resolve(directory,'parser.js'));
const parserHash = crypto.createHash('sha256').update(parserBytes).digest('hex');
const expectedUrl = `https://github.com/joopererer/EasySave/releases/download/parser-v${parserVersion}/parser.js`;
for (const [name, bytes] of [['Release',releaseBytes],['master',masterBytes]]) {
  const envelope = JSON.parse(bytes.toString('utf8'));
  validateSchema(envelope,schema,schema);
  assert(crypto.verify(null,Buffer.from(envelope.payload,'utf8'),key,
    Buffer.from(envelope.signature,'hex')), `${name}: Ed25519 signature rejected`);
  const payload = JSON.parse(envelope.payload);
  validatePayload(payload,schema);
  assert.equal(payload.manifestVersion,Number(versionText));
  assert.equal(payload.parserVersion,parserVersion);
  assert.equal(payload.parserUrl,expectedUrl);
  assert.equal(payload.sha256,parserHash);
  console.log(`${name}: PASS Ed25519(payload bytes), SHA-256, parserUrl, versions`);
}
console.log(`manifestVersion=${versionText} parserVersion=${parserVersion}`);
console.log(`parserSha256=${parserHash}`);
console.log(`parserUrl=${expectedUrl}`);
