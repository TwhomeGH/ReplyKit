"""命令列介面：add / list / show / serve。

網頁 GUI 為主要介面；CLI 供腳本化使用。
"""

import argparse
import sys

from . import server, storage


def cmd_add(args):
    """插入新紀錄；日期／時間留空時帶入現在時刻。"""
    date_str = args.date or storage.now_parts()[0]
    time_str = args.time or storage.now_parts()[1]
    storage.insert_block(storage.build_block(
        date_str, args.title, args.type, args.file,
        refs=getattr(args, "ref", []), time_str=time_str))
    print("已插入: %s %s %s" % (date_str, time_str, args.title))


def _matches(e, args):
    """依 grep／file／type／since 篩選單筆紀錄。"""
    hay = (e["title"] + "\n" + e["raw"]).lower()
    if args.grep and args.grep.lower() not in hay:
        return False
    if args.file and args.file.lower() not in e["raw"].lower():
        return False
    if args.type and args.type.lower() not in e["raw"].lower():
        return False
    if args.since and (not e["date"] or e["date"] < args.since):
        return False
    return True


def cmd_list(args):
    """列出符合條件的紀錄（序號、日期時間、標題）。"""
    entries = storage.parse_entries()
    hits = [e for e in entries if _matches(e, args)]
    if args.limit:
        hits = hits[: args.limit]
    print("符合 %d / 共 %d 筆\n" % (len(hits), len(entries)))
    for i, e in enumerate(hits, 1):
        when = e["date"] or "----------"
        if e["date"] and e["time"]:
            when += " " + e["time"]
        print("%3d  %-16s  %s" % (i, when, e["title"]))


def cmd_show(args):
    """以編號或關鍵字顯示單筆完整內容。"""
    entries = storage.parse_entries()
    target = None
    if args.query.isdigit():
        idx = int(args.query) - 1
        if 0 <= idx < len(entries):
            target = entries[idx]
    if target is None:
        q = args.query.lower()
        target = next((e for e in entries if q in (e["title"] + "\n" + e["raw"]).lower()), None)
    if target is None:
        sys.exit("找不到符合的紀錄: %s" % args.query)
    print(target["raw"])


def main(argv=None):
    """進入點：解析參數並分派。無子命令等同 ``serve``。"""
    p = argparse.ArgumentParser(description="變更歷史：網頁 GUI + CLI（Docs/ChangeHistory.md）")
    sub = p.add_subparsers(dest="cmd")

    sv = sub.add_parser("serve", help="啟動本機網頁 GUI")
    sv.add_argument("--port", type=int, default=8710)
    sv.add_argument("--no-browser", action="store_true")

    a = sub.add_parser("add", help="插入新紀錄骨架（CLI）")
    a.add_argument("title")
    a.add_argument("--type", default="修復")
    a.add_argument("--file", default="")
    a.add_argument("--date", default="")
    a.add_argument("--time", default="", help="時間 HH:MM（預設為現在時刻）")
    a.add_argument("--ref", action="append", default=[], help="相關文件（可重複，格式 [說明](路徑)）")

    l = sub.add_parser("list", help="檢索紀錄（CLI）")
    l.add_argument("--grep", default="")
    l.add_argument("--since", default="")
    l.add_argument("--file", default="")
    l.add_argument("--type", default="")
    l.add_argument("--limit", type=int, default=0)

    s = sub.add_parser("show", help="顯示單筆完整內容（編號或關鍵字）")
    s.add_argument("query")

    args = p.parse_args(argv)
    if args.cmd in (None, "serve"):
        server.serve(getattr(args, "port", 8710), not getattr(args, "no_browser", False))
    elif args.cmd == "add":
        cmd_add(args)
    elif args.cmd == "list":
        cmd_list(args)
    elif args.cmd == "show":
        cmd_show(args)
