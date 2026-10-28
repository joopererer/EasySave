"""Extract a minimal, sanitized photo fixture from an anonymously fetched page.

Usage: python create_tiktok_photo_fixture.py path/to/photo_canonical.html
Never fetches a page, reads cookies, or overwrites an existing fixture.
"""
import json
import re
import sys
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit

page = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r'<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>',
    page, re.S,
)
detail = json.loads(match[1])["__DEFAULT_SCOPE__"]["webapp.video-detail"]
assert detail["statusCode"] == 0
source = detail["itemInfo"]["itemStruct"]
assert source["id"] == "7688352288666045718"
item = {key: source[key] for key in ("id", "desc", "createTime") if key in source}
item["author"] = {key: source["author"][key] for key in ("id", "nickname")}
item["imagePost"] = {}
if "title" in source["imagePost"]:
    item["imagePost"]["title"] = source["imagePost"]["title"]
images = []
counter = 0
for image in source["imagePost"]["images"]:
    urls = []
    for raw in image["imageURL"]["urlList"]:
        counter += 1
        query = urlencode([(key, "FAKE") for key, _ in parse_qsl(urlsplit(raw).query)])
        urls.append(f"https://media.example/FAKE_{counter}.jpg" + (f"?{query}" if query else ""))
    images.append({"imageWidth": image["imageWidth"], "imageHeight": image["imageHeight"],
                   "imageURL": {"urlList": urls}})
item["imagePost"]["images"] = images
root = {"__DEFAULT_SCOPE__": {"webapp.video-detail": {
    "statusCode": 0, "itemInfo": {"itemStruct": item}}}}
text = '<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">\n'
text += json.dumps(root, ensure_ascii=False, indent=2) + '\n</script>\n'
assert not re.search(r"cookie|csrfToken|encryptedWebid", text, re.I)
target = Path(__file__).resolve().parents[2] / "spec/fixtures/tiktok/photo.html"
with target.open("x", encoding="utf-8", newline="\n") as output:
    output.write(text)
print(f"Created minimal fixture: {len(images)} images, {counter} sanitized URLs")
