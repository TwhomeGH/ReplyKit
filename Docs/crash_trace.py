#!/usr/bin/env python3
"""
dSYM Crash Tracer — 一行指令定位 crash 根因 (支援 macOS atos 精確到行號)

用法:
  python crash_trace.py crash.ips                              # 基本
  python crash_trace.py crash.ips -s symbols.txt               # Windows: 文字符號表
  python crash_trace.py crash.ips -s ./dSYMs                   # macOS: dSYM 目錄 (atos 行號)
  python crash_trace.py crash.ips --json                       # JSON 輸出
"""
import sys, os, json, re, argparse, subprocess
from pathlib import Path

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")

BUG_LABEL = {"309": "Stack Overflow", "288": "CPU Limit", "198": "Memory", "210": "Watchdog"}

RECURSION_CAUSES = [
    (["_WZ", "globalinit_", "vau", "supportedProtocols"],
     "static let lazy 初始化遞迴", "把 static let 改成 computed var"),
    (["completeTaskWithClosure", "mixerVideoContinuation", "mixerAudioContinuation", "VideoCaptureUnit", "AudioCaptureUnit"],
     "AsyncStream yield() 同步鏈", "在 mixer(_:didOutput:) 用 Task { } 包 yield() 斷鏈"),
    (["MetalRealTimeNoiseSuppressor", "runMetalKernel"],
     "Metal noise suppressor 函數重入", "加上 isEnqueuing gate + rebuildAudio 時 explicit cleanup"),
    (["DispatchSemaphore", "semaphore.wait"],
     "DispatchSemaphore 阻塞 cooperative thread", "移出 cooperative pool 或換 async"),
    (["__swift_coroFrameAllocStub"],
     "Swift async frame alloc 遞迴", "減少深層 async call 或加節流 gate"),
]


def load_text_symbols(path):
    """從文字符號表載入 {offset: name} (Windows)"""
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
        if addr >= 0x100000000:
            offset = addr - 0x100000000
        else:
            offset = addr
        symbols[offset] = name
    return symbols


def demangle_swift(name):
    """簡化 Swift mangled name"""
    words = re.findall(r'(\d+)([A-Za-z][A-Za-z0-9]*)', name)
    if not words:
        return name[:80]
    parts = [w for _, w in words]
    meaningful = [p for p in parts if not re.match(r'^[A-F0-9]+LL$', p) and not re.match(r'^T[A-Z]', p)]
    n = len(meaningful)
    if n <= 3:
        return ".".join(meaningful)
    return ".".join(meaningful[-3:])


class AtosResolver:
    """macOS 用 atos 精確到行號"""

    def __init__(self, dsym_dir):
        self.dsym_dir = Path(dsym_dir)
        self.cache = {}  # (image_name, runtime_addr) -> "symbol (file:line)"

    def _find_dwarf(self, image_name):
        """找 dSYM 內的 DWARF binary"""
        for dsym in self.dsym_dir.rglob(f"{image_name}*.dSYM"):
            dwarf = dsym / "Contents" / "Resources" / "DWARF" / image_name
            if dwarf.exists():
                return dwarf
        return None

    def lookup(self, image_name, image_base, runtime_addr, arch="arm64"):
        """atos 查詢: 回傳 "symbolName (file:line)" 或 "symbolName +offset" 或 None"""
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
            result = subprocess.run(
                ["atos", "-o", str(dwarf), "-arch", arch,
                 "-l", hex(image_base), hex(runtime_addr)],
                capture_output=True, text=True, timeout=5
            )
            out = result.stdout.strip()
            if out and out != hex(runtime_addr):
                # atos 格式: "symbolName (in imageName) (file:line)"
                # 或:       "symbolName (in imageName)"
                # 去掉 "(in imageName)" 部分
                out = re.sub(r'\s*\(in\s+\S+\)', '', out)
                self.cache[key] = out
                return out
        except Exception:
            pass
        self.cache[key] = None
        return None


class SymbolResolver:
    """統一的符號解析器: macOS 用 atos，Windows 用文字符號表"""

    def __init__(self, symbols_path):
        self.text_symbols = {}
        self.atos = None
        p = Path(symbols_path)

        if p.is_dir():
            # 目錄 — 可能是 dSYM 目錄
            if sys.platform == "darwin":
                self.atos = AtosResolver(p)
            # 也嘗試載入文字符號表作為 fallback
            for f in p.rglob("symbols_text.txt"):
                self.text_symbols.update(load_text_symbols(str(f)))
            for f in p.rglob("symbol_map.txt"):
                self.text_symbols.update(load_text_symbols(str(f)))
        elif p.suffix == ".txt":
            self.text_symbols = load_text_symbols(str(p))

    def lookup(self, image_name, image_base, offset=None, runtime_addr=None):
        """解析符號，回傳函數名 [+offset] [(file:line)]"""
        if self.atos and runtime_addr and image_base:
            result = self.atos.lookup(image_name, image_base, runtime_addr)
            if result:
                return result

        if offset is not None and self.text_symbols:
            sorted_addrs = sorted(self.text_symbols.keys())
            best, best_dist = None, float("inf")
            for a in sorted_addrs:
                d = abs(a - offset)
                if d < best_dist:
                    best_dist, best = d, a
                elif a > offset and d > best_dist:
                    break
            if best is not None and best_dist < 0x10000:
                name = demangle_swift(self.text_symbols[best])
                if best_dist == 0:
                    return name
                return f"{name} +0x{best_dist:x}"

        return None


def analyze(ips_path, symbols_path=None):
    text = Path(ips_path).read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    crash = json.loads("".join(lines[1:]))

    resolver = SymbolResolver(symbols_path) if symbols_path else None

    bt = str(crash.get("bug_type", "?"))
    exc = crash.get("exception", {})
    ft_idx = crash.get("faultingThread", 0)
    queue = crash.get("legacyInfo", {}).get("threadTriggered", {}).get("queue", "")
    vminfo = crash.get("vmRegionInfo", "")
    threads = crash.get("threads", [])
    images = crash.get("usedImages", [])

    # 建立 imageIndex -> image info 對照
    img_map = {}
    for i, img in enumerate(images):
        img["_idx"] = i
        img_map[i] = img

    app_base = images[0].get("base") if images else None
    app_image = images[0] if images else {}

    # ── 輸出 header ──
    label = BUG_LABEL.get(bt, "Unknown")
    has_atos = resolver and resolver.atos is not None
    mode = "atos (行號)" if has_atos else ("symbols" if resolver else "offsets only")
    print(f"bug_type {bt} ({label})  |  queue: {queue}  |  thread #{ft_idx}  |  mode: {mode}")
    print(f"exception: {exc.get('type','?')}/{exc.get('signal','?')}")

    if "Stack Guard" in vminfo:
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

    print(f"--- Crash Thread #{ft_idx} ({tqueue}) ---")
    col_w = 55 if has_atos else 50
    print(f"{'#':>3}  {'offset':>10}  {'function'}")
    print(f"{'─'*3}  {'─'*10}  {'─'*col_w}")

    offset_counts = {}
    for f in frames:
        off = f.get("imageOffset", 0)
        offset_counts[off] = offset_counts.get(off, 0) + 1

    all_func_names = []

    for i, f in enumerate(frames):
        off = f.get("imageOffset", 0)
        img_idx = f.get("imageIndex", -1)
        repeat = f" (x{offset_counts[off]})" if offset_counts.get(off, 1) > 1 else ""

        img = img_map.get(img_idx, {})
        img_name = img.get("name", f"img{img_idx}")
        img_base = img.get("base", 0)
        arch = img.get("arch", "arm64")

        # 符號化
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

        all_func_names.append(func_name)

        offset_str = f"+0x{off:x}"
        mark = " [!] RECUR" if offset_counts.get(off, 1) >= 3 else ""
        print(f"{i:3d}  {offset_str:>10}  {func_name}{repeat}{mark}")

    print()

    # ── 遞迴檢測 ──
    rec = {k: v for k, v in offset_counts.items() if v >= 3 and k != 0}
    if rec:
        print(">>> 遞迴檢測 <<<")
        for off, count in sorted(rec.items(), key=lambda x: -x[1]):
            func = None
            if resolver:
                runtime_addr = app_base + off if app_base else None
                func = resolver.lookup(
                    image_name=app_image.get("name", ""),
                    image_base=app_base,
                    offset=off,
                    runtime_addr=runtime_addr
                )
            print(f"  +0x{off:x} 出現 {count} 次  ->  {func or '?'}")

        cause, fix = detect_cause(all_func_names)
        if cause:
            print(f"\n  根因: {cause}")
            print(f"  修法: {fix}")
        else:
            print(f"\n  (無法自動判定根因)")
        print()

    # ── 其他 cooperative thread ──
    blocked = []
    for i, t in enumerate(threads):
        if i == ft_idx or not t.get("frames"):
            continue
        if "cooperative" in (t.get("queue") or ""):
            fs = t.get("frames", [])
            blocked.append((i, [f.get("symbol", "???") for f in fs[:3]]))

    if blocked:
        print("--- 其他 cooperative thread ---")
        for tid, tops in blocked:
            print(f"  Thread {tid}: {', '.join(tops)}")
        print()


def detect_cause(all_func_names):
    all_text = " ".join(all_func_names)
    for keywords, desc, fix in RECURSION_CAUSES:
        hits = [kw for kw in keywords if kw.lower() in all_text.lower()]
        if len(hits) >= 2:
            return desc, fix
        if len(hits) == 1 and len(keywords) == 1:
            return desc, fix
    return None, None


def main():
    parser = argparse.ArgumentParser(description="dSYM Crash Tracer")
    parser.add_argument("ips", help=".ips crash 檔案")
    parser.add_argument("-s", "--symbols", help="符號表檔案或 dSYM 目錄")
    parser.add_argument("--json", "-j", action="store_true", help="JSON 輸出")
    args = parser.parse_args()

    if args.json:
        text = Path(args.ips).read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        crash = json.loads("".join(lines[1:]))
        ft = crash.get("faultingThread", 0)
        t = crash.get("threads", [])[ft] if ft < len(crash.get("threads", [])) else {}
        frames = t.get("frames", [])
        offsets = {}
        for f in frames:
            o = f.get("imageOffset", 0)
            offsets[hex(o)] = offsets.get(hex(o), 0) + 1
        result = {
            "bug_type": crash.get("bug_type"),
            "queue": crash.get("legacyInfo", {}).get("threadTriggered", {}).get("queue"),
            "thread": ft,
            "frames": len(frames),
            "recursions": {k: v for k, v in offsets.items() if v >= 3},
            "stack_guard": "Stack Guard" in crash.get("vmRegionInfo", "")
        }
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        analyze(args.ips, args.symbols)


if __name__ == "__main__":
    main()
