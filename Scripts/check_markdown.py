#!/usr/bin/env python3
"""本地與 CI 共用的 Markdown 空行檢查（MD012）。

只檢查「連續多個空白行」，忽略 fenced code block 內的空白；與
development-index workflow 使用同一個入口，避免只在 CI 才發現。
"""

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


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


def md012_errors(path: Path) -> list[tuple[int, int]]:
    """回傳 (行號, 該段連續空白行數) 的 MD012 錯誤。"""
    text = path.read_text(encoding="utf-8", errors="replace")
    in_fence = False
    fence = ""
    blank_run = 0
    errors: list[tuple[int, int]] = []
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
                errors.append((line_number, blank_run))
        else:
            blank_run = 0
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
        for line_number, count in md012_errors(path):
            display = path.relative_to(ROOT) if path.is_absolute() and ROOT in path.parents else path
            print("%s:%d MD012/no-multiple-blanks 連續 %d 個空白行" %
                  (display, line_number, count))
            failures += 1
    if failures:
        print("Markdown 空行檢查失敗（%d 項）；移除多餘空白行後再提交。" % failures,
              file=sys.stderr)
        return 1
    print("Markdown 空行檢查通過（%d 個檔案）" % len(paths))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
