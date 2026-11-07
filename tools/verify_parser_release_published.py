"""Verify the published parser release and the v2 channel manifest.

Checks, without needing a local `extension/dist`:
  * the Ed25519 signature against the App public key,
  * parserVersion / manifestVersion / sha256 of the published parser,
  * the published payload equals the manifest embedded in the App, and
  * master's spec/v2/manifest.json carries the same bytes.

Usage: python tools/verify_parser_release_published.py 1.4.14
"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

root = Path(__file__).resolve().parents[1]
version = sys.argv[1]
repo = 'joopererer/EasySave'
out = root / 'app' / 'build' / ('parser' + version.replace('.', ''))
out.mkdir(parents=True, exist_ok=True)

subprocess.run(['gh', 'release', 'download', 'parser-v' + version, '--repo', repo,
                '--pattern', 'manifest.json', '--pattern', 'parser.js',
                '--dir', str(out)], check=True)
channel = subprocess.run(['gh', 'api', f'repos/{repo}/contents/spec/v2/manifest.json?ref=master',
                          '-H', 'Accept: application/vnd.github.raw+json'],
                         stdout=subprocess.PIPE, check=True).stdout

manifest_bytes = (out / 'manifest.json').read_bytes()
parser_bytes = (out / 'parser.js').read_bytes()
assert manifest_bytes == channel, 'master channel manifest differs from the release asset'

envelope = json.loads(manifest_bytes)
assert envelope['schemaVersion'] == 2
payload = json.loads(envelope['payload'])

source = (root / 'app/lib/services/update_service.dart').read_text(encoding='utf-8')
key = __import__('re').search(r"kDefaultParserPublicKeyHex\s*=\s*'([a-f0-9]{64})'", source).group(1)
try:
    Ed25519PublicKey.from_public_bytes(bytes.fromhex(key)).verify(
        bytes.fromhex(envelope['signature']), envelope['payload'].encode('utf-8'))
except InvalidSignature:
    raise SystemExit('Invalid release signature')

assert payload['parserVersion'] == version, payload['parserVersion']
assert hashlib.sha256(parser_bytes).hexdigest() == payload['sha256']
embedded = json.loads((root / 'app/assets/parser/builtin-manifest.json').read_text(encoding='utf-8'))
assert payload == embedded, 'published payload differs from the App builtin manifest'

xhs = next(site for site in payload['sites'] if site['id'] == 'xhs')
rule = next(page for page in xhs['load']['terminalPages'] if page['category'] == '404')

report = {
    'tag': 'parser-v' + version,
    'manifestBytes': len(manifest_bytes),
    'manifestSha256': hashlib.sha256(manifest_bytes).hexdigest(),
    'parserBytes': len(parser_bytes),
    'parserSha256': payload['sha256'],
    'parserVersion': payload['parserVersion'],
    'manifestVersion': payload['manifestVersion'],
    'accessTokenParams': xhs['load']['accessTokenParams'],
    'missingTokenCode': rule['missingTokenCode'],
    'channelMatchesRelease': True,
    'payloadMatchesAppBuiltin': True,
    'signatureValid': True,
}
(out / 'verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(report, ensure_ascii=False, indent=2))
