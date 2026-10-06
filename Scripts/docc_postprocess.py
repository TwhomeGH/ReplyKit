"""DocC 靜態站後處理。

用途（CI 內、在 `docc process-archive transform-for-static-hosting` 之後執行）：
1. 修正 hosting base path：DocC 轉出的 SPA 可能仍以根目錄參照資產（`baseUrl = "/"`、
   `src="/js/..."`），在多模組子路徑託管時會 404 而頁面空白；此時補上 `/<base>/<module>/` 前綴。
2. 產生根目錄 `index.html`，列出各模組連結。

以 `python Scripts/docc_postprocess.py --site site --base ReplyKit` 執行。
"""

import argparse
import re
from pathlib import Path

# SPA 外殼中以根目錄參照的資產路徑；命中的 `="/<key>` 會補上模組前綴。
_ROOT_ASSET = re.compile(r'="/(js/|css/|favicon|index\.json|metadata\.json|data/)')

HOME = """<!doctype html>
<html lang="zh-Hant"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ReplyKit 文件</title>
<style>
body{{font:15px/1.7 -apple-system,"Segoe UI","Microsoft JhengHei",sans-serif;
max-width:760px;margin:56px auto;padding:0 24px;color:#111827;background:#fff}}
a{{color:#2563eb}} code{{background:#f3f4f6;padding:2px 6px;border-radius:6px}}
li{{margin:6px 0}} h2{{margin-top:1.6em}} .muted{{color:#6b7280;font-size:13px}}
</style>
</head><body>
<h1>ReplyKit 文件</h1>
<p>由 <code>xcodebuild docbuild</code> 產生的 DocC 模組文件：</p>
<ul>
{links}</ul>
<h2>回饋與社群</h2>
<ul>
<li><a href="https://discord.com/invite/jud4UE6wuq">Discord 群</a>：問題回報與討論</li>
<li><a href="https://www.twitch.tv/coffeelatte0709">Twitch 直播</a>：開發／遊戲追蹤</li>
</ul>
<p class="muted">遇到問題時，附上執行環境與相關資訊有助於回報與排查。</p>
</body></html>
"""


def module_dirs(site):
    """site/ 下的模組目錄（排除隱藏檔）。"""
    return sorted(p for p in site.iterdir() if p.is_dir() and not p.name.startswith("."))


def patch_base_path(site, base):
    """若 SPA 外殼仍以根目錄參照資產，補上 /<base>/<module>/ 前綴；回傳修正檔數。"""
    patched = 0
    for module in module_dirs(site):
        prefix = "/%s/%s/" % (base, module.name)
        for html in module.rglob("index.html"):
            text = html.read_text(encoding="utf-8")
            if 'baseUrl = "/"' not in text:
                continue
            text = text.replace('baseUrl = "/"', 'baseUrl = "%s"' % prefix)
            text = _ROOT_ASSET.sub(lambda m: '="%s%s' % (prefix, m.group(1)), text)
            html.write_text(text, encoding="utf-8")
            patched += 1
    return patched


def write_home(site):
    """產生根目錄首頁，列出各模組。"""
    modules = [m.name for m in module_dirs(site)]
    links = "".join('<li><a href="./%s/">%s</a></li>\n' % (m, m) for m in modules)
    (site / "index.html").write_text(HOME.format(links=links), encoding="utf-8")
    return modules


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", required=True, help="轉出的站台目錄")
    parser.add_argument("--base", required=True, help="Pages 的 repo 子路徑（如 ReplyKit）")
    args = parser.parse_args()

    site = Path(args.site)
    patched = patch_base_path(site, args.base)
    modules = write_home(site)
    print("base-path patched %d html；模組：%s" % (patched, ", ".join(modules) or "<none>"))


if __name__ == "__main__":
    main()
