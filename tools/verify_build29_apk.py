"""Verify the build 29 APK: embedded parser 1.4.12 / manifest 8 and Dart sources."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]).resolve()
evidence = root / 'app/build/v1412'
evidence.mkdir(parents=True, exist_ok=True)
report = {'apk': str(path), 'bytes': path.stat().st_size,
          'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
with zipfile.ZipFile(path) as apk:
    base = 'assets/flutter_assets/'
    manifest = json.loads(apk.read(base + 'assets/parser/builtin-manifest.json'))
    script = apk.read(base + 'assets/parser/parser.js')
    assert manifest['parserVersion'] == '1.4.12'
    assert manifest['manifestVersion'] == 8
    assert script == (root / 'app/assets/parser/parser.js').read_bytes()
    assert hashlib.sha256(script).hexdigest() == manifest['sha256']
    assert manifest == json.loads((root / 'app/assets/parser/builtin-manifest.json').read_text(encoding='utf-8'))
    x = next(site for site in manifest['sites'] if site['id'] == 'x')
    assert x['load']['entryTemplate'] == 'https://x.com/i/status/{id}'
    for marker in [b'__easysaveXGraphql', b'TweetResultByRestId', b'NsfwViewerHasNoStatedAge',
                   b'XhsStreamProbe', b'XProbe', b'audioChannels']:
        assert marker in script, f'parser marker missing: {marker!r}'
    kernel = apk.read(base + 'kernel_blob.bin')
    report['embeddedSources'] = {}
    for name in ['background/background_entry.dart', 'services/gallery_locator_service.dart',
                 'pages/history_page.dart', 'widgets/history_masonry.dart',
                 'services/parse_service.dart', 'services/auth.dart',
                 'services/download_manager.dart', 'services/mp4_audio_probe.dart',
                 'core/error_copy.dart', 'core/models.dart']:
        source = (root / 'app/lib' / name).read_bytes()
        offset = kernel.find(source)
        assert offset >= 0, f'APK source mismatch: {name}'
        report['embeddedSources'][name] = {'offset': offset, 'sha256': hashlib.sha256(source).hexdigest()}
    report['parserVersion'] = manifest['parserVersion']
    report['manifestVersion'] = manifest['manifestVersion']
    report['parserSha256'] = manifest['sha256']
(evidence / 'apk-verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(report, ensure_ascii=False, indent=2))
