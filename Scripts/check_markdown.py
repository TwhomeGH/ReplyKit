#!/usr/bin/env python3
"""本地與 CI 共用的 Markdown 結構檢查（MD001／MD012）。

- MD001：heading 每次最多只能增加一階（h2 → h4 會失敗）。
- MD012：不可有連續多個空白行。

忽略 fenced code block 內的內容；與 development-index workflow 共用入口，
避免只在 CI 才發現。
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HEADING = re.compile(r"^(#{1,6})\s")


def git_markdown_files() -> list[Path]:
    output = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others",
         "--exclude-standard", "--", "*.md"],
        stderr=subprocess.STDOUT,
    )
    paths = []
    for raw in output.split(b"\0"):
        if raw:
            paths.append(ROOT / raw.decode("utf-8", errors="surrogateescape"))
    return sorted(set(paths))


def markdown_errors(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    in_fence = False
    fence = ""
    blank_run = 0
    previous_heading = 0
    errors: list[str] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        if in_fence:
            if stripped.startswith(fence):
                in_fence = False
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = True
            fence = stripped[:3]
            blank_run = 0
            continue
        if line.strip() == "":
            blank_run += 1
            if blank_run > 1:
                errors.append("%d MD012/no-multiple-blanks 連續 %d 個空白行" %
                              (line_number, blank_run))
            continue
        blank_run = 0
        heading = HEADING.match(line)
        if heading:
            level = len(heading.group(1))
            if previous_heading and level > previous_heading + 1:
                errors.append("%d MD001/heading-increment 標題由 h%d 跳到 h%d" %
                              (line_number, previous_heading, level))
            previous_heading = level
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="指定 Markdown；省略時使用 git 清單")
    args = parser.parse_args()
    paths = [Path(p) for p in args.paths] if args.paths else git_markdown_files()
    failures = 0
    for path in paths:
        if not path.is_file():
            print("找不到檔案：%s" % path, file=sys.stderr)
            failures += 1
            continue
        display = path.relative_to(ROOT) if path.is_absolute() and ROOT in path.parents else path
        for error in markdown_errors(path):
            print("%s:%s" % (display, error))
            failures += 1
    if failures:
        print("Markdown 結構檢查失敗（%d 項）；修正後再提交。" % failures,
              file=sys.stderr)
        return 1
    print("Markdown 結構檢查通過（%d 個檔案）" % len(paths))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
