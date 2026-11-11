"""Verify the build 33 release APK: embedded parser and shipped string markers.

Release builds run R8, so class names are renamed; the checks use the string
literals that survive (they are the behaviour-bearing ones) and the APK assets.
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
    assert manifest['parserVersion'] == '1.4.14'
    assert manifest['manifestVersion'] == 10
    assert hashlib.sha256(script).hexdigest() == manifest['sha256']
    assert script == (root / 'app/assets/parser/parser.js').read_bytes()

    lib = apk.read([n for n in apk.namelist() if n.endswith('libapp.so')][0])
    dex = b''.join(apk.read(n) for n in apk.namelist()
                   if n.startswith('classes') and n.endswith('.dex'))
    markers = {
        # Dart AOT stores non-ASCII literals as UTF-16LE.
        'token_required_copy': '\u94fe\u63a5\u7f3a\u5c11\u8bbf\u95ee\u4ee4\u724c'.encode('utf-16-le'),
        'check_log': b'event=check trigger=',
        'session_log': b'event=session stream=',
        'cleanup_log': b'file rows cleaned source=migration',
        'merge_log': b'kept=',
    }
    report['dartMarkers'] = {k: (v in lib) for k, v in markers.items()}
    assert all(report['dartMarkers'].values()), report['dartMarkers']
    # `savedMediaId` is a method-channel map key, so R8 keeps the literal.
    assert b'savedMediaId' in dex
    report['dexMarkers'] = {'savedMediaId': True}
    report['parserVersion'] = manifest['parserVersion']
    report['manifestVersion'] = manifest['manifestVersion']
    report['parserSha256'] = manifest['sha256']
(evidence / 'apk-verification-release.json').write_text(
    json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(report, ensure_ascii=False, indent=2))
