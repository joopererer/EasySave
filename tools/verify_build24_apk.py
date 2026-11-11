"""Inspect the delivered build 24's real views, worker dispatch and bitmap cache."""
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
with args.apk.open('rb') as stream:
    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
print(f'apk={args.apk} bytes={args.apk.stat().st_size} sha256={digest}')
with zipfile.ZipFile(args.apk) as apk:
    kernel = apk.read('assets/flutter_assets/kernel_blob.bin')
    for symbol in ['PreviewPage', 'CoverImage', 'CdnImage', '_LimitedCodec',
                   'thumbnailVisibleBegin', 'thumbnailVisibleEnd', 'thumbnailVisible',
                   'thumbnailPrefetchIdle', '_prefetchSlots', '_validationSlots',
                   '_prefetchValidationSlots', 'waitMs=', 'ioMs=', 'queue=', 'cacheIdentity', 'thumbnailDirectory', 'thumbnailReady', 'validateThumbnailHeader', 'writeThumbnailFile', 'thread=bg', 'bytes=', 'THUMBNAIL_WRITE_ON_MAIN_ISOLATE']:
        offset = kernel.find(symbol.encode())
        assert offset >= 0, f'Missing kernel symbol: {symbol}'
        print(f'kernel {symbol!r} offset={offset}')
    assert b'thumbnailWrite' not in kernel, 'Legacy byte channel still bundled'
    manifest = json.loads(apk.read('assets/flutter_assets/assets/parser/builtin-manifest.json'))
    assert manifest['parserVersion'] == '1.4.5'
    assert hashlib.sha256(apk.read('assets/flutter_assets/assets/parser/parser.js')).hexdigest() == manifest['sha256']
    print('parser version: 1.4.5, script hash verified')
    output = Path('app/build/build24-apk-dex').resolve()
    output.mkdir(parents=True, exist_ok=True)
    print(f'DEX retained at {output}; no directories removed')
    required = {
        'OrientedBitmap;': ['ExifInterface;.<init>:', 'ExifInterface;.getAttributeInt:', 'Matrix;.setValues:', 'Bitmap;.createBitmap:', 'Looper;.myLooper:'],
        'MainActivity;': ['BinaryMessenger;.makeBackgroundTaskQueue:'],
        'ProvenancePairWriter;': ['BinaryMessenger;.makeBackgroundTaskQueue:'],
        'SelectPanelView;': ['NativeThumbBitmaps;.get:', 'NativeThumbBitmaps;.put:',
                             'NativeThumbBitmaps;.getDecoders:', 'NativeMediaRequest;.imageAsync:',
                             'ScrollView;.<init>:', 'ImageView;.setImageBitmap:',
                             'OrientedBitmap;.decode:'],
        'SharedPreviewBridge;': ['ThumbnailQueues;.read:', 'ThumbnailQueues;.readInfo:',
                                 'ThumbnailQueues;.prefetchReadInfo:',
                                 'ThumbnailQueues;.write:', 'TaskQueueOptions;.setIsSerial:',
                                 'BinaryMessenger;.makeBackgroundTaskQueue:',
                                 'ThumbnailVisibility;.begin:', 'ThumbnailVisibility;.end:'],
        'NativeMediaRequest;': ['SharedPreviewBridge;.imageAsync:'],
        'NativeThumbBitmaps;': ['ThumbnailMemory;.<init>:', 'ThumbnailMemory;.get:',
                               'ThumbnailMemory;.put:', 'ActivityManager;.getMemoryClass:'],
        'NativeLog;': ['ExecutorService;.execute:', 'BinaryMessenger;.makeBackgroundTaskQueue:'],
        'DownloadControl;': ['BinaryMessenger;.makeBackgroundTaskQueue:'],
        'ThumbnailQueues;': ['ExecutorService;.execute:', 'Executors;.newFixedThreadPool:',
                             'Executors;.newSingleThreadExecutor:'],
    }
    found = set()
    forced_log_sync = False
    for name in apk.namelist():
        if not re.fullmatch(r'classes\d*\.dex', name):
            continue
        contents = apk.read(name)
        if b'com/james/easysave/' not in contents:
            continue
        path = output / name
        path.write_bytes(contents)
        process = subprocess.Popen([str(args.dexdump), '-d', str(path)], stdout=subprocess.PIPE,
                                   text=True, encoding='utf-8', errors='replace')
        owner = ''
        for line in process.stdout:
            if 'Class descriptor' in line:
                owner = line.split("'", 2)[1]
            if 'invoke-' not in line:
                continue
            if owner == 'Lcom/james/easysave/NativeLogFileWriter;' and 'FileDescriptor;.sync:' in line:
                forced_log_sync = True
            for suffix, terms in required.items():
                if owner != f'Lcom/james/easysave/{suffix}':
                    continue
                for term in terms:
                    pair = (suffix, term)
                    if term in line and pair not in found:
                        found.add(pair)
                        print(f'{name} {owner} {line.strip()}')
        assert process.wait() == 0
    for owner, terms in required.items():
        for term in terms:
            assert (owner, term) in found, f'Missing actual compiled call: {owner} -> {term}'
    assert not forced_log_sync, 'Diagnostic writer still forces fsync per line'
print('PASS: real CoverImage and panel, file-only thumbnail channel, header workers, EXIF-aware native decode and background bulk-data channels')
