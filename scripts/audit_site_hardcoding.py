"""Reproduce the v1.10 platform-information inventory (stdlib only).

Run from any directory: python scripts/audit_site_hardcoding.py
Output is deterministic; this is a lexical inventory, not a claim of reachability.
"""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/tasks/v1.10-audit"
ROOTS = {
    "app/lib": {".dart"},
    "app/android/app/src/main": {".kt", ".xml", ".json"},
    "extension/src": {".ts", ".js"},
    "extension/entrypoints": {".ts"},
    "extension/public": {".json"},
    ".github/workflows": {".yml", ".yaml"},
}
EXTRA = [
    "extension/wxt.config.ts", "extension/scripts/build_release.js",
    "build_release.js", "config/sites.json", "config/parser-release.json",
    "app/assets/parser/builtin-manifest.json",
    "app/assets/parser/sites-manifest.schema.json",
]
PATTERN = (
    r"xiaohongshu|xhs|instagram|instagr[.]am|tiktok|twitter|rednote|douyin|"
    r"小红书|抖音|youtube|youtu[.]be|\bseal\b|SealMissing|SealInstalled|"
    r"sendToSeal|sealPackage|sealReleases|SEAL_|twimg|cdninstagram|fbcdn|xhscdn|"
    r"xsec_token|xsec_source|web_session|sessionid|auth_token|"
    r"(?<![A-Za-z0-9_])(?:x[.]com|t[.]co)(?![A-Za-z0-9_])|"
    r"""['"]x['"]|accounts[.]google[.](?:com|cn)"""
)
RX = re.compile(PATTERN, re.I)
GENERATED = {
    "app/lib/generated/builtin_sites.dart",
    "app/android/app/src/main/assets/link-recognition.json",
    "app/assets/parser/builtin-manifest.json",
    "app/assets/parser/sites-manifest.schema.json",
}
EXTERNAL = {
    "app/lib/services/links.dart", "app/lib/services/seal.dart",
    "app/lib/services/clipboard_guard.dart", "app/lib/pages/parse_page.dart",
    "app/lib/pages/batch_page.dart",
}
MEDIA = {
    "app/lib/services/download_manager.dart", "app/lib/services/saver.dart",
    "app/lib/services/preview_video.dart", "app/lib/services/session_media_download.dart",
}
LEGACY_TS = {
    "extension/src/index.ts", "extension/src/_utils.ts",
    "extension/src/manifest.ts", "extension/src/errors.ts",
}
def classify(path, text):
    stripped = text.strip()
    if stripped.startswith(("//", "/*", "*", "<!--", "import ", "export {", "export type")):
        return "词法候选", "注释、导入或符号声明；不独立执行站点数据规则。"
    if path in GENERATED:
        return "生成配置", "由 config/sites.json 与构建器生成；不是独立维护的平台表。"
    if path.startswith("config/"):
        return "清单源配置", "允许维护站点数据的源配置；parser-release 的 platforms/headers 是旧 ABI 兼容投影。"
    if path == "app/lib/widgets/shared.dart":
        return "内置图标资源", "本地 Material assetKey 注册表；清单只能选择已打包字形，不能加载远程图标。"
    if path in MEDIA:
        return "延期 2b-2（超类说明）", "重试/会话/Cookie/Referer/续传策略；用户明确禁止本轮改变下载和预览请求策略，须在 2b-2 连同逐请求授权一起迁移。"
    if path == "app/lib/services/update_service.dart":
        return "旧通道兼容代码", "旧 platforms/headers ABI 的 X 默认 endpoint/UA；v2 解析入口从 site.load 获取数据，本轮保留旧调用契约。"
    if path == "app/lib/services/login_navigation.dart":
        return "通用安全规则", "内嵌 WebView 的 Google OAuth 精确 host 判定，与站点无关；站点专用文案已入清单。"
    if path in EXTERNAL or path.endswith(("/ExternalHandlers.kt", "/MainActivity.kt", "/AndroidManifest.xml")):
        return "外部转交许可表", "YouTube 仅交给本地许可包 Seal；包括域/路径许可、包可见性、显式 Intent 及安装指引，不能由远程清单扩展为任意包。"
    if path.endswith(("/LogSanitizer.kt", "/dev_log.dart", "/background_entry.dart")):
        return "通用安全规则", "日志统一去除 query/凭据，不把脱敏边界交给站点清单。"
    if path in LEGACY_TS:
        return "旧通道兼容代码", "parse(input,pageUrl) 与扩展旧 manifest 协议入口/host 辅助/错误投影；不是 App v2 Registry 分派。"
    if path.startswith(("extension/entrypoints/", "extension/public/")) or path == "extension/wxt.config.ts":
        return "扩展旧通道与静态权限（超类说明）", "扩展仍消费冻结 v1 通道；内容脚本注入/host_permissions/DNR 属浏览器打包权限，App 清单不能提升；迁移需单独扩展协议与重新发行，且本轮不改请求策略。"
    if path.startswith("extension/src/"):
        return "签名解析模块算法（超类说明）", "站点 JSON/DOM 路径、ID/媒体算法、canonical 拼接及模块注册，属于签名 parser 的可执行实现；清单选择 parserModule，不执行任意配置 JS。"
    return "需人工核查", "尚无保留理由；必须在最终验收前处理。"

def main():
    files = set()
    scanned = {}
    for name, suffixes in ROOTS.items():
        folder = ROOT / name
        selected = sorted(p for p in folder.rglob("*") if p.is_file() and p.suffix in suffixes)
        files.update(selected)
        scanned[name] = len(selected)
    for name in EXTRA:
        p = ROOT / name
        if p.is_file():
            files.add(p)
    hits = []
    grouped = {}
    for p in sorted(files):
        relative = p.relative_to(ROOT).as_posix()
        for line, source in enumerate(p.read_text(encoding="utf-8-sig").splitlines(), 1):
            if not RX.search(source):
                continue
            category, reason = classify(relative, source)
            hits.append(dict(file=relative, line=line, source=source, category=category, reason=reason))
            entry = grouped.setdefault((relative, category, reason), [])
            entry.append(line)
    OUT.mkdir(parents=True, exist_ok=True)
    report = dict(pattern=PATTERN, scanned=scanned, extra=EXTRA,
        exclusions=["tests/fixtures", "generated parser bundles", "docs prose", "binary/icon assets"],
        hits=hits)
    (OUT / "hardcoded-hits.json").write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    rows = [
        "# v1.10 最终硬编码逐文件盘点", "",
        "生成命令：rtk proxy python scripts/audit_site_hardcoding.py。完整逐行源码与理由见 hardcoded-hits.json。",
        "本表是词法候选盘点；生成配置、注释/符号、算法与延期项不冒充四类获准保留项。详细范围和结论见 README.md。",
        "", "| 文件 | 行号 | 分类 | 每处保留理由 |", "|---|---|---|---|",
    ]
    for (path, category, reason), lines in sorted(grouped.items()):
        rows.append("| "+path+" | "+", ".join(map(str,lines))+" | "+category+" | "+reason+" |")
    rows += ["", "扫描文件数："+str(len(files))+"；命中行数："+str(len(hits))+"。", ""]
    (OUT / "hardcoded-inventory.md").write_text("\n".join(rows), encoding="utf-8")
    unresolved = [h for h in hits if h["category"] == "需人工核查"]
    print(json.dumps(dict(files=len(files), hits=len(hits), unresolved=unresolved),ensure_ascii=False))
    return 1 if unresolved else 0

if __name__ == "__main__":
    raise SystemExit(main())
