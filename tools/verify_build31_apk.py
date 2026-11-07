"""Verify the build 31 APK: parser 1.4.12 / 8, backup v2 sources, native bridge."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]).resolve()
evidence = root / 'app/build/build31'
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
    kernel = apk.read(base + 'kernel_blob.bin')
    report['embeddedSources'] = {}
    for name in ['services/backup/backup_service.dart', 'services/backup/backup_model.dart',
                 'services/backup/backup_restore_matcher.dart', 'services/backup/saf_service.dart',
                 'services/history_db.dart', 'metadata/url_normalizer.dart',
                 'services/clipboard_guard.dart',
                 'widgets/history_cards.dart',
                 'pages/history_page.dart']:
        source = (root / 'app/lib' / name).read_bytes()
        offset = kernel.find(source)
        assert offset >= 0, f'APK source mismatch: {name}'
        report['embeddedSources'][name] = {'offset': offset, 'sha256': hashlib.sha256(source).hexdigest()}
    dex = b''.join(apk.read(n) for n in apk.namelist() if n.endswith('.dex'))
    for marker in [b'Lcom/james/easysave/MediaStoreBridge;',
                   b'Lcom/james/easysave/MediaStoreBridge$Companion;', b'savedMediaIndex', b'storageInfo',
                   b'mediaSize', b'mediaSizes', b'READ_MEDIA_VISUAL_USER_SELECTED', b'owner_package_name']:
        assert marker in dex, f'native marker missing: {marker!r}'
    report['nativeMarkers'] = 'MediaStoreBridge savedMediaIndex storageInfo mediaSize mediaSizes'
    report['parserVersion'] = manifest['parserVersion']
    report['manifestVersion'] = manifest['manifestVersion']
    report['parserSha256'] = manifest['sha256']
(evidence / 'apk-verification.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(report, ensure_ascii=False, indent=2))
