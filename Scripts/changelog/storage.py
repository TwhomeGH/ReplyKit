"""ChangeHistory 資料層。

負責 ``Docs/ChangeHistory.md`` 的解析、組版與讀寫。網頁與 CLI 皆透過這裡
存取資料，因此調整資料格式時只需改動本模組。

資料格式（最新在最上面）::

    ## YYYY.MM.DD HH:MM 一句話標題
    **類型**: 修復 · **檔案**: `a/b.swift`
    ### 問題 - 摘要
    ...
    ### 根因 - 摘要
    ...
    ### 修改 - 核心手法
    - 其他改動
    **相關文件**: [說明](Docs/x.md) · [另一份](Docs/y.md)
    ---
"""

import re
import subprocess
import sys
from datetime import date, datetime
from pathlib import Path

# 專案根目錄：本檔位於 Scripts/changelog/，往上兩層即專案根。
ROOT = Path(__file__).resolve().parents[2]
HISTORY = ROOT / "Docs" / "ChangeHistory.md"

# 標題行：## YYYY.MM.DD [HH:MM] 標題（時間可省略，舊資料相容）。
DATE_RE = re.compile(r"^##\s+(\d{4})\.(\d{2})\.(\d{2})(?:\s+(\d{1,2}:\d{2}))?\s+(.*)$")


# ─────────────────────────── 解析 ───────────────────────────

def strip_comments(text):
    """移除 HTML 註解（``<!-- ... -->``），避免註解內的 ``## `` 被當成標題。"""
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)


def parse_entries(text=None):
    """回傳 ``list[dict(date, time, title, raw)]``，順序即檔案順序（新→舊）。

    ``raw`` 為該筆完整 markdown（不含尾端 ---- 之後的內容），供編輯與呈現。
    """
    text = read_history() if text is None else text
    lines = strip_comments(text).splitlines()
    heads = [i for i, l in enumerate(lines) if l.startswith("## ")]
    entries = []
    for k, start in enumerate(heads):
        end = heads[k + 1] if k + 1 < len(heads) else len(lines)
        raw = "\n".join(lines[start:end]).rstrip()
        m = DATE_RE.match(lines[start].rstrip())
        if m:
            entries.append({"date": "%s.%s.%s" % (m.group(1), m.group(2), m.group(3)),
                            "time": m.group(4) or "",
                            "title": m.group(5).strip(), "raw": raw})
        else:
            entries.append({"date": None, "time": "",
                            "title": lines[start][3:].strip(), "raw": raw})
    return entries


def read_history():
    """讀取 ChangeHistory.md；不存在時直接結束程式（資料檔是必要輸入）。"""
    if not HISTORY.exists():
        sys.exit("找不到 %s" % HISTORY)
    return HISTORY.read_text(encoding="utf-8")


def _heading_indices(lines):
    """真實（非註解內）的 ``'## '`` 標題行索引。"""
    out, in_comment = [], False
    for i, l in enumerate(lines):
        if "<!--" in l:
            in_comment = True
        if in_comment:
            if "-->" in l:
                in_comment = False
            continue
        if l.startswith("## "):
            out.append(i)
    return out


# ─────────────────────────── 組版 ───────────────────────────

def _summary_body(text):
    """把多行文字拆成 (摘要, 其餘內文)；摘要取第一個非空行。

    摘要會成為 ``### 問題 - <摘要>`` / ``### 根因 - <摘要>`` 標題的一部分，
    因此必須是能區分各筆紀錄的短句，避免 markdownlint MD024（重複標題）。
    """
    text = (text or "").strip()
    if not text:
        return "", ""
    parts = text.splitlines()
    return parts[0].strip(), "\n".join(parts[1:]).strip()


def _norm_refs(refs):
    """把多筆相關文件正規化為以 `` · `` 串接的單行字串。

    接受 list（網頁 GUI）或字串（每行一筆，CLI 用），保留每筆的
    markdown 連結寫法（如 ``[說明](Docs/x.md)``）。
    """
    if not refs:
        return ""
    if isinstance(refs, str):
        refs = refs.splitlines()
    items = [str(r).strip() for r in refs if str(r).strip()]
    return " · ".join(items)


def build_block(date_str, title, type_, file_, problem="", root_cause="",
                changes=None, refs="", time_str=""):
    """把表單欄位組成一段 markdown 紀錄區塊（不含尾端分隔線之外的空行正規化）。"""
    if isinstance(changes, str):
        changes = changes.splitlines()
    changes = [c.strip() for c in (changes or []) if c and c.strip()]
    refs = _norm_refs(refs)
    head = "## %s %s" % (date_str, title)
    if time_str:
        head = "## %s %s %s" % (date_str, time_str, title)
    lines = [head, ""]
    meta = "**類型**: %s" % (type_ or "修復")
    if file_:
        meta += " · **檔案**: `%s`" % file_
    lines += [meta, ""]
    # 問題 / 根因：第一行當標題摘要，其後為詳述。
    for label, text in (("問題", problem), ("根因", root_cause)):
        summary, body = _summary_body(text)
        if not summary:
            continue
        lines.append("### %s - %s" % (label, summary))
        if body:
            lines += ["", body]
        lines.append("")
    # 修改：第一項當標題摘要，其餘為條列。
    if changes:
        summary, rest = changes[0], changes[1:]
        lines.append("### 修改 - %s" % summary)
        if rest:
            lines.append("")
            lines += ["- %s" % c for c in rest]
        lines.append("")
    if refs:
        lines.append("**相關文件**: %s" % refs)
    while lines and lines[-1] == "":
        lines.pop()
    lines += ["", "---", ""]
    return "\n".join(lines)


# ─────────────────────────── 寫入 ───────────────────────────

def _write(lines):
    """把行陣列寫回 ChangeHistory.md，正規化結尾換行。"""
    HISTORY.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def insert_block(block):
    """把新區塊插到第一筆紀錄之前（維持最新在上）。"""
    lines = read_history().splitlines()
    heads = _heading_indices(lines)
    at = heads[0] if heads else len(lines)
    new = lines[:at] + block.splitlines() + [""] + lines[at:]
    _write(new)


def _entry_range(heads, lines, i):
    """回傳第 i 筆的 (start, end)；越界時拋 IndexError。"""
    if not (0 <= i < len(heads)):
        raise IndexError("編號超出範圍")
    start = heads[i]
    end = heads[i + 1] if i + 1 < len(heads) else len(lines)
    return start, end


def update_entry(i, raw):
    """以新的 markdown 內容取代第 i 筆。"""
    lines = read_history().splitlines()
    heads = _heading_indices(lines)
    start, end = _entry_range(heads, lines, i)
    repl = raw.rstrip().splitlines()
    if i + 1 < len(heads):          # 後面還有下一筆 → 補回分隔空行
        repl.append("")
    _write(lines[:start] + repl + lines[end:])


def delete_entry(i):
    """刪除第 i 筆，並收斂多餘空行。"""
    lines = read_history().splitlines()
    heads = _heading_indices(lines)
    start, end = _entry_range(heads, lines, i)
    new = lines[:start] + lines[end:]
    out, blank = [], 0
    for l in new:
        blank = blank + 1 if l.strip() == "" else 0
        if blank <= 2:
            out.append(l)
    _write(out)


# ─────────────────────────── Git 輔助 ───────────────────────────

def git_changed_files():
    """目前工作區已修改（含未追蹤、未忽略）的檔案清單；失敗時回傳空清單。"""
    try:
        r1 = subprocess.run(["git", "-C", str(ROOT), "diff", "--name-only"],
                            capture_output=True, text=True, timeout=5).stdout
        r2 = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--others",
                             "--exclude-standard"],
                            capture_output=True, text=True, timeout=5).stdout
        files = [f.strip() for f in (r1 + "\n" + r2).splitlines() if f.strip()]
        return sorted(set(files))
    except Exception:
        return []


# ─────────────────────────── CLI 用的便利函式 ───────────────────────────

def now_parts():
    """回傳 (預設日期字串, 預設時間字串)，格式 YYYY.MM.DD 與 HH:MM。"""
    n = datetime.now()
    return n.strftime("%Y.%m.%d"), n.strftime("%H:%M")


def today_str():
    """今天的 YYYY.MM.DD。"""
    return date.today().strftime("%Y.%m.%d")
