"""Verify delivered parser, Dart channel wiring and native DEX call sites."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]).resolve()
dexdump = sys.argv[2]
evidence = root / 'app/build/v1411'
evidence.mkdir(parents=True, exist_ok=True)
report = {'apk': str(path), 'bytes': path.stat().st_size,
          'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
with zipfile.ZipFile(path) as apk:
    base = 'assets/flutter_assets/'
    manifest = json.loads(apk.read(base + 'assets/parser/builtin-manifest.json'))
    script = apk.read(base + 'assets/parser/parser.js')
    assert manifest['parserVersion'] == '1.4.11'
    assert manifest['manifestVersion'] == 7
    assert script == (root / 'app/assets/parser/parser.js').read_bytes()
    assert hashlib.sha256(script).hexdigest() == manifest['sha256']
    assert manifest == json.loads((root / 'app/assets/parser/builtin-manifest.json').read_text(encoding='utf-8'))
    assert b'text: "AI content", source: "platform"' in script
    kernel = apk.read(base + 'kernel_blob.bin')
    report['embeddedSources'] = {}
    for name in ['background/background_entry.dart', 'services/ai_label_log.dart',
                 'services/media_request_policy.dart', 'services/parse_service.dart',
                 'services/download_manager.dart', 'services/history_db.dart',
                 'pages/parse_page.dart', 'pages/preview_page.dart', 'pages/history_page.dart',
                 'pages/download_queue_page.dart', 'widgets/history_cards.dart', 'pages/mine_page.dart', 'widgets/gallery_browser.dart', 'widgets/verified_asset_image.dart', 'widgets/download_sheet.dart', 'services/history_io.dart', 'services/gallery_locator_service.dart']:
        source = (root / 'app/lib' / name).read_bytes()
        offset = kernel.find(source)
        assert offset >= 0, f'APK source mismatch: {name}'
        report['embeddedSources'][name] = {'offset': offset, 'sha256': hashlib.sha256(source).hexdigest()}
    native_lines = []
    for name in apk.namelist():
        if not name.endswith('.dex'):
            continue
        dex = apk.read(name)
        if b'Lcom/james/easysave/SelectPanelView;' not in dex:
            continue
        extracted = evidence / name
        extracted.write_bytes(dex)
        result = subprocess.run([dexdump, '-d', str(extracted)], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, check=True)
        # Retain only our classes, keeping disassembled invoke instructions as evidence.
        keep = False
        for line in result.stdout.decode('utf-8', errors='replace').splitlines():
            if line.startswith('Class #'):
                keep = False
            if 'Class descriptor' in line:
                keep = any(c in line for c in ['Lcom/james/easysave/HostService',
                                               'Lcom/james/easysave/SelectPanelView',
                                               'Lcom/james/easysave/MainActivity',
                                               'Lcom/james/easysave/SafStorageBridge'])
            if keep:
                native_lines.append(line)
    native = '\n'.join(native_lines)
    preview = native.split("name          : 'loadImage'", 1)[1].split("name          :", 1)[0]
    assert 'NativeThumbBitmaps;.get:' in preview, 'fullscreen preview must reuse thumbnail bitmap'
    assert 'ImageView;.setImageBitmap:' in preview, 'fullscreen must paint the cached thumbnail'
    (evidence / 'native-panel-disassembly.txt').write_text(native, encoding='utf-8')
    calls = [line.strip() for line in native_lines if 'invoke-' in line and
             any(method in line for method in ['setPostMetadata:', 'setItems:', 'Landroid/view/WindowManager;.addView:'])]
    assert any('SelectPanelView;.setPostMetadata:' in line for line in calls), 'missing HostService -> native metadata call'
    assert any('SelectPanelView;.setItems:' in line for line in calls), 'missing real panel population'
    assert any('WindowManager;.addView:' in line for line in calls), 'missing real overlay attachment'
    assert 'postTitle' in native and 'aiLabel' in native, 'missing MethodChannel argument reads'
    assert 'AI 标注' in native and '平台识别' in native and '作者声明' in native
    assert 'SafStorageBridge$Companion;.register:' in native, 'background SAF registration absent'
    assert 'SafStorageBridge;.handle:' in native, 'foreground SAF storage dispatch absent'
    assert 'checkDirectoryAccess' in native and 'writeBackupToDirectory' in native
    assert 'BinaryMessenger;.makeBackgroundTaskQueue:' in native, 'SAF storage must run off the UI thread'
    report['nativeCallSites'] = calls
    report['parserVersion'] = manifest['parserVersion']
    report['manifestVersion'] = manifest['manifestVersion']
    report['parserSha256'] = manifest['sha256']
print(json.dumps(report, ensure_ascii=False, indent=2))
