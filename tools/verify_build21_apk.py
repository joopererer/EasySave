"""Inspect build 21 compiled history widget and shared-cache call sites."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('apk', type=Path)
parser.add_argument('--dexdump', type=Path, required=True)
args = parser.parse_args()
with args.apk.open('rb') as source:
    digest = hashlib.file_digest(source, 'sha256').hexdigest()
print(f'apk={args.apk} bytes={args.apk.stat().st_size} sha256={digest}')
with zipfile.ZipFile(args.apk) as apk:
    kernel = apk.read('assets/flutter_assets/kernel_blob.bin')
    for text in ['canonical-platform-filter', 'lookupParsed', 'ParseCache', 'ThumbCache',
                 'cachePostId', 'cacheItemIndex', 'canonicalId', 'sameSite']:
        offset = kernel.find(text.encode('utf-8'))
        assert offset >= 0, f'Missing compiled widget/cache symbol: {text}'
        print(f'kernel_blob.bin UTF-8 {text!r}: FOUND offset={offset}')
    payload = json.loads(apk.read('assets/flutter_assets/assets/parser/builtin-manifest.json'))
    assert payload['parserVersion'] == '1.4.3'
    sites = {site['id']: site for site in payload['sites']}
    assert 'rednote' in sites['xhs']['aliases']
    assert 'twitter' in sites['x']['aliases']
    print('APK builtin parserVersion=1.4.3; xhs/rednote and x/twitter aliases present')
    for slug in ['xiaohongshu', 'instagram', 'x', 'tiktok']:
        contents = apk.read(f'assets/flutter_assets/assets/brands/{slug}.svg')
        assert contents == Path(f'app/assets/brands/{slug}.svg').read_bytes()
    print('four brand vectors still match bundled sources')
    required = ['ParsedHandoff;.lookup:', 'ParsedHandoff;.put:',
                'SharedPreviewBridge;.register', 'ThumbnailFiles;.read:', 'ThumbnailFiles;.write:']
    evidence = set()
    temporary_root = Path('app/build').resolve()
    with tempfile.TemporaryDirectory(prefix='build21-apk-dex-', dir=temporary_root) as directory:
        assert Path(directory).resolve().is_relative_to(temporary_root)
        print(f'temporary DEX directory (removed after verification): {directory}')
        for name in apk.namelist():
            if not re.fullmatch(r'classes\d*\.dex', name):
                continue
            contents = apk.read(name)
            if b'com/james/easysave/' not in contents:
                continue
            path = Path(directory) / name
            path.write_bytes(contents)
            process = subprocess.Popen([str(args.dexdump), '-d', str(path)], stdout=subprocess.PIPE,
                                       text=True, encoding='utf-8', errors='replace')
            owner = ''
            for line in process.stdout:
                if 'Class descriptor' in line:
                    owner = line.split("'", 2)[1]
                if owner.startswith('Lcom/james/easysave/') and 'invoke-' in line and any(term in line for term in required):
                    evidence.add((name, owner, line.strip()))
            assert process.wait() == 0
    for row in sorted(evidence):
        print(' '.join(row))
    combined = '\n'.join(str(row) for row in evidence)
    for term in required:
        assert term in combined, f'Missing compiled call: {term}'
    for owner in ['/MainActivity;', '/HostService;']:
        assert any(owner in row[1] and 'SharedPreviewBridge;.register' in row[2] for row in evidence)
print('PASS: actual history menu marker, stable identities, bidirectional native RAM cache and shared thumbnails')
