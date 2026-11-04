"""Verify build 20 compiled UI, bundled brand vectors and native execution paths."""
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
    for value in ['清空日志', '确认清空', '清空链接', 'clear-link-input',
                  'easysave/shared_preview', 'assets/brands/', 'SharedParse']:
        offset = kernel.find(value.encode('utf-8'))
        assert offset >= 0, value
        print(f'kernel_blob.bin UTF-8 {value!r}: FOUND offset={offset}')
    for name in ['xiaohongshu', 'instagram', 'x', 'tiktok']:
        path = f'assets/flutter_assets/assets/brands/{name}.svg'
        contents = apk.read(path)
        assert contents == Path(f'app/assets/brands/{name}.svg').read_bytes()
        print(f'{path}: MATCH source bytes={len(contents)} sha256={hashlib.sha256(contents).hexdigest()}')
    assert apk.read('assets/flutter_assets/assets/brands/LICENSE.md')
    manifest = json.loads(apk.read('assets/flutter_assets/assets/parser/builtin-manifest.json'))
    assert manifest['parserVersion'] == '1.4.2'
    print('builtin parserVersion=1.4.2; brand license bundled')
    for name in apk.namelist():
        if name.startswith('META-INF/') and 'media3' in name and name.endswith('.version'):
            value = apk.read(name).decode().strip()
            assert value == '1.9.2', (name, value)
            print(f'{name}: {value}')
    terms = ['DefaultRenderersFactory;.setEnableDecoderFallback:',
             'ExoPlayer$Builder;.build:', 'PreviewSessions;.accepts:',
             'PreviewSessions;.close:', 'SharedPreviewBridge;.register',
             'ThumbnailFiles;.write:', 'PreviewSessionsKt;.holdCountdown:',
             'PreviewSessionsKt;.parsingDotOffsets:', 'Canvas;.drawRoundRect:',
             'Uri;.fromFile:', 'Player;.clearVideoSurface:', 'Player;.release:']
    evidence = set()
    temporary_root = Path('app/build').resolve()
    with tempfile.TemporaryDirectory(prefix='build20-apk-dex-', dir=temporary_root) as directory:
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
                if not owner.startswith('Lcom/james/easysave/') or 'invoke-' not in line:
                    continue
                if 'SelectPanelView' in owner:
                    assert 'Landroid/media/MediaPlayer;' not in line, 'Legacy MediaPlayer remains active'
                if any(term in line for term in terms):
                    evidence.add((name, owner, line.strip()))
            assert process.wait() == 0
    for row in sorted(evidence):
        print(' '.join(row))
    combined = '\n'.join(str(row) for row in evidence)
    for required in terms:
        assert required in combined, f'Missing compiled call: {required}'
    for owner in ['/MainActivity;', '/HostService;']:
        assert any(owner in row[1] and 'SharedPreviewBridge;.register' in row[2] for row in evidence)
print('PASS: compiled UI, four exact brand assets, Media3 fallback/session cleanup, cache bridge, countdown and dots')
