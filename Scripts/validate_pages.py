#!/usr/bin/env python3
"""驗證 DocC + ChangeLogKit 的 Pages 產物。

檢查項目：
- DocC 根首頁、ChangeLogKit 首頁與 development 入口存在。
- 根首頁有連到 ./project/。
- project/ 內沒有以 / 開頭的內部 asset/link（子路徑會 404）。
- project/ 內相對 .html/.css/.js 連結都有對應檔案或目錄 index.html。
- ChangeLogKit 的分類文件至少產生一份 ChangeHistory 頁。

用法：python3 Scripts/validate_pages.py --site site --base ReplyKit
"""

import argparse
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

LINK = re.compile(r'(?:href|src)="([^"]*)"')
EXTERNAL = ("http://", "https://", "mailto:", "data:", "javascript:")
REQUIRED = (
    "index.html",
    "project/index.html",
    "project/development/index.html",
)


def target_exists(base: Path, target: Path) -> bool:
    if target.exists():
        return True
    if target.suffix == "":
        if (target / "index.html").is_file():
            return True
        if target.with_suffix(".html").is_file():
            return True
    return False


def validate(site: Path) -> list[str]:
    errors: list[str] = []
    for relative in REQUIRED:
        if not (site / relative).is_file():
            errors.append("缺少產物：%s" % relative)

    project = site / "project"
    if not project.is_dir():
        return errors + ["缺少 project/ 目錄"]

    root_index = site / "index.html"
    if root_index.is_file() and 'href="./project/"' not in root_index.read_text(encoding="utf-8"):
        errors.append("根首頁沒有連到 ./project/")

    for html in project.rglob("*.html"):
        text = html.read_text(encoding="utf-8", errors="replace")
        for raw in LINK.findall(text):
            if not raw or raw.startswith("#") or raw.startswith("?"):
                continue
            if raw.startswith("/"):
                errors.append("%s 使用根路徑連結：%s" % (html.relative_to(site), raw))
                continue
            if raw.startswith(EXTERNAL):
                continue
            parsed = urlsplit(unquote(raw))
            if not parsed.path:
                continue
            target = (html.parent / parsed.path).resolve()
            try:
                target.relative_to(site.resolve())
            except ValueError:
                errors.append("%s 連結超出站台：%s" % (html.relative_to(site), raw))
                continue
            if not target_exists(site, target):
                errors.append("%s 連結不存在：%s" % (html.relative_to(site), raw))

    if not list(project.rglob("ChangeHistory.html")):
        errors.append("project/ 沒有產生 ChangeHistory 頁")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site", required=True, help="Pages 站台目錄")
    parser.add_argument("--base", default="", help="repo 子路徑；只供訊息顯示")
    args = parser.parse_args()
    site = Path(args.site).resolve()
    if not site.is_dir():
        print("站台目錄不存在：%s" % args.site, file=sys.stderr)
        return 2
    errors = validate(site)
    if errors:
        print("Pages 驗證失敗（%d 項）：" % len(errors), file=sys.stderr)
        for error in errors[:80]:
            print("- " + error, file=sys.stderr)
        if len(errors) > 80:
            print("... 其餘 %d 項省略" % (len(errors) - 80), file=sys.stderr)
        return 1
    print("Pages 驗證通過：site/project 相對連結與入口存在")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
