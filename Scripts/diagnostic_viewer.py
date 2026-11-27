#!/usr/bin/env python3
"""ReplyKit 診斷日誌本機檢視器。

把 `diagnostic-*.txt` 依 `[Tag]`、session 與嚴重度拆開，提供可搜尋的
本機網頁；不依賴外部套件，也不會上傳日誌。

用法:
    python Scripts/diagnostic_viewer.py "E:\\Video5\\crash-symbols\\diagnostic-....txt"
    python Scripts/diagnostic_viewer.py <log.txt> --port 8766 --no-browser
"""

from __future__ import annotations

import argparse
import errno
import json
import re
import sys
import webbrowser
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
TEMPLATE = ROOT / "diagnostic_viewer.html"
DEFAULT_PORT = 8766

TIMESTAMP = re.compile(r"^(\d{4}/\d{2}/\d{2}\s+\S*\d{1,2}:\d{2}:\d{2}):\s*(.*)$")
LOCAL_TIMESTAMP = re.compile(
    r"^(\d{4})/(\d{1,2})/(\d{1,2})\s+"
    r"(?:(凌晨|清晨|早晨|早上|上午|中午|下午|傍晚|晚上|深夜)\s*)?"
    r"(\d{1,2}):(\d{2}):(\d{2})$"
)
TAG = re.compile(r"\[([^\[\]]+)\]")
SESSION = re.compile(r"\bsession=([0-9A-Fa-f-]{8,}|[A-Za-z0-9_.-]+)")
FIELD = re.compile(r"\b([A-Za-z_][A-Za-z0-9_.-]*)=([^\s]+)")
ERROR_WORDS = re.compile(
    r"\b(failed|failure|fatal|panic|crash|jetsam|watchdog|abort|exception)\b",
    re.IGNORECASE,
)
WARN_WORDS = re.compile(
    r"(\[!\]|warning|memory\.warning|save failed|incomplete|"
    r"syncState=(drifting|jumped)|lastError=(?!none\b|0\b)\S+)",
    re.IGNORECASE,
)


@dataclass
class LogLine:
    number: int
    time: str
    category: str
    severity: str
    session: str | None
    message: str
    fields: dict[str, str] = field(default_factory=dict)
    epoch_ms: int | None = None

    def as_dict(self) -> dict:
        return {
            "n": self.number,
            "time": self.time,
            "category": self.category,
            "severity": self.severity,
            "session": self.session,
            "message": self.message,
            "fields": self.fields,
            "epoch": self.epoch_ms,
        }


def classify_severity(message: str) -> str:
    """只把真正的失敗與警示拉出來。

    `failed=0`、`lastError=none`、累積的 `dropped=1` 都不是錯誤；
    後者只代表總數，應該在欄位裡看，不該讓整段後續紀錄都變紅。
    """
    lowered = message.lower()
    for match in ERROR_WORDS.finditer(lowered):
        word = match.group(1)
        suffix = lowered[match.end():]
        value_match = re.match(r"\s*=\s*([^\s]+)", suffix)
        if value_match and value_match.group(1) in {"0", "none", "false", "no"}:
            continue
        return "error"
    for match in re.finditer(r"\berror\s*=\s*([^\s]+)", lowered):
        value = match.group(1)
        if value not in {"none", "0", "false", "no"}:
            return "error"
    if WARN_WORDS.search(lowered):
        return "warn"
    return "info"


def parse_local_timestamp(text: str) -> int | None:
    """把日誌的本地時間字串轉成 epoch 毫秒。

    日誌使用 `2026/11/26 晚上9:35:11` 這類中文時段，不是 ISO 8601；
    直接丟給 `datetime.fromisoformat` 會失敗，時間範圍篩選也會靜默失效。
    """
    match = LOCAL_TIMESTAMP.match(text.strip())
    if not match:
        return None
    year, month, day, period, hour_text, minute_text, second_text = match.groups()
    hour = int(hour_text)
    if period in {"下午", "傍晚"} and hour < 12:
        hour += 12
    elif period in {"晚上", "深夜"}:
        if hour == 12:
            hour = 0
        elif hour < 12:
            hour += 12
    elif period == "中午" and hour < 11:
        hour += 12
    elif period in {"凌晨", "清晨", "早晨", "早上", "上午"} and hour == 12:
        hour = 0
    try:
        return int(datetime(
            int(year), int(month), int(day),
            hour, int(minute_text), int(second_text),
        ).timestamp() * 1000)
    except (ValueError, OSError):
        return None


def parse_line(number: int, raw: str) -> LogLine:
    raw = raw.rstrip("\r\n")
    match = TIMESTAMP.match(raw)
    if match:
        time_text, body = match.group(1), match.group(2)
    else:
        time_text, body = "", raw

    if body.startswith("liveApp:"):
        body = body[len("liveApp:"):].lstrip()

    tag = TAG.search(body)
    category = tag.group(1) if tag else "Other"
    if not time_text and body.startswith("[BuildInfo]"):
        category = "BuildInfo"

    session_match = SESSION.search(body)
    session = session_match.group(1) if session_match else None

    fields: dict[str, str] = {}
    for key, value in FIELD.findall(body):
        # 只保留短值，避免把整段 JSON 或路徑拆成欄位。
        if len(value) <= 160:
            fields[key] = value

    return LogLine(
        number=number,
        time=time_text,
        category=category,
        severity=classify_severity(body),
        session=session,
        message=body,
        fields=fields,
        epoch_ms=parse_local_timestamp(time_text),
    )


def parse_log(path: Path) -> list[LogLine]:
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    return [parse_line(index + 1, line) for index, line in enumerate(text.splitlines())]


def summarize(path: Path, lines: list[LogLine]) -> dict:
    categories = Counter(line.category for line in lines)
    sessions = sorted({line.session for line in lines if line.session})
    times = [line.time for line in lines if line.time]
    epochs = [line.epoch_ms for line in lines if line.epoch_ms is not None]
    latest_line = max(
        (line for line in lines if line.epoch_ms is not None),
        key=lambda line: line.epoch_ms or 0,
        default=None,
    )
    warnings = sum(1 for line in lines if line.severity == "warn")
    errors = sum(1 for line in lines if line.severity == "error")
    return {
        "file": str(path),
        "range": f"{times[0]} ～ {times[-1]}" if times else "無時間戳",
        "lines": len(lines),
        "earliest": min(epochs) if epochs else None,
        "latest": max(epochs) if epochs else None,
        "latestTime": latest_line.time if latest_line else None,
        "categories": [
            {"name": name, "count": count}
            for name, count in categories.most_common()
        ],
        "sessions": sessions,
        "warn": warnings,
        "error": errors,
    }


def filter_indices(
    lines: list[LogLine], *, category: str = "", severity: str = "",
    session: str = "", search: str = "", from_ms: int = 0, to_ms: int = 0,
) -> list[int]:
    """依可見篩選與時間範圍回傳符合的原始索引。"""
    result: list[int] = []
    for index, line in enumerate(lines):
        if category and line.category != category:
            continue
        if severity and line.severity != severity:
            continue
        if session and line.session != session:
            continue
        if from_ms and (line.epoch_ms is None or line.epoch_ms < from_ms):
            continue
        if to_ms and (line.epoch_ms is None or line.epoch_ms > to_ms):
            continue
        if search:
            haystack = " ".join(
                [line.message, line.category, line.session or ""]
                + [f"{key}={value}" for key, value in line.fields.items()]
            ).lower()
            if search not in haystack:
                continue
        result.append(index)
    return result


class ViewerHandler(BaseHTTPRequestHandler):
    lines: list[LogLine] = []
    summary: dict = {}

    def log_message(self, format: str, *args) -> None:  # noqa: A002,A003
        # 避免每個 API 請求都洗版；真正錯誤仍可從主控台看到。
        return

    def send_json(self, value: dict, status: int = 200) -> None:
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_html(self) -> None:
        try:
            body = TEMPLATE.read_bytes()
        except OSError as error:
            self.send_error(500, f"找不到 diagnostic_viewer.html: {error}")
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            self.send_html()
            return
        if parsed.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        if parsed.path == "/api/summary":
            self.send_json(self.summary)
            return
        if parsed.path == "/api/lines":
            self.handle_lines(parse_qs(parsed.query))
            return
        self.send_error(404)

    def handle_lines(self, query: dict[str, list[str]]) -> None:
        def first(name: str) -> str:
            return (query.get(name) or [""])[0]

        category = first("category")
        severity = first("severity")
        session = first("session")
        search = first("q").lower()
        order = "desc" if first("order") == "desc" else "asc"
        try:
            offset = max(0, int(first("offset") or "0"))
            limit = min(1000, max(1, int(first("limit") or "300")))
            context = min(10, max(0, int(first("context") or "0")))
            from_ms = max(0, int(first("from") or "0"))
            to_ms = max(0, int(first("to") or "0"))
        except ValueError:
            self.send_json({"error": "offset/limit/context/from/to 必須是整數"}, 400)
            return

        matched_indices = filter_indices(
            self.lines,
            category=category,
            severity=severity,
            session=session,
            search=search,
            from_ms=from_ms,
            to_ms=to_ms,
        )
        if order == "desc":
            matched_indices.reverse()
        page_matches = matched_indices[offset:offset + limit]
        page = page_with_context(
            self.lines, matched_indices, offset, limit, context, order
        )
        self.send_json({
            "total": len(matched_indices),
            "offset": offset,
            "limit": limit,
            "context": context,
            "order": order,
            "from": from_ms,
            "to": to_ms,
            "matchCount": len(page_matches),
            "lineCount": len(page),
            "hasMore": offset + len(page_matches) < len(matched_indices),
            "lines": [dict(line.as_dict(), isMatch=is_match) for line, is_match in page],
        })


def page_with_context(lines: list[LogLine], matched: list[int],
                      offset: int, limit: int, context: int,
                      order: str = "asc") -> list[tuple[LogLine, bool]]:
    """回傳本頁符合行與其前後鄰近行；is_match 為 True 表示真正符合篩選。"""
    page = matched[offset:offset + limit]
    wanted = set(page)
    indices: set[int] = set()
    for index in page:
        start = max(0, index - context)
        end = min(len(lines), index + context + 1)
        indices.update(range(start, end))
    ordered = sorted(indices, reverse=(order == "desc"))
    return [(lines[index], index in wanted) for index in ordered]


def bind_server(host: str, start_port: int, attempts: int = 20) -> ThreadingHTTPServer:
    """綁定指定 port；使用中時往下一個 port 嘗試，不讓小工具開不起來。"""
    last_error: OSError | None = None
    for offset in range(attempts):
        candidate = 0 if start_port == 0 else start_port + offset
        try:
            server = ThreadingHTTPServer((host, candidate), ViewerHandler)
            if offset:
                print(f"Port {start_port} 已被使用，改用 {server.server_address[1]}。")
            return server
        except OSError as error:
            last_error = error
            # Windows 對已占用 port 可能回 WinError 10013（WSAEACCES），
            # 而不是 Unix 常見的 EADDRINUSE。
            in_use = error.errno in (errno.EADDRINUSE, errno.EACCES, 10048)
            in_use = in_use or getattr(error, "winerror", None) == 10013
            if start_port == 0 or not in_use:
                raise
    raise SystemExit(
        f"Port {start_port}～{start_port + attempts - 1} 都無法使用：{last_error}"
    )


def serve(path: Path, host: str, port: int, open_browser: bool) -> None:
    if not path.is_file():
        raise SystemExit(f"找不到日誌檔：{path}")
    lines = parse_log(path)
    ViewerHandler.lines = lines
    ViewerHandler.summary = summarize(path, lines)
    template = TEMPLATE
    if not template.is_file():
        raise SystemExit(f"找不到網頁模板：{template}")

    server = bind_server(host, port)
    actual_port = server.server_address[1]
    url = f"http://{host}:{actual_port}/"
    print(f"診斷檢視器：{url}")
    print(f"檔案：{path}（{len(lines)} 行）")
    print("按 Ctrl+C 停止。")
    if open_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        server.server_close()


def main() -> None:
    if sys.platform == "win32":
        for stream in (sys.stdout, sys.stderr):
            reconfigure = getattr(stream, "reconfigure", None)
            if reconfigure is not None:
                reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="ReplyKit 診斷日誌本機檢視器")
    parser.add_argument("log", type=Path, help="diagnostic-*.txt")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--no-browser", action="store_true", help="不要自動開啟瀏覽器")
    args = parser.parse_args()
    serve(args.log.expanduser(), args.host, args.port, not args.no_browser)


if __name__ == "__main__":
    main()
