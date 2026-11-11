"""Verify the build 33 debug APK: embedded parser 1.4.14 / 10 and changed sources.

The debug APK keeps the Dart kernel, so every changed Dart file can be matched
byte-for-byte. The Kotlin side is checked by class/string markers in the dex.
"""
import hashlib
import json
from pathlib import Path
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]).resolve()
evidence = root / 'app/build/build33'
evidence.mkdir(parents=True, exist_ok=True)
report = {'apk': str(path), 'bytes': path.stat().st_size,
          'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
with zipfile.ZipFile(path) as apk:
    base = 'assets/flutter_assets/'
    manifest = json.loads(apk.read(base + 'assets/parser/builtin-manifest.json'))
    script = apk.read(base + 'assets/parser/parser.js')
    assert manifest['parserVersion'] == '1.4.14', manifest['parserVersion']
    assert manifest['manifestVersion'] == 10, manifest['manifestVersion']
    assert script == (root / 'app/assets/parser/parser.js').read_bytes()
    assert hashlib.sha256(script).hexdigest() == manifest['sha256']
    assert manifest == json.loads(
        (root / 'app/assets/parser/builtin-manifest.json').read_text(encoding='utf-8'))
    # The missing-token rule travels inside the signed manifest payload.
    xhs = next(site for site in manifest['sites'] if site['id'] == 'xhs')
    assert xhs['load']['accessTokenParams'] == ['xsec_token']
    rule = next(page for page in xhs['load']['terminalPages'] if page['category'] == '404')
    assert rule['missingTokenCode'] == 'TOKEN_REQUIRED'

    kernel = apk.read(base + 'kernel_blob.bin')
    report['embeddedSources'] = {}
    for name in ['services/history_db.dart', 'services/update_service.dart',
                 'services/parse_service.dart', 'services/site_registry.dart',
                 'services/gallery_locator_service.dart',
                 'services/parser_config_contract.dart',
                 'services/download_manager.dart', 'services/backup/backup_service.dart',
                 'background/background_entry.dart', 'core/error_copy.dart',
                 'core/models.dart', 'widgets/history_cards.dart',
                 'pages/main_shell.dart', 'pages/mine_page.dart', 'main.dart']:
        source = (root / 'app/lib' / name).read_bytes()
        offset = kernel.find(source)
        assert offset >= 0, f'APK source mismatch: {name}'
        report['embeddedSources'][name] = {
            'offset': offset, 'sha256': hashlib.sha256(source).hexdigest()}

    dex = b''.join(apk.read(n) for n in apk.namelist()
                   if n.startswith('classes') and n.endswith('.dex'))
    report['nativeMarkers'] = {}
    for marker in [b'savedMediaId', b'NativeLocalBitmap',
                   b'local preview unavailable, using network']:
        assert marker in dex, f'dex marker missing: {marker!r}'
        report['nativeMarkers'][marker.decode()] = True

    report['parserVersion'] = manifest['parserVersion']
    report['manifestVersion'] = manifest['manifestVersion']
    report['parserSha256'] = manifest['sha256']
(evidence / 'apk-verification.json').write_text(
    json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({k: v for k, v in report.items() if k != 'embeddedSources'},
                 ensure_ascii=False, indent=2))
print(f"embedded sources verified: {len(report['embeddedSources'])}")
