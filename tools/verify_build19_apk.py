"""Inspect compiled Flutter strings and native call sites in a debug APK."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("apk", type=Path)
parser.add_argument("--dexdump", type=Path, required=True)
args = parser.parse_args()
print(f"apk={args.apk} bytes={args.apk.stat().st_size}")
print(f"sha256={hashlib.file_digest(args.apk.open('rb'), 'sha256').hexdigest()}")
with zipfile.ZipFile(args.apk) as apk:
    kernel = apk.read("assets/flutter_assets/kernel_blob.bin")
    for text in ["中国大陆账号", "扫一扫 → 从相册选择", "easysave/dev_log"]:
        offset = kernel.find(text.encode("utf-8"))
        assert offset >= 0, f"Missing compiled Flutter string: {text}"
        print(f"kernel_blob.bin UTF-8 {text!r}: FOUND offset={offset}")
    payload = json.loads(apk.read("assets/flutter_assets/assets/parser/builtin-manifest.json"))
    xhs = next(site for site in payload["sites"] if site["id"] == "xhs")
    assert "Mobile" not in xhs["auth"]["userAgent"]
    assert xhs["auth"]["userAgent"] == xhs["load"]["userAgent"]
    assert xhs["auth"]["loginUrl"] == "https://www.xiaohongshu.com/login"
    print("APK builtin XHS: desktop login UA == parsing UA; login path=/login")
    evidence = set()
    with tempfile.TemporaryDirectory(prefix="build19-dex-") as temporary:
        for name in apk.namelist():
            if not re.fullmatch(r"classes\d*\.dex", name):
                continue
            contents = apk.read(name)
            if b"com/james/easysave/" not in contents:
                continue
            dex = Path(temporary) / name
            dex.write_bytes(contents)
            process = subprocess.Popen([str(args.dexdump), "-d", str(dex)],
                                       stdout=subprocess.PIPE, text=True,
                                       encoding="utf-8", errors="replace")
            owner = ""
            for line in process.stdout:
                if "Class descriptor" in line:
                    owner = line.split("'", 2)[1]
                if not owner.startswith("Lcom/james/easysave/"):
                    continue
                match = (
                    (owner.endswith("/MainActivity;") or owner.endswith("/HostService;"))
                    and "invoke-" in line and "NativeLog;.register:" in line
                ) or (
                    owner.endswith("/NativeLog;") and any(term in line for term in [
                        "easysave/dev_log", "setMethodCallHandler:", "getFilesDir:",
                        "NativeLogFileWriter;.append:", "event=ready sink=",
                    ])
                ) or (
                    "SelectPanelView" in owner and "MediaPlayer;.setDataSource:(Ljava/lang/String;)V" in line
                )
                if match:
                    evidence.add((name, owner, line.strip()))
            assert process.wait() == 0, f"dexdump failed on {name}"
    for name, owner, instruction in sorted(evidence):
        print(f"{name} {owner} {instruction}")
    joined = "\n".join(str(row) for row in evidence)
    for required in ["/MainActivity;", "/HostService;", "easysave/dev_log",
                     "setMethodCallHandler:", "getFilesDir:", "NativeLogFileWriter;.append:",
                     "MediaPlayer;.setDataSource:(Ljava/lang/String;)V"]:
        assert required in joined, f"Missing APK call-site evidence: {required}"
print("PASS: compiled UI copy, both engine registrations, shared file sink and cached playback")
