"""Extract allowlisted minimal, anonymized fixtures from anonymous HTML captures.

Usage: python extension/scripts/create_ai_label_fixtures.py
Existing fixtures are never overwritten. No HTML, headers or cookies are copied.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'spec/fixtures/ai-label'
OUT.mkdir(exist_ok=True)


def save(name, value):
    with (OUT / (name + '.json')).open('x', encoding='utf-8') as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
        f.write('\n')


def find_note(value):
    if isinstance(value, dict):
        if value.get('noteId') and isinstance(value.get('imageList'), list):
            return value
        for child in value.values():
            found = find_note(child)
            if found:
                return found
    if isinstance(value, list):
        for child in value:
            found = find_note(child)
            if found:
                return found


for kind in ('platform', 'author', 'normal'):
    html = (ROOT / f'app/ai_xhs_{kind}.tmp.html').read_text(encoding='utf-8')
    raw = re.search(r'window\.__INITIAL_STATE__\s*=\s*(.*?)</script>', html, re.S)[1]
    # JS undefined outside strings only.
    raw = re.sub(r'"(?:\\.|[^"\\])*"|\bundefined\b',
                 lambda m: 'null' if m[0] == 'undefined' else m[0], raw)
    note = find_note(json.loads(raw.rstrip(';')))
    assert note is not None
    desc = note.get('illegalInfo', {}).get('desc')
    minimal = {'noteId': '000000000000000000000001',
               'imageList': [{'urlDefault': 'https://example.invalid/FAKE.jpg'}]}
    if desc is not None:
        minimal['illegalInfo'] = {'desc': desc}
    save('xhs-' + kind, {'note': {'noteDetailMap': {
        minimal['noteId']: {'note': minimal}}}})
    print('xhs', kind, json.dumps(desc, ensure_ascii=True))

for kind, path in (
    ('platform', Path('D:/temp/tiktok_research/post_ai_platform.html')),
    ('author', ROOT / 'app/ai_tiktok_author.tmp.html'),
):
    html = path.read_text(encoding='utf-8')
    raw = re.search(r'<script\b[^>]*\bid="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>', html, re.S)[1]
    scope = json.loads(raw)['__DEFAULT_SCOPE__']
    detail = scope.get('webapp.video-detail', scope.get('webapp.reflow.video.detail'))
    item = detail['itemInfo']['itemStruct']
    label = item['aigcLabelType']
    save('tiktok-' + kind, {'__DEFAULT_SCOPE__': {'webapp.video-detail': {
        'statusCode': 0, 'itemInfo': {'itemStruct': {
            'id': '1234567890123456789', 'aigcLabelType': label,
            'video': {'playAddr': 'https://example.invalid/FAKE.mp4'}}}}}})
    print('tiktok', kind, label)
