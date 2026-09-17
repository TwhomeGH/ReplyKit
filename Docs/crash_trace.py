#!/usr/bin/env python3
"""
dSYM Crash Tracer — 一行指令定位 crash 根因

用法:
  python crash_trace.py crash.ips -s <含 dSYM 的目錄>   # 建議：會驗證 UUID 才符號化
  python crash_trace.py crash.ips -s symbols_text.txt    # 舊式 nm 符號表（會檢查模組名）
  python crash_trace.py crash.ips                        # 純 offset

修正重點:
  * 符號化前先用 crash 的 slice_uuid 比對 dSYM（避免拿錯 binary / 舊 build 的符號表）。
    舊式 symbols_text.txt 無法驗證 UUID，改用「模組名是否出現在符號中」做防呆。
  * bug_type 只是訊號種類；真正死因讀 termination（例如 0x8BADF00D = watchdog deadlock），
    不再一律把 bug_type 309 當成 Stack Overflow。
  * 若主執行緒卡在 lock，會自動找出持有 lock 的執行緒並印出跨執行緒死鎖鏈。
"""
import sys, json, re, struct, shutil, subprocess, uuid as uuidlib, argparse
from pathlib import Path
from bisect import bisect_right

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")

# bug_type 只描述訊號類型，真正的死因見 termination_label()
BUG_LABEL = {
    "309": "EXC_CRASH/SIGKILL",
    "288": "CPU Limit",
    "198": "Memory",
    "210": "Watchdog",
}

LOCK_WAIT = (
    "__psynch_mutexwait", "__ulock_wait", "semaphore_wait", "semaphore_timedwait",
    "_dispatch_sema4_wait", "_dispatch_semaphore_wait_slow",
)
GRAPH_MARKERS = (
    "UpdateGroup", "MovableLock", "GraphHost", "AG::Graph", "AttributeGraph",
    "flushTransactions", "UpdateStack",
)
SYNC_TO_MAIN = ("_dispatch_sync_f_slow", "__DISPATCH_WAIT_FOR_QUEUE__",
                "_dispatch_barrier_sync", "_dispatch_sync")


# ────────────────────────────── 符號解析 ──────────────────────────────

def load_text_symbols(path):
    """舊式 nm 輸出：`<hex> <t/T> <name>` 或 `<hex> F __TEXT,__text <name>`。"""
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


_DEMANGLE_CACHE = {}
_DEMANGLER = None      # None=未探測; False=沒有; 否則為指令前綴 list


def _demangler():
    """優先用 Swift 官方的 swift-demangle（若已安裝），否則退回啟發式。"""
    global _DEMANGLER
    if _DEMANGLER is None:
        exe = shutil.which('swift-demangle')
        if exe:
            _DEMANGLER = [exe]
        else:
            exe = shutil.which('swift')
            _DEMANGLER = [exe, 'demangle'] if exe else False
    return _DEMANGLER


def _heuristic_demangle(name):
    """沒有 swift-demangle 時的粗略還原（讀 Swift 的長度前綴標識字）。"""
    s = name
    for pfx in ('_$s', '$s', '_$S', '$S', '_T'):
        if s.startswith(pfx):
            s = s[len(pfx):]
            break
    parts, i = [], 0
    while i < len(s):
        if s[i].isdigit():
            j = i
            while j < len(s) and s[j].isdigit():
                j += 1
            n = int(s[i:j])
            ident = s[j:j + n]
            if len(ident) < n:
                break
            parts.append(ident)
            i = j + n
        else:
            i += 1
    return ".".join(parts) if parts else name[:80]


def demangle_swift(name):
    if name in _DEMANGLE_CACHE:
        return _DEMANGLE_CACHE[name]
    result = None
    cmd = _demangler()
    if cmd:
        try:
            r = subprocess.run(cmd + [name], capture_output=True, text=True, timeout=10)
            out = (r.stdout or '').strip().splitlines()
            if out and out[0]:
                line = out[0]
                if ' ---> ' in line:            # swift-demangle 會印 "<mangled> ---> <demangled>"
                    line = line.split(' ---> ', 1)[1]
                if line and line != name and not line.startswith(('error', 'warning')):
                    result = line
        except Exception:
            result = None
    if result is None:
        result = _heuristic_demangle(name)
    _DEMANGLE_CACHE[name] = result
    return result


class MachOSymbols:
    """直接解析 Mach-O（含 dSYM 的 DWARF 檔）的 nlist 符號表。

    在 Windows / macOS 都能跑（不需要 atos），並能讀出 LC_UUID 供比對，
    避免拿錯 binary 或舊 build 的符號表去符號化（本工具最常見的誤判來源）。
    """
    MH_MAGIC_64 = 0xfeedfacf
    LC_SEGMENT_64 = 0x19
    LC_SYMTAB = 0x2
    LC_UUID = 0x1b

    def __init__(self, path):
        self.path = str(path)
        self.uuid = None
        self.text_vmaddr = None
        self.symbols = []          # sorted [(vmaddr, name)]
        self._parse()

    def _parse(self):
        with open(self.path, 'rb') as fh:
            d = fh.read()
        if len(d) < 32 or struct.unpack('<I', d[:4])[0] != self.MH_MAGIC_64:
            raise ValueError('not a 64-bit little-endian Mach-O: %s' % self.path)
        ncmds = struct.unpack('<I', d[16:20])[0]
        off, symtab = 32, None
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack('<II', d[off:off + 8])
            if cmd == self.LC_UUID:
                self.uuid = str(uuidlib.UUID(bytes=bytes(d[off + 8:off + 24])))
            elif cmd == self.LC_SEGMENT_64:
                segname = d[off + 8:off + 24].split(b'\x00', 1)[0].decode('ascii', 'replace')
                if segname == '__TEXT':
                    self.text_vmaddr = struct.unpack('<Q', d[off + 24:off + 32])[0]
            elif cmd == self.LC_SYMTAB:
                symtab = struct.unpack('<IIII', d[off + 8:off + 24])
            off += cmdsize
        if symtab is None:
            raise ValueError('no LC_SYMTAB in %s' % self.path)
        if self.text_vmaddr is None:
            self.text_vmaddr = 0x100000000
        symoff, nsyms, stroff, _ = symtab
        syms = []
        for i in range(nsyms):
            b = symoff + i * 16
            n_strx, = struct.unpack('<I', d[b:b + 4])
            n_value, = struct.unpack('<Q', d[b + 8:b + 16])
            if n_value == 0:
                continue
            end = d.find(b'\x00', stroff + n_strx)
            if end < 0:
                continue
            syms.append((n_value, d[stroff + n_strx:end].decode('utf-8', 'replace')))
        syms.sort()
        self.symbols = syms

    def lookup(self, image_offset):
        """回傳 (name, delta) 或 None。image_offset 為 crash 報告的 imageOffset。"""
        if not self.symbols:
            return None
        addr = self.text_vmaddr + image_offset
        i = bisect_right(self.symbols, (addr,)) - 1
        if i < 0:
            return None
        vmaddr, name = self.symbols[i]
        delta = addr - vmaddr
        if delta > 0x20000:            # 距離太遠，視為無對應符號
            return None
        return name, delta


class AtosResolver:
    """macOS 專用：用 atos 把地址換成 `func (File.swift:行號)`。

    僅在 dSYM 已通過 UUID 驗證後才建立（呼叫端負責），避免拿錯 binary。
    """

    def __init__(self, dwarf_path):
        self.dwarf = str(dwarf_path)
        self.cache = {}

    def lookup(self, image_base, runtime_addr, arch="arm64"):
        if sys.platform != "darwin":
            return None
        key = (runtime_addr, arch)
        if key in self.cache:
            return self.cache[key]
        result = None
        try:
            r = subprocess.run(
                ["atos", "-o", self.dwarf, "-arch", arch, "-l", hex(image_base), hex(runtime_addr)],
                capture_output=True, text=True, timeout=5)
            out = (r.stdout or "").strip()
            if out and out != hex(runtime_addr):
                result = re.sub(r'\s*\(in\s+\S+\)', '', out)
        except Exception:
            result = None
        self.cache[key] = result
        return result


class SymbolResolver:
    """負責 image 0（主 binary）的符號化，並確保符號來源與 crash 相符。"""

    def __init__(self, symbols_path, slice_uuid=None, app_name=None):
        self.slice_uuid = slice_uuid
        self.app_name = app_name
        self.macho = None              # 通過 UUID 驗證的 MachOSymbols
        self.atos = None               # macOS 行號強化（僅在 UUID 驗證通過後）
        self.text_symbols = {}
        self.text_symbols_ok = False
        self.source = None
        self.uuid_match = None         # True / False / None(無法判定)
        self.warnings = []

        if symbols_path is None:
            return
        p = Path(symbols_path)

        if p.is_dir():
            dsyms = list(p.rglob('*.dSYM'))
            if p.name.endswith('.dSYM'):
                dsyms.append(p)
            for dsym in dsyms:
                dwarf_dir = dsym / 'Contents' / 'Resources' / 'DWARF'
                if not dwarf_dir.is_dir():
                    continue
                for binfile in sorted(dwarf_dir.iterdir()):
                    if not binfile.is_file():
                        continue
                    try:
                        m = MachOSymbols(binfile)
                    except Exception:
                        continue
                    if self.slice_uuid and m.uuid == self.slice_uuid:
                        if app_name and binfile.name != app_name:
                            continue
                        self.macho = m
                        self.uuid_match = True
                        self.source = str(binfile)
                        if sys.platform == "darwin" and shutil.which("atos"):
                            self.atos = AtosResolver(binfile)
                        break
                if self.macho:
                    break
            if self.macho is None:
                self.uuid_match = False
                if self.slice_uuid:
                    self.warnings.append(
                        "找不到 UUID=%s 相符的 dSYM；image 0 將不做符號化（避免張冠李戴）。"
                        % self.slice_uuid)
            for f in list(p.rglob('symbols_text.txt')) + list(p.rglob('symbol_map.txt')):
                self.text_symbols.update(load_text_symbols(str(f)))
            self.text_symbols_ok = self._check_text_module()
            if self.macho is None and self.text_symbols and not self.text_symbols_ok:
                self.warnings.append(
                    "目錄內的 symbols_text.txt 找不到模組 '%s' 的符號，疑似拿錯 binary，已停用。"
                    % app_name)

        elif p.suffix == '.txt':
            self.text_symbols = load_text_symbols(str(p))
            self.text_symbols_ok = self._check_text_module()
            if self.text_symbols and not self.text_symbols_ok:
                self.warnings.append(
                    "符號表 %s 找不到模組 '%s' 的符號，疑似拿錯 binary（例如把 appex 的符號表"
                    "套到主 App）；已停用以免誤判。請改用 -s 指向含正確 dSYM 的目錄。"
                    % (p.name, app_name))

    def _check_text_module(self):
        if not self.text_symbols or not self.app_name:
            return False
        needle = "%d%s" % (len(self.app_name), self.app_name)   # Swift mangling 的模組前綴
        return any(needle in n for n in self.text_symbols.values())

    def lookup(self, image_name, image_base, offset=None, runtime_addr=None):
        if self.macho is not None:
            if self.atos and runtime_addr is not None and image_base:
                atos_hit = self.atos.lookup(image_base, runtime_addr)
                if atos_hit:
                    return atos_hit
            if offset is None:
                return None
            hit = self.macho.lookup(offset)
            if not hit:
                return None
            name, delta = hit
            shown = demangle_swift(name) if name.startswith(('_$s', '$s')) else name
            return shown if delta == 0 else "%s +0x%x" % (shown, delta)
        if self.text_symbols_ok and self.text_symbols:
            keys = sorted(self.text_symbols)
            i = bisect_right(keys, offset) - 1
            if i >= 0:
                best, dist = keys[i], offset - keys[i]
                if dist < 0x10000:
                    name = demangle_swift(self.text_symbols[best])
                    return name if dist == 0 else "%s +0x%x" % (name, dist)
        return None


# ────────────────────────────── 死因判定 ──────────────────────────────

def termination_label(crash):
    """從 termination 判斷真正死因（比 bug_type 精確）。"""
    term = crash.get('termination') or {}
    reasons = term.get('reasons') or []
    joined = ' '.join(str(r) for r in reasons)
    low = joined.lower()
    code = term.get('code')
    if code == 0x8BADF00D or '8badf00d' in low:
        return 'Watchdog Deadlock (0x8BADF00D)' if 'deadlock' in low \
            else 'Watchdog Transgression (0x8BADF00D)'
    if code == 0xDEAD10CC or 'dead10cc' in low:
        return 'Watchdog File Lock (0xDEAD10CC)'
    if code == 0xC00010FF or 'c00010ff' in low:
        return 'CPU Limit (0xC00010FF)'
    if code == 0xBAADCAFE or 'baadcafe' in low:
        return 'Bad Memory Access'
    if reasons:
        first = str(reasons[0]).split('|')[0].strip()
        if first:
            return first[:80]
    return None


def short_name(name):
    """把長到爆的 Swift 還原名縮短，只為了報表可讀（不影響符號判定）。"""
    s = re.sub(r'\((\w+) in [_A-F0-9]{8,}\)', r'\1', name)
    s = re.sub(r'\b(?:Swift|Foundation|Network|CoreGraphics|CoreFoundation|ObjectiveC)\.', '', s)
    s = re.sub(r'\s*->\s*\(\)$', '', s)
    return re.sub(r'\s+', ' ', s).strip()


def classify_frame(func_name, is_recursive, idx, total):
    fn = (func_name or "").lower()
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
    lines = []
    for i in range(len(frames_info) - 1, -1, -1):
        off, name, role, rec = frames_info[i]
        indent = "  " * (len(frames_info) - 1 - i) if i < len(frames_info) - 1 else ""
        prefix = "└─ " if i < len(frames_info) - 1 else ""
        rec_mark = f" [RECUR x{rec}]" if rec and rec >= 3 else ""
        role_tag = f"  <{role}>" if role else ""
        lines.append(f"{indent}{prefix}{name}{rec_mark}{role_tag}")
    return "\n".join(lines)


# ────────────────────────────── 主流程 ──────────────────────────────

def frame_name(f, img_map, resolver, app_name):
    s = f.get('symbol')
    if s and s != '???':
        return s
    idx = f.get('imageIndex', -1)
    img = img_map.get(idx, {})
    name = img.get('name', 'img%d' % idx)
    if idx == 0 and resolver is not None:
        base = img.get('base', 0)
        r = resolver.lookup(name, base, offset=f.get('imageOffset', 0),
                            runtime_addr=base + f.get('imageOffset', 0))
        if r:
            return r
    return name


def thread_frames(thread, img_map, resolver, app_name):
    return [(f.get('imageIndex', -1), frame_name(f, img_map, resolver, app_name))
            for f in thread.get('frames', [])]


def deadlock_summary(crash, img_map, resolver, app_name, ft_idx):
    """主執行緒卡在 lock 時，找出持有者並描述跨執行緒死鎖。"""
    threads = crash.get('threads', [])
    if ft_idx >= len(threads):
        return None
    main_names = [n for _, n in thread_frames(threads[ft_idx], img_map, resolver, app_name)]
    if not any(any(k in n for k in LOCK_WAIT) for n in main_names[:4]):
        return None

    holders = []
    for ti, th in enumerate(threads):
        if ti == ft_idx:
            continue
        pairs = thread_frames(th, img_map, resolver, app_name)
        joined = ' | '.join(n for _, n in pairs)
        if any(g in joined for g in GRAPH_MARKERS) and any(s in joined for s in SYNC_TO_MAIN):
            holders.append((ti, th.get('queue') or th.get('name') or '?', pairs))

    if not holders:
        return "主執行緒卡在 lock（%s），但找不到明顯的跨執行緒持有者。" % main_names[0]

    lines = ["偵測到跨執行緒死鎖："]
    for ti, queue, pairs in holders:
        sync_frame = next((n for _, n in pairs if any(s in n for s in SYNC_TO_MAIN)), pairs[0][1])
        app_frames = [n for idx, n in pairs if idx == 0]
        lines.append("  持有 SwiftUI/AttributeGraph lock 的 thread #%d (%s)" % (ti, queue))
        lines.append("    在 graph update 中同步等 main queue：%s" % sync_frame)
        if app_frames:
            lines.append("    App 端堆疊（outer → inner，最內層通常就是觸發者）：")
            for n in app_frames:
                lines.append("      - %s" % short_name(n))
    lines.append("  → main 等 movable lock、該 thread 等 main，互等即死鎖；watchdog 隨後砍掉 App。")
    return "\n".join(lines)


def analyze(ips_path, symbols_path=None, as_json=False):
    text = Path(ips_path).read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    crash = json.loads("".join(lines[1:]))
    meta = json.loads(lines[0])

    images = crash.get("usedImages", [])
    img_map = {}
    for i, img in enumerate(images):
        img["_idx"] = i
        img_map[i] = img
    app_name = images[0].get("name") if images else None

    resolver = SymbolResolver(symbols_path, slice_uuid=meta.get("slice_uuid"),
                              app_name=app_name) if symbols_path else None

    bt = str(crash.get("bug_type", "?"))
    exc = crash.get("exception", {})
    ft_idx = crash.get("faultingThread", 0)
    queue = crash.get("legacyInfo", {}).get("threadTriggered", {}).get("queue", "")
    vminfo = crash.get("vmRegionInfo", "") or ""
    threads = crash.get("threads", [])
    crash_uuid = meta.get("slice_uuid", "?")[:8]

    if resolver and resolver.macho:
        mode = "atos(UUID ✓)" if resolver.atos else "dSYM(UUID ✓)"
    elif resolver and resolver.text_symbols_ok:
        mode = "symbols"
    elif resolver:
        mode = "offsets"
    else:
        mode = "offsets"

    label = termination_label(crash) or BUG_LABEL.get(bt, "Unknown")

    if as_json:
        print(json.dumps({
            "bug_type": bt,
            "label": label,
            "termination": crash.get("termination"),
            "slice_uuid": meta.get("slice_uuid"),
            "faulting_thread": ft_idx,
            "queue": queue,
            "symbol_mode": mode,
            "warnings": resolver.warnings if resolver else [],
        }, ensure_ascii=False, indent=2))
        return

    # ── 概覽 ──
    print(f"[{label}] bug_type {bt}  |  thread #{ft_idx}  |  queue: {queue}")
    print(f"exception: {exc.get('type','?')}/{exc.get('signal','?')}  |  UUID: {crash_uuid}  |  mode: {mode}")
    term = crash.get("termination") or {}
    if term.get("reasons"):
        print(f"termination: {' '.join(str(r) for r in term['reasons'])[:220]}")
    if "Stack Guard" in vminfo:
        for sz, tid in re.findall(r'\[\s*(\d+K)\]\s+.*thread\s+(\d+)', vminfo):
            print(f"stack overflow: thread {tid} {sz} -> hit Stack Guard")
    for w in (resolver.warnings if resolver else []):
        print(f"⚠️  {w}")
    print()

    if ft_idx >= len(threads):
        print("(no crash thread)")
        return

    t = threads[ft_idx]
    frames = t.get("frames", [])
    tqueue = t.get("queue", "")

    offset_counts = {}
    for f in frames:
        off = f.get("imageOffset", 0)
        offset_counts[off] = offset_counts.get(off, 0) + 1

    frames_info = []
    for i, f in enumerate(frames):
        off = f.get("imageOffset", 0)
        name = frame_name(f, img_map, resolver, app_name)
        rec = offset_counts.get(off, 1)
        role = classify_frame(name, rec >= 3, i, len(frames))
        frames_info.append((off, name, role, rec))

    print(f"--- Crash Thread #{ft_idx} ({tqueue}) ---")
    print(f"{'#':>3}  {'offset':>10}  {'function':<55} {'note'}")
    print(f"{'─'*3}  {'─'*10}  {'─'*55} {'─'*15}")
    for i, (off, name, role, rec) in enumerate(frames_info):
        note = ""
        if rec >= 3:
            note = f"RECUR x{rec}"
        elif role in ("data_processing", "entry_point", "async_root", "swift_runtime"):
            note = {"data_processing": "data", "entry_point": "entry",
                    "async_root": "root", "swift_runtime": "runtime"}[role]
        print(f"{i:3d}  {('+0x%x' % off):>10}  {name:<55} {note}")
    print()

    dl = deadlock_summary(crash, img_map, resolver, app_name, ft_idx)
    if dl:
        print("--- 死鎖分析 ---")
        print(dl)
        print()

    recursive = [(off, name, rec) for off, name, role, rec in frames_info if rec >= 3]
    if recursive:
        print("--- 調用鏈 (outer -> inner) ---")
        print(build_call_tree(frames_info))
        print()
        sample_name = recursive[0][1]
        print("--- 結構分析 ---")
        print(f"  遞迴函數: {sample_name}")
        print(f"  遞迴深度: {max(rec for _, _, rec in recursive)} 層")
        print("  -> 檢查是否有自調用或間接遞迴")
        print()


def main():
    parser = argparse.ArgumentParser(description="dSYM Crash Tracer")
    parser.add_argument("ips", help=".ips crash 檔案")
    parser.add_argument("-s", "--symbols", help="dSYM 目錄 / symbols_text.txt / symbol_map.txt")
    parser.add_argument("--json", "-j", action="store_true", help="JSON 輸出")
    args = parser.parse_args()
    analyze(args.ips, args.symbols, as_json=args.json)


if __name__ == "__main__":
    main()
