#!/usr/bin/env python3
"""
dSYM Crash Tracer — 一行指令定位 crash 根因

用法:
  python crash_trace.py crash.ips -s symbols.txt     # Windows
  python crash_trace.py crash.ips -s ./dSYMs         # macOS (atos 行號)
  python crash_trace.py crash.ips                    # 純 offset
"""
import sys, os, json, re, argparse, subprocess
from pathlib import Path

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")

BUG_LABEL = {"309": "Stack Overflow", "288": "CPU Limit", "198": "Memory", "210": "Watchdog"}


def load_text_symbols(path):
    symbols = {}
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        m = re.match(r'^([0-9a-fA-F]+)\s+\S+\s+F\s+__TEXT,__text\s+(.+)$', line)
        if not m:
            m = re.match(r'^([0-9a-fA-F]+)\s+[tT]\s+(.+)$', line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        name = m.group(2).strip().replace(".hidden ", "")
        offset = addr - 0x100000000 if addr >= 0x100000000 else addr
        symbols[offset] = name
    return symbols


def demangle_swift(name):
    words = re.findall(r'(\d+)([A-Za-z][A-Za-z0-9]*)', name)
    if not words:
        return name[:80]
    parts = [w for _, w in words]
    meaningful = [p for p in parts if not re.match(r'^[A-F0-9]+LL$', p) and not re.match(r'^T[A-Z]', p)]
    return ".".join(meaningful[-3:]) if len(meaningful) > 3 else ".".join(meaningful)


class AtosResolver:
    def __init__(self, dsym_dir):
        self.dsym_dir = Path(dsym_dir)
        self.cache = {}

    def _find_dwarf(self, image_name):
        for dsym in self.dsym_dir.rglob(f"{image_name}*.dSYM"):
            dwarf = dsym / "Contents" / "Resources" / "DWARF" / image_name
            if dwarf.exists():
                return dwarf
        return None

    def lookup(self, image_name, image_base, runtime_addr, arch="arm64"):
        if sys.platform != "darwin":
            return None
        key = (image_name, runtime_addr)
        if key in self.cache:
            return self.cache[key]
        dwarf = self._find_dwarf(image_name)
        if not dwarf:
            self.cache[key] = None
            return None
        try:
            r = subprocess.run(["atos", "-o", str(dwarf), "-arch", arch, "-l", hex(image_base), hex(runtime_addr)],
                             capture_output=True, text=True, timeout=5)
            out = r.stdout.strip()
            if out and out != hex(runtime_addr):
                out = re.sub(r'\s*\(in\s+\S+\)', '', out)
                self.cache[key] = out
                return out
        except Exception:
            pass
        self.cache[key] = None
        return None


class SymbolResolver:
    def __init__(self, symbols_path):
        self.text_symbols = {}
        self.atos = None
        p = Path(symbols_path)
        if p.is_dir():
            if sys.platform == "darwin":
                self.atos = AtosResolver(p)
            for f in p.rglob("symbols_text.txt"):
                self.text_symbols.update(load_text_symbols(str(f)))
            for f in p.rglob("symbol_map.txt"):
                self.text_symbols.update(load_text_symbols(str(f)))
        elif p.suffix == ".txt":
            self.text_symbols = load_text_symbols(str(p))

    def lookup(self, image_name, image_base, offset=None, runtime_addr=None):
        if self.atos and runtime_addr and image_base:
            result = self.atos.lookup(image_name, image_base, runtime_addr)
            if result:
                return result
        if offset is not None and self.text_symbols:
            best, best_dist = None, float("inf")
            for a in sorted(self.text_symbols.keys()):
                d = abs(a - offset)
                if d < best_dist:
                    best_dist, best = d, a
                elif a > offset and d > best_dist:
                    break
            if best is not None and best_dist < 0x10000:
                name = demangle_swift(self.text_symbols[best])
                return name if best_dist == 0 else f"{name} +0x{best_dist:x}"
        return None


def classify_frame(func_name, is_recursive, idx, total):
    """自動分類 frame 角色"""
    fn = func_name.lower() if func_name else ""
    if "completetaskwithclosure" in fn:
        return "async_root"
    if idx == total - 1:
        return "async_root"
    if "fatalerror" in fn:
        return "swift_runtime"
    if "mach_msg" in fn or "cfrunloop" in fn:
        return "system_idle"
    if is_recursive:
        return "recursion"
    if idx <= 2:
        return "crash_site"
    if any(k in fn for k in ["performconnect", "connect", "publish", "listen"]):
        return "entry_point"
    if any(k in fn for k in ["serialize", "deserialize", "read", "write", "decode", "encode"]):
        return "data_processing"
    if any(k in fn for k in ["thunk", "ty", "tq", "tatq"]):
        return "async_thunk"
    return "general"


def build_call_tree(frames_info):
    """從 frame 陣列重建調用鏈樹狀結構 (bottom-up)"""
    lines = []
    # frames_info is from inner(0) to outer(N-1), we want outer to inner
    for i in range(len(frames_info) - 1, -1, -1):
        off, name, role, rec = frames_info[i]
        indent = "  " * (len(frames_info) - 1 - i) if i < len(frames_info) - 1 else ""
        prefix = "└─ " if i < len(frames_info) - 1 else ""
        rec_mark = f" [RECUR x{rec}]" if rec and rec >= 3 else ""
        role_tag = f"  <{role}>" if role else ""
        lines.append(f"{indent}{prefix}{name}{rec_mark}{role_tag}")
    return "\n".join(lines)


def analyze(ips_path, symbols_path=None):
    text = Path(ips_path).read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    crash = json.loads("".join(lines[1:]))
    meta = json.loads(lines[0])

    resolver = SymbolResolver(symbols_path) if symbols_path else None
    bt = str(crash.get("bug_type", "?"))
    exc = crash.get("exception", {})
    ft_idx = crash.get("faultingThread", 0)
    queue = crash.get("legacyInfo", {}).get("threadTriggered", {}).get("queue", "")
    vminfo = crash.get("vmRegionInfo", "")
    threads = crash.get("threads", [])
    images = crash.get("usedImages", [])

    img_map = {}
    for i, img in enumerate(images):
        img["_idx"] = i
        img_map[i] = img
    app_base = images[0].get("base") if images else None
    crash_uuid = meta.get("slice_uuid", "?")[:8]

    # ── 概覽 ──
    label = BUG_LABEL.get(bt, "Unknown")
    has_atos = resolver and resolver.atos is not None
    mode = "atos" if has_atos else ("symbols" if resolver else "offsets")
    is_stack_guard = "Stack Guard" in vminfo
    print(f"[{label}] bug_type {bt}  |  thread #{ft_idx}  |  queue: {queue}")
    print(f"exception: {exc.get('type','?')}/{exc.get('signal','?')}  |  UUID: {crash_uuid}  |  mode: {mode}")
    if is_stack_guard:
        stacks = re.findall(r'\[\s*(\d+K)\]\s+.*thread\s+(\d+)', vminfo)
        for sz, tid in stacks:
            print(f"stack overflow: thread {tid} {sz} -> hit Stack Guard")
    print()

    if ft_idx >= len(threads):
        print("(no crash thread)")
        return

    t = threads[ft_idx]
    frames = t.get("frames", [])
    tqueue = t.get("queue", "")

    # ── 蒐集 frame 資訊 ──
    offset_counts = {}
    for f in frames:
        off = f.get("imageOffset", 0)
        offset_counts[off] = offset_counts.get(off, 0) + 1

    frames_info = []
    for i, f in enumerate(frames):
        off = f.get("imageOffset", 0)
        img_idx = f.get("imageIndex", -1)
        img = img_map.get(img_idx, {})
        img_name = img.get("name", f"img{img_idx}")
        img_base = img.get("base", 0)
        rec = offset_counts.get(off, 1)

        func_name = None
        runtime_addr = img_base + off if img_base else None
        if resolver:
            func_name = resolver.lookup(
                image_name=img_name,
                image_base=img_base,
                offset=off if img_idx == 0 else None,
                runtime_addr=runtime_addr
            )
        if not func_name:
            s = f.get("symbol", "")
            func_name = s if s and s != "???" else img_name
        if not func_name or func_name == "???":
            func_name = "???"

        role = classify_frame(func_name, rec >= 3, i, len(frames))
        frames_info.append((off, func_name, role, rec))

    # ── Frame 明細表 ──
    print(f"--- Crash Thread #{ft_idx} ({tqueue}) ---")
    print(f"{'#':>3}  {'offset':>10}  {'function':<55} {'note'}")
    print(f"{'─'*3}  {'─'*10}  {'─'*55} {'─'*15}")
    for i, (off, func_name, role, rec) in enumerate(frames_info):
        offset_str = f"+0x{off:x}"
        note = ""
        if rec >= 3:
            note += f"RECUR x{rec}"
        elif role == "data_processing":
            note += "data"
        elif role == "entry_point":
            note += "entry"
        elif role == "async_root":
            note += "root"
        elif role == "swift_runtime":
            note += "runtime"
        print(f"{i:3d}  {offset_str:>10}  {func_name:<55} {note}")

    print()

    # ── 調用鏈樹狀圖 ──
    recursive = [(off, name, rec) for off, name, role, rec in frames_info if rec >= 3]
    if recursive:
        print("--- 調用鏈 (outer -> inner) ---")
        # only show frames that have useful names
        named = [(o, n, r, rec) for o, n, r, rec in frames_info if n and n != "???"]
        tree = build_call_tree(frames_info)
        print(tree)
        print()

        # ── 自動分析 ──
        print("--- 結構分析 ---")
        r_names = [name for _, name, rec in recursive]

        # 分析1: 遞迴發生在同一模組的 extension 上？
        has_extension_recursion = any(
            re.search(r'(\w+)V\d+(\w+)E\d+', name) for name in r_names
        )
        has_module_prefix = any(
            re.match(r'^\w+\.\w+\.\w+', name) for name in r_names
        )

        # 分析2: 遞迴函數特徵
        sample_name = r_names[0] if r_names else ""
        if "withUnsafeBytes" in sample_name:
            print("  遞迴函數: Data.withUnsafeBytes (RTMPHaishinKit 模組內擴展)")
            print("  -> 這是自定義 extension Data { withUnsafeBytes } 自調用造成的無限遞迴")
            print("  -> 模組內所有 data.withUnsafeBytes 呼叫都走到這個自訂版，而非 Foundation 原生版")
            print("  -> 修法: 刪除 RTMPHandshake.swift 中的 extension Data { withUnsafeBytes ... }")
        elif "supportedProtocols" in sample_name:
            print("  遞迴函數: RTMPConnection.supportedProtocols lazy init guard")
            print("  -> static let 在 Swift 跨模組時走 lazy init，初始化過程中觸發自己")
            print("  -> 修法: 改用檔案層級 private let，不走 lazy init")
        elif "CompleteTask" in sample_name or "completeTask" in sample_name:
            print("  遞迴發生在 Swift async task 完成階段")
            print("  -> 可能是深層 async call chain 導致 cooperative thread stack 耗盡")
            print("  -> 修法: 加節流 gate，減少同時在飛的 Task 數量")
        else:
            # 通用分析: 找出遞迴函數所在的層級
            rec_indices = [i for i, (_, _, r, rec) in enumerate(frames_info) if rec >= 3]
            if rec_indices:
                first_rec = rec_indices[0]
                # 找最接近的 entry_point 或 data_processing
                context = None
                for i in range(first_rec + 1, len(frames_info)):
                    _, _, role, _ = frames_info[i]
                    if role in ("entry_point", "data_processing"):
                        context = frames_info[i][1]
                        break
                print(f"  遞迴函數: {sample_name}")
                if context:
                    print(f"  調用上下文: {context}")
                print(f"  遞迴深度: {max(rec for _, _, _, rec in recursive)} 層")
                print("  -> 請從上面調用鏈確認呼叫關係，檢查是否有自調用或間接遞迴")

        # 分析3: cooperative thread 狀況
        print()
        coop_threads = []
        for i, t in enumerate(threads):
            if i == ft_idx:
                continue
            if "cooperative" in (t.get("queue") or ""):
                fs = t.get("frames", [])
                if fs:
                    coop_threads.append((i, fs[0].get("symbol", "???")))
        if coop_threads:
            print(f"  其他 cooperative thread: {len(coop_threads)} 個")
            for tid, top in coop_threads[:3]:
                print(f"    thread {tid}: {top}")
            if any("mach_msg" in top for _, top in coop_threads):
                print("  -> cooperative pool 有空閒線程，不是 pool exhaustion")

    print()


def main():
    parser = argparse.ArgumentParser(description="dSYM Crash Tracer")
    parser.add_argument("ips", help=".ips crash 檔案")
    parser.add_argument("-s", "--symbols", help="符號表檔案或 dSYM 目錄")
    parser.add_argument("--json", "-j", action="store_true", help="JSON 輸出")
    args = parser.parse_args()
    analyze(args.ips, args.symbols)


if __name__ == "__main__":
    main()
