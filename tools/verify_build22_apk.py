"""Verify build 22 preview/cache changes in the delivered debug APK."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
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
    for symbol in ['PreviewPage', 'CoverImage', 'CdnImage', '_LimitedCodec',
                   'ThumbnailSlots', 'thumbnailAcquire', 'thumbnailRelease',
                   'thumbnailDelete', 'thumbnailPrefetchAllowed', 'ThumbLoad',
                   'THUMBNAIL_TRUNCATED', 'fullResolution', 'getTargetSize',
                   '加载失败，点击重试']:
        offset = kernel.find(symbol.encode('utf-8'))
        assert offset >= 0, f'Missing compiled widget/cache symbol: {symbol}'
        print(f'kernel symbol {symbol!r}: FOUND offset={offset}')
    manifest = json.loads(apk.read('assets/flutter_assets/assets/parser/builtin-manifest.json'))
    assert manifest['parserVersion'] == '1.4.4'
    script = apk.read('assets/flutter_assets/assets/parser/parser.js')
    assert hashlib.sha256(script).hexdigest() == manifest['sha256']
    print('bundled parserVersion=1.4.4; parser.js hash matches manifest')
    output = Path('app/build/build22-apk-dex').resolve()
    output.mkdir(parents=True, exist_ok=True)
    print(f'DEX evidence retained at {output}; no directories removed')
    calls = set()
    live = False
    for name in apk.namelist():
        if not re.fullmatch(r'classes\d*\.dex', name):
            continue
        data = apk.read(name)
        if b'com/james/easysave/' not in data:
            continue
        path = output / name
        path.write_bytes(data)
        process = subprocess.Popen([str(args.dexdump), '-d', str(path)], stdout=subprocess.PIPE,
                                   text=True, encoding='utf-8', errors='replace')
        owner = ''
        for line in process.stdout:
            if 'Class descriptor' in line:
                owner = line.split("'", 2)[1]
            if not owner.startswith('Lcom/james/easysave/'):
                continue
            if 'SelectPanelView' in owner and 'const-string' in line and '"LIVE"' in line:
                live = True
                print(f'{name} {owner} {line.strip()}')
            terms = ['ScrollView;.<init>:', 'ScrollView;.addView:', 'getGlobalVisibleRect:',
                     'makeBackgroundTaskQueue:', 'thumbnailValid:', 'thumbnailContainerComplete:',
                     'ThumbnailFiles;.read:', 'ThumbnailFiles;.write:', 'ThumbnailFiles;.remove:',
                     'SharedPreviewBridge;.register', 'BitmapFactory;.decodeFile:']
            if 'invoke-' in line:
                for term in terms:
                    if term in line:
                        calls.add(term)
                        print(f'{name} {owner} {line.strip()}')
        assert process.wait() == 0
    for term in ['ScrollView;.<init>:', 'ScrollView;.addView:', 'getGlobalVisibleRect:',
                 'makeBackgroundTaskQueue:', 'thumbnailValid:', 'thumbnailContainerComplete:',
                 'ThumbnailFiles;.read:', 'ThumbnailFiles;.write:', 'ThumbnailFiles;.remove:',
                 'SharedPreviewBridge;.register', 'BitmapFactory;.decodeFile:']:
        assert term in calls, f'Missing compiled invocation: {term}'
    assert live, 'Actual SelectPanelView is missing its LIVE badge'
print('PASS: compiled real preview widgets, native scroll/LIVE, background I/O and shared cache entry points')
