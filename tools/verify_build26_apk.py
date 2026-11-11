"""Inspect the delivered APK and tie its real widget code to tested sources."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1])
with path.open('rb') as stream:
    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
report = {'apk': str(path), 'bytes': path.stat().st_size, 'sha256': digest}
with zipfile.ZipFile(path) as apk:
    base = 'assets/flutter_assets/'
    manifest = json.loads(apk.read(base + 'assets/parser/builtin-manifest.json'))
    script = apk.read(base + 'assets/parser/parser.js')
    assert manifest['parserVersion'] == '1.4.9'
    assert manifest['manifestVersion'] == 5
    assert hashlib.sha256(script).hexdigest() == manifest['sha256']
    assert script == (root / 'app/assets/parser/parser.js').read_bytes()
    assert manifest == json.loads((root / 'app/assets/parser/builtin-manifest.json').read_text())
    kernel = apk.read(base + 'kernel_blob.bin')
    symbols = ['PreviewPage', 'GalleryBrowserPage', 'GalleryBrowserItem',
               'fromMediaItem', 'toMediaItem', 'thumbnailUrl', 'cacheIdentity',
               'networkPreviewController', 'AiLabelBadge', 'WaterfallPostCard',
               'resources.count', 'hostClass=', 'IgAiProbe']
    report['kernelSymbols'] = {}
    for symbol in symbols:
        offset = kernel.find(symbol.encode())
        assert offset >= 0, symbol
        report['kernelSymbols'][symbol] = offset
    # Debug kernel embeds library sources. Verify the modified real widgets and
    # policy/bridge are these exact sources, alongside their compiled symbols.
    files = ['widgets/gallery_browser.dart', 'pages/preview_page.dart',
             'pages/parse_page.dart', 'pages/history_page.dart',
             'services/ai_label_log.dart', 'services/media_request_policy.dart']
    report['embeddedSources'] = {}
    for name in files:
        source = (root / 'app/lib' / name).read_bytes()
        offset = kernel.find(source)
        assert offset >= 0, f'APK source mismatch: {name}'
        report['embeddedSources'][name] = offset
    report['parserVersion'] = manifest['parserVersion']
    report['manifestVersion'] = manifest['manifestVersion']
    report['parserSha256'] = manifest['sha256']
print(json.dumps(report, ensure_ascii=False, indent=2))
