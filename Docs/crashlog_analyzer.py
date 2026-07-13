#!/usr/bin/env python3
"""
crashlog_analyzer.py — ReplyKit 系統日誌 / Crash Report / Analytics 分析工具

Usage:
    python crashlog_analyzer.py <file.ips>
    python crashlog_analyzer.py <file.ips.ca.synced.txt>
    python crashlog_analyzer.py <log.txt>
    python crashlog_analyzer.py <directory>   (掃描目錄下所有已知格式)
"""

import json
import re
import sys
from pathlib import Path
from collections import Counter
from datetime import datetime


# ── 中文名稱對照 ──
EVENT_CN = {
    "CPAnalyticsWeeklyScreenView": "每週螢幕瀏覽",
    "CPAnalyticsWeeklyScreenViewMinimalFields": "每週螢幕瀏覽(精簡)",
    "ExcessiveVolumeTelemetry": "音量過大回報",
    "FreezerRecommendationMetrics": "凍結建議指標",
    "PhotosFeatureUsed_Weekly_Histogram": "照片功能使用(每週)",
    "PhotosEditSession_v8_Weekly": "照片編輯工作階段(每週)",
    "PhotosFeatureUsed_Weekly": "照片功能使用(每週)",
    "Edit_Session_Weekly_Histogram": "編輯工作階段(每週)",
    "FreezerRecommendationMetricsModelPerformance": "凍結建議模型效能",
    "PhotosEdit_Retouch_v0_2_dailyRotation_weeklyAgg": "照片編輯-修飾(每日輪換)",
}

LOG_CN = {
    "VFrame": "視訊more frames到達",
    "VProc": "視訊more frames處理",
    "PIP": "子母畫面事件",
    "SocketEvent": "Socket 連線事件",
    "TTS_Error": "TTS 語音錯誤 [!]",
    "MemoryWarning": "記憶體警告 [!]",
    "PageSwitch": "頁面切換",
    "AudioPage": "音訊頁面",
    "Heartbeat": "心跳維持",
    "StreamEvent": "串流事件",
}

# ── ANSI colors ──
class C:
    R = "\033[91m"
    G = "\033[92m"
    Y = "\033[93m"
    B = "\033[94m"
    M = "\033[95m"
    CYN = "\033[96m"
    N = "\033[0m"


# ── Helpers ──

def fmt_ts(ts):
    if isinstance(ts, str):
        return ts[:19]
    return str(ts)


def highlight(msg, keyword, color=C.R):
    return msg.replace(keyword, f"{color}{keyword}{C.N}")


# ── IPS Crash Report Parser ──

BUG_TYPES = {
    "309": "[!] Crash / 例外終止",
    "284": "[!] GPU Hang / IOFence 阻塞",
    "211": "[i] Analytics Data",
    "145": "[i] Resource Exception (磁碟寫入)",
    "110": "[i] Watchdog Timeout",
    "298": "[i]  熱力降頻事件",
    "212": "[i]  崩潰日誌聚合",
    "199": "[i]  系統診斷",
    "107": "[i]  Jetsam (記憶體不足)",
    "108": "[i]  記憶體狀態",
}

def parse_ips(path):
    content = path.read_text(encoding="utf-8", errors="replace")
    data = {}
    buf = ""
    depth = 0
    first_ts = None
    for ch in content:
        buf += ch
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and buf.strip():
                try:
                    obj = json.loads(buf.strip())
                    # Preserve the first string timestamp
                    ts = obj.get("timestamp") or obj.get("captureTime")
                    if ts and isinstance(ts, str) and first_ts is None:
                        first_ts = ts
                    data.update(obj)
                except json.JSONDecodeError:
                    pass
                buf = ""
    if buf.strip():
        try:
            data.update(json.loads(buf.strip()))
        except json.JSONDecodeError:
            pass
    # Restore string timestamp if overwritten by numeric
    if first_ts:
        data["_timestamp"] = first_ts

    bug_type = str(data.get("bug_type", ""))
    bug_label = BUG_TYPES.get(bug_type, f"[!] 未分類型別 (bug_type {bug_type})")

    print(f"\n{C.B}══════════════════════════════════════{C.N}")
    print(f"{C.B}   {bug_label}: {path.name}{C.N}")
    print(f"{C.B}══════════════════════════════════════{C.N}\n")

    app = data.get("app_name") or data.get("process_name") or data.get("bundleID") or "?"
    version = data.get("app_version") or data.get("CFBundleShortVersionString") or "?"
    bundle = data.get("bundleID") or "?"
    os = data.get("os_version") or "?"
    model = data.get("modelCode") or data.get("hwMachine") or data.get("hardwareModel") or "?"
    # 優先使用字串格式的時間戳
    ts = data.get("_timestamp") or data.get("captureTime") or ""
    proc = data.get("procName") or data.get("process_name") or data.get("name") or "?"
    pid = data.get("pid") or "?"
    role = data.get("procRole", "")
    coal = data.get("coalitionName", "")

    print(f"  [OS] OS: {os}")
    if model:
        print(f"  [DEV] Device: {model}")
    print(f"  [ID] Bundle: {bundle}")
    if app != bundle:
        print(f"  [APP] App: {app} (v{version})")
    else:
        print(f"  [APP] App: {app} v{version}")
    if ts:
        print(f"  [TIME] Time: {fmt_ts(ts)}")
    if pid != "?":
        print(f"  [PROC]  Proc: {proc} (PID {pid}){f' [{role}]' if role else ''}")
    else:
        print(f"  [PROC]  Proc: {proc}")
    if coal:
        print(f"  [LINK]  Coalition：{coal}")

    # Resource Exception資訊 (bug_type 145)
    duration = data.get("duration_ms")
    if duration is not None:
        try:
            d = float(duration)
            m = int(d // 60000)
            s = int((d % 60000) // 1000)
            print(f"  [DUR] duration: {m}m {s}s ({d} ms)")
        except (ValueError, TypeError):
            print(f"  [DUR] duration: {duration}")

    # 例外 / 終止資訊 (bug_type 309 等)
    exc = data.get("exception", {})
    term = data.get("termination", {})
    if exc:
        etype = exc.get("type", "?")
        signal = term.get("indicator", "?")
        subtype = exc.get("subtype", "")
        print(f"  {C.R}[X] Exception: {etype} ({signal}){C.N}")
        if subtype:
            print(f"     subtype：{subtype}")
    elif term:
        signal = term.get("indicator", "?")
        namespace = term.get("namespace", "")
        code = term.get("code", "")
        print(f"  {C.R}[X] Termination: {signal} ({namespace} code {code}){C.N}")

    # Threads (bug_type 309 等 crash report)
    threads = data.get("threads", [])
    fault = data.get("faultingThread", -1)
    if threads:
        print(f"\n{C.Y}[THR] Threads: {len(threads)} {C.N}")
        for i, t in enumerate(threads):
            queue = t.get("queue", "")
            tid = t.get("id", "?")
            frames = t.get("frames", [])
            is_fault = (i == fault)
            if is_fault or i < 2:
                tag = f" {C.R} << FAULT THREAD{C.N}" if is_fault else ""
                print(f"  Thread {i} [{tid}] queue={queue}{tag}")
                for f in frames[:8]:
                    sym = f.get("symbol", "?")
                    off = f.get("symbolLocation", 0)
                    print(f"    {sym}+{off}")
                if len(frames) > 8:
                    print(f"    ... and {len(frames)-8} more frames")

    # GPU Hang 分析 (bug_type 284)
    analysis = data.get("analysis", {})
    if analysis:
        print(f"\n{C.M}[GPU] GPU Analysis{C.N}")
        restart = analysis.get("restart_reason_desc", "")
        if restart:
            print(f"  Restart Reason:  {restart}")
        signature = analysis.get("signature", "?")
        print(f"  Signature: {signature}")
        iofence = analysis.get("iofence_list", {})
        fences = iofence.get("iofence_iosurfaces", [])
        if fences:
            print(f"  IOFence blocked surfaces: {len(fences)}")
            for f in fences:
                sid = f.get("iosurface_id", "?")
                waiting = f.get("iofence_waiting_queue", [])
                current = f.get("iofence_current_queue", [])
                print(f"    Surface {sid}: {len(current)} active, {len(waiting)} waiting")

    # VM Summary
    vm = data.get("vmSummary", "")
    if vm:
        print(f"\n{C.CYN}[MEM] Memory Regions:{C.N}")
        for line in vm.split("\n"):
            if any(kw in line for kw in ("Malloc", "CG", "CoreAnimation", "IOAccelerator")):
                print(f"  {line.strip()}")

    # Used Images (modules)
    images = data.get("usedImages", [])
    if images:
        app_images = [i for i in images if "ReplyKIT" in i.get("name", "")
                      or "liveAPP" in i.get("name", "")]
        if app_images:
            print(f"\n{C.M}[DEV] App Modules:{C.N}")
            for img in app_images:
                print(f"  {img.get('name','?')} @0x{img.get('base',0):x}")


# ── IPS.ca.synced.txt (Apple Analytics) Parser ──

def parse_analytics(path):
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    print(f"\n{C.CYN}══════════════════════════════════════{C.N}")
    print(f"{C.CYN}   Analytics: {path.name}{C.N}")
    print(f"{C.CYN}══════════════════════════════════════{C.N}\n")

    meta = {}
    header = {}
    event_names = Counter()
    bundle_ids = Counter()
    error_codes = Counter()
    total = 0
    meta_keys = {
        "productSku": "型號", "currentCountry": "國家", "deviceCapacity": "容量(GB)",
        "dramSize": "記憶體(GB)", "startTimestamp": "開始時間", "sessionId": "Session",
        "os_version": "系統版本", "appStoreCountry": "商店國家",
        "_preferredUserInterfaceLanguage": "語言", "configVariant": "配置變體",
    }

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue

        has_name = "name" in obj
        if not has_name:
            meta.update(obj)
            continue

        total += 1
        name = obj.get("name", "")
        msg = obj.get("message", {})
        event_names[name] += 1

        if isinstance(msg, dict):
            bid = msg.get("bundleId", "?")
            bundle_ids[bid] += 1
            ec = msg.get("errorCodes")
            if ec:
                error_codes[str(ec)] += 1

    print(f"  [OS] OS: {meta.get('os_version', '?')}")
    print(f"  [DEV] SKU：{meta.get('productSku', '?')}")
    print(f"  [GEO] 國家：{meta.get('currentCountry', '?')}")
    print(f"  [MEM] 容量：{meta.get('deviceCapacity', '?')} GB")
    print(f"  [RAM] 記憶體：{meta.get('dramSize', '?')} GB")
    print(f"  [TIME] 統計區間：{meta.get('startTimestamp', '?')}")
    print(f"  [ID] Session：{meta.get('sessionId', '?')}")

    print(f"\n{C.Y}Total events: {total}{C.N}")

    if event_names:
        print(f"\n  {C.B}[STAT] Event Type Top 10:{C.N}")
        for name, count in event_names.most_common(10):
            cn = EVENT_CN.get(name, "")
            tag = f"  {cn}" if cn else ""
            print(f"    {name}: {count}{tag}")

    if error_codes:
        print(f"\n  {C.R}[X] Error Code Top 10:{C.N}")
        for code, count in error_codes.most_common(10):
            print(f"    {code}: {count}")


# ── ReplyKit 自有 log.txt 解析器 ──

LOG_PATTERNS = {
    "VFrame": r"\[VFrame\]",
    "VProc": r"\[VProc\]",
    "PIP": r"\[PIP\]",
    "SocketEvent": r"(Connection (added|ready|removed)|Idle timeout|Socket Send error|SocketClient (connected|connection closed))",
    "TTS_Error": r"TTS.*配置失敗|音頻服務已丟失",
    "MemoryWarning": r"Memory Warning|收到 Memory Warning",
    "PageSwitch": r"Page:",
    "AudioPage": r"onAudioPage:",
    "Heartbeat": r"心跳|keepalive",
    "StreamEvent": r"StreamEnded|直播已結束|廣播暫停",
}


def parse_log(path):
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    print(f"\n{C.G}══════════════════════════════════════{C.N}")
    print(f"{C.G}   Log File: {path.name}{C.N}")
    print(f"{C.G}══════════════════════════════════════{C.N}\n")

    # Timeline
    timestamps = []
    pattern_matches = Counter()
    crash_indicators = []

    for line in lines:
        if not line.strip():
            continue

        # Extract timestamp
        ts_match = re.match(r"(\d{4}/\d{1,2}/\d{1,2}[ \t]+\S+)", line)
        if ts_match:
            timestamps.append(ts_match.group(1))

        # Classify
        for label, pat in LOG_PATTERNS.items():
            if re.search(pat, line):
                pattern_matches[label] += 1
                if label in ("TTS_Error", "MemoryWarning", "SocketEvent"):
                    crash_indicators.append(line[:120])
                break

    if timestamps:
        print(f"  [TIME] 時間範圍：{timestamps[0]} ~ {timestamps[-1]}")
        print(f"  [APP] 總行數：{len(lines)}")
        print(f"  🏷 含時間戳：{len(timestamps)}")

    if pattern_matches:
        print(f"\n{C.B}[STAT] Event Summary:{C.N}")
        for label, count in pattern_matches.most_common():
            cn = LOG_CN.get(label, label)
            marker = " [!]" if label in ("TTS_Error", "MemoryWarning") else ""
            print(f"  {cn}: {count}{marker}")

    # Idle timeout analysis
    timeouts = [l for l in lines if "Idle timeout" in l]
    if timeouts:
        print(f"\n{C.Y}[NET] Idle Timeouts：{len(timeouts)} 次{C.N}")
        for t in timeouts[:5]:
            print(f"  {t.strip()[:100]}")

    # Background task analysis
    bgtask = [l for l in lines if "BGTaskScheduler" in l or "bgTask" in l or "background window" in l]
    if bgtask:
        active_pip = sum(1 for l in bgtask if "PiP 活躍中，跳過" in l)
        scheduled = sum(1 for l in bgtask if "已排程" in l)
        print(f"\n{C.CYN}[TASK] Background Tasks:{C.N}")
        print(f"  BGTask scheduled：{scheduled} 次")
        print(f"  Skipped (PiP active)：{active_pip} 次")

    # FPS analysis
    fps_lines = [l for l in lines if "fps ->" in l]
    if fps_lines:
        fps_values = []
        for l in fps_lines:
            m = re.search(r"fps -> ([\d.]+)", l)
            if m:
                fps_values.append(float(m.group(1)))
        if fps_values:
            print(f"\n  [FPS] PIP more frames率：min={min(fps_values)} max={max(fps_values)} avg={sum(fps_values)/len(fps_values):.1f}")

    if crash_indicators:
        print(f"\n{C.R}[ALERT] Top 3 Alert Events:{C.N}")
        for ci in crash_indicators[:3]:
            print(f"  {ci}")


# ── Main dispatch ──

def analyze(path):
    name = path.name.lower()

    if name.endswith(".ips") and not name.endswith(".ips.ca.synced.txt"):
        # Pure IPS crash report (single JSON)
        try:
            # 嘗試當作 single-line JSON（最新格式 compressed）
            first = path.read_text(encoding="utf-8", errors="replace").split("\n")[0].strip()
            if first.startswith("{"):
                parse_ips(path)
            else:
                print(f"{C.R}Unrecognized IPS format{C.N}")
        except Exception as e:
            print(f"{C.R}Error parsing IPS: {e}{C.N}")

    elif name.endswith(".ips.ca.synced.txt"):
        # Apple Analytics
        try:
            parse_analytics(path)
        except Exception as e:
            print(f"{C.R}Error parsing analytics: {e}{C.N}")

    else:
        # 一般 log
        try:
            parse_log(path)
        except Exception as e:
            print(f"{C.R}Error parsing log: {e}{C.N}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    target = Path(sys.argv[1])
    if target.is_dir():
        # Scan all known formats
        for ext in ("*.ips", "*.txt", "*.log"):
            for f in sorted(target.glob(ext)):
                print(f"\n{C.M}{'='*60}{C.N}")
                print(f"{C.M}File: {f.name}{C.N}")
                try:
                    analyze(f)
                except Exception as e:
                    print(f"{C.R}  Error: {e}{C.N}")
    elif target.is_file():
        analyze(target)
    else:
        print(f"{C.R}File not found: {target}{C.N}")
        sys.exit(1)

    print(f"\n{C.G}Done.{C.N}")
