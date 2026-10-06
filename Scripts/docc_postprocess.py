"""DocC 靜態站後處理。

用途（CI 內、在 `docc process-archive transform-for-static-hosting` 之後執行）：
1. 修正 hosting base path：DocC 轉出的 SPA 可能仍以根目錄參照資產（`baseUrl = "/"`、
   `src="/js/..."`），在多模組子路徑託管時會 404 而頁面空白；此時補上 `/<base>/<module>/` 前綴。
2. 模組根目錄轉址：每個模組 archive 的內容頁在 `<module>/documentation/<topic>/`，
   直接開 `<module>/` 會顯示「找不到頁面」；把 `<module>/index.html` 改寫為轉址到內容頁。
3. 產生根目錄 `index.html`，列出各模組連結。

以 `python Scripts/docc_postprocess.py --site site --base ReplyKit` 執行。
"""

import argparse
import re
from pathlib import Path

# SPA 外殼中以根目錄參照的資產路徑；命中的 `="/<key>` 會補上模組前綴。
_ROOT_ASSET = re.compile(r'="/(js/|css/|favicon|index\.json|metadata\.json|data/)')

# 首頁模板（純 HTML 檔，不寫死在程式或 workflow 裡）與模組清單佔位符。
DEFAULT_TEMPLATE = Path(__file__).resolve().parent / "docc_home.html"
MODULE_PLACEHOLDER = "{{module_list}}"


def module_dirs(site):
    """site/ 下的模組目錄（排除隱藏檔）。"""
    return sorted(p for p in site.iterdir() if p.is_dir() and not p.name.startswith("."))


def module_topic(module_dir):
    """回傳模組內唯一的文件目錄名（如 `liveapp`），沒有則 None。

    DocC 的內容路由是 `documentation/<模組小寫名>`；一個模組 archive 只會有一個。
    """
    docdir = module_dir / "documentation"
    if not docdir.is_dir():
        return None
    topics = sorted(p.name for p in docdir.iterdir() if p.is_dir())
    return topics[0] if topics else None


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


def write_module_redirects(site):
    """把每個模組的 index.html 改為轉址到 <module>/documentation/<topic>/。

    回傳「有內容」的模組名（沒有文件的模組不會列入首頁）。
    """
    modules = []
    for module in module_dirs(site):
        topic = module_topic(module)
        if not topic:
            continue
        modules.append(module.name)
        (module / "index.html").write_text(
            '<!doctype html><meta charset="utf-8">'
            '<meta http-equiv="refresh" content="0; url=./documentation/%s/">'
            '<link rel="canonical" href="./documentation/%s/">'
            "<title>%s</title>" % (topic, topic, module.name),
            encoding="utf-8",
        )
    return modules


def write_home(site, modules, template_path=DEFAULT_TEMPLATE):
    """以模板產生根目錄首頁，列出各模組。"""
    links = "".join('<li><a href="./%s/">%s</a></li>' % (m, m) for m in modules)
    template = Path(template_path).read_text(encoding="utf-8")
    (site / "index.html").write_text(template.replace(MODULE_PLACEHOLDER, links), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", required=True, help="轉出的站台目錄")
    parser.add_argument("--base", required=True, help="Pages 的 repo 子路徑（如 ReplyKit）")
    parser.add_argument("--template", default=str(DEFAULT_TEMPLATE), help="首頁模板 HTML")
    args = parser.parse_args()

    site = Path(args.site)
    patched = patch_base_path(site, args.base)
    modules = write_module_redirects(site)
    write_home(site, modules, args.template)
    print("base-path patched %d html；模組：%s" % (patched, ", ".join(modules) or "<none>"))


if __name__ == "__main__":
    main()
