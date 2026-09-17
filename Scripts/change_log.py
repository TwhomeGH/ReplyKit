#!/usr/bin/env python3
"""變更歷史工具 — 本機網頁 GUI（主要）+ CLI（腳本化用）。

主要用法（雙擊 Scripts/變更紀錄.cmd，或直接執行）:
  python Scripts/change_log.py                 # 啟動本機網頁 GUI（自動開瀏覽器）
  python Scripts/change_log.py serve --port 8765 --no-browser

CLI:
  python Scripts/change_log.py add "修復 xxx" [--type 修復] [--file path] [--date YYYY.MM.DD]
  python Scripts/change_log.py list [--grep 關鍵字] [--since 2026.06.01] [--type 修復] [--file Socket]
  python Scripts/change_log.py show <編號|關鍵字>

資料檔: Docs/ChangeHistory.md（最新在最上面）。零外部依賴。
"""
import re
import sys
import json
import argparse
import subprocess
import threading
import webbrowser
from datetime import date
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]
HISTORY = ROOT / "Docs" / "ChangeHistory.md"
DATE_RE = re.compile(r"^##\s+(\d{4})\.(\d{2})\.(\d{2})\s+(.*)$")


# ─────────────────────────── 核心：解析 / 讀寫 ───────────────────────────

def strip_comments(text):
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)


def parse_entries(text=None):
    """回傳 list[dict(date, title, raw)]，順序即檔案順序（新→舊）。"""
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
                            "title": m.group(4).strip(), "raw": raw})
        else:
            entries.append({"date": None, "title": lines[start][3:].strip(), "raw": raw})
    return entries


def read_history():
    if not HISTORY.exists():
        sys.exit("找不到 %s" % HISTORY)
    return HISTORY.read_text(encoding="utf-8")


def _heading_indices(lines):
    """真實（非註解內）的 '## ' 標題行索引。"""
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


def build_block(date_str, title, type_, file_, problem="", root_cause="", changes=None, refs=""):
    changes = [c.strip() for c in (changes or []) if c and c.strip()]
    lines = ["## %s %s" % (date_str, title), ""]
    meta = "**類型**: %s" % (type_ or "修復")
    if file_:
        meta += " · **檔案**: `%s`" % file_
    lines += [meta, ""]
    if problem:
        lines.append("**問題**: %s" % problem)
    if root_cause:
        lines.append("**根因**: %s" % root_cause)
    if changes:
        lines.append("**修改**:")
        lines += ["- %s" % c for c in changes]
    if refs:
        lines.append("**相關文件**: %s" % refs)
    lines += ["", "---", ""]
    return "\n".join(lines)


def insert_block(block):
    lines = read_history().splitlines()
    heads = _heading_indices(lines)
    at = heads[0] if heads else len(lines)
    new = lines[:at] + block.splitlines() + [""] + lines[at:]
    HISTORY.write_text("\n".join(new).rstrip() + "\n", encoding="utf-8")


def update_entry(i, raw):
    lines = read_history().splitlines()
    heads = _heading_indices(lines)
    if not (0 <= i < len(heads)):
        raise IndexError("編號超出範圍")
    start = heads[i]
    end = heads[i + 1] if i + 1 < len(heads) else len(lines)
    repl = raw.rstrip().splitlines()
    if i + 1 < len(heads):          # 後面還有下一筆 → 補回分隔空行
        repl.append("")
    new = lines[:start] + repl + lines[end:]
    HISTORY.write_text("\n".join(new).rstrip() + "\n", encoding="utf-8")


def delete_entry(i):
    lines = read_history().splitlines()
    heads = _heading_indices(lines)
    if not (0 <= i < len(heads)):
        raise IndexError("編號超出範圍")
    start = heads[i]
    end = heads[i + 1] if i + 1 < len(heads) else len(lines)
    new = lines[:start] + lines[end:]
    # 收斂多餘空行
    out, blank = [], 0
    for l in new:
        blank = blank + 1 if l.strip() == "" else 0
        if blank <= 2:
            out.append(l)
    HISTORY.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")


def git_changed_files():
    try:
        r1 = subprocess.run(["git", "-C", str(ROOT), "diff", "--name-only"],
                            capture_output=True, text=True, timeout=5).stdout
        r2 = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--others", "--exclude-standard"],
                            capture_output=True, text=True, timeout=5).stdout
        files = [f.strip() for f in (r1 + "\n" + r2).splitlines() if f.strip()]
        return sorted(set(files))
    except Exception:
        return []


# ─────────────────────────────── CLI ───────────────────────────────

def cmd_add(args):
    date_str = args.date or date.today().strftime("%Y.%m.%d")
    insert_block(build_block(date_str, args.title, args.type, args.file))
    print("已插入: %s %s" % (date_str, args.title))


def _matches(e, args):
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
    entries = parse_entries()
    hits = [e for e in entries if _matches(e, args)]
    if args.limit:
        hits = hits[: args.limit]
    print("符合 %d / 共 %d 筆\n" % (len(hits), len(entries)))
    for i, e in enumerate(hits, 1):
        print("%3d  %-10s  %s" % (i, e["date"] or "----------", e["title"]))


def cmd_show(args):
    entries = parse_entries()
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


# ─────────────────────────── 網頁 GUI ───────────────────────────

PAGE = r"""<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>變更歷史</title>
<script>(function(){try{var t=localStorage.getItem('theme');if(t!=='dark'&&t!=='light')t=matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light';document.documentElement.dataset.theme=t;}catch(e){}})();</script>
<style>
:root{--bg:#f7f7f8;--fg:#1c1c1e;--mut:#6b7280;--card:#fff;--line:#e5e7eb;--accent:#2563eb;--code:#f3f4f6}
:root[data-theme="dark"]{--bg:#1c1c1e;--fg:#e5e5e7;--mut:#9ca3af;--card:#2c2c2e;--line:#3a3a3c;--accent:#4f8cff;--code:#3a3a3c}
*{box-sizing:border-box}body{margin:0;font:15px/1.6 -apple-system,"Segoe UI","Microsoft JhengHei",sans-serif;background:var(--bg);color:var(--fg)}
header{display:flex;gap:8px;align-items:center;padding:10px 14px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:5}
header h1{font-size:16px;margin:0 12px 0 0;white-space:nowrap}
input,select,button{font:inherit;padding:6px 9px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg)}
input#q{flex:1;min-width:120px}
button{cursor:pointer}button.primary{background:var(--accent);color:#fff;border-color:var(--accent)}
main{display:flex;height:calc(100vh - 57px)}
aside{width:340px;min-width:220px;overflow:auto;border-right:1px solid var(--line)}
.item{padding:9px 14px;border-bottom:1px solid var(--line);cursor:pointer}
.item:hover{background:var(--card)}.item.sel{background:var(--card);box-shadow:inset 3px 0 0 var(--accent)}
.item .d{font-size:12px;color:var(--mut)}.item .t{font-weight:600}
section{flex:1;overflow:auto;padding:18px 24px}
section h1,section h2,section h3{margin:.6em 0 .4em}section h2{font-size:20px;border-bottom:1px solid var(--line);padding-bottom:.3em}
pre.code{background:var(--code);padding:10px 12px;border-radius:8px;overflow:auto}
code{background:var(--code);padding:1px 5px;border-radius:5px}
table{border-collapse:collapse;margin:.6em 0}th,td{border:1px solid var(--line);padding:5px 9px;text-align:left}
blockquote{margin:.6em 0;padding:.2em .9em;border-left:3px solid var(--line);color:var(--mut)}
a{color:var(--accent)}hr{border:none;border-top:1px solid var(--line);margin:1em 0}
.toolbar{margin-bottom:10px;display:flex;gap:8px}
#modal{position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;align-items:center;justify-content:center;z-index:10}
#modal[hidden]{display:none}
.dialog{background:var(--card);border-radius:14px;padding:18px;width:min(680px,92vw);max-height:90vh;overflow:auto}
.dialog h2{margin-top:0}.dialog label{display:block;font-size:13px;color:var(--mut);margin:10px 0 3px}
.dialog input,.dialog textarea,.dialog select{width:100%}.dialog textarea{min-height:64px;resize:vertical;font:inherit}
.row{display:flex;gap:10px}.row>div{flex:1}
.right{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}
.empty{color:var(--mut);padding:30px;text-align:center}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:5px}
.chip{font-size:12px;padding:2px 8px;border:1px solid var(--line);border-radius:20px;cursor:pointer;background:var(--card)}
#raw{width:100%;min-height:320px;font:13px/1.6 ui-monospace,Consolas,"Courier New",monospace;padding:12px;border:1px solid var(--line);border-radius:10px;background:var(--card);color:var(--fg);resize:vertical;white-space:pre;overflow:auto;tab-size:2}
button.danger{background:#dc2626;color:#fff;border-color:#dc2626}
.err{color:#dc2626;font-size:13px;min-height:1.1em;margin-top:6px}
.alert{border:1px solid;border-left-width:4px;border-radius:10px;padding:10px 14px;margin:.9em 0}
.alert-title{font-weight:700;font-size:13px;margin-bottom:5px;letter-spacing:.02em}
.alert :last-child{margin-bottom:0}
.alert-note{border-color:#3b82f6;background:rgba(59,130,246,.10)}.alert-note .alert-title{color:#2563eb}
.alert-tip{border-color:#10b981;background:rgba(16,185,129,.10)}.alert-tip .alert-title{color:#059669}
.alert-important{border-color:#a855f7;background:rgba(168,85,247,.10)}.alert-important .alert-title{color:#9333ea}
.alert-warning{border-color:#f59e0b;background:rgba(245,158,11,.13)}.alert-warning .alert-title{color:#d97706}
.alert-caution{border-color:#ef4444;background:rgba(239,68,68,.10)}.alert-caution .alert-title{color:#dc2626}
</style></head>
<body>
<header>
  <h1>變更歷史</h1>
  <input id="q" placeholder="搜尋標題 / 內容…">
  <select id="type"><option value="">全部類型</option><option>修復</option><option>新增</option><option>優化</option><option>重構</option><option>測試</option></select>
  <button id="reload">↻</button>
  <button id="theme" title="切換深/淺色">🌙</button>
  <button id="add" class="primary">＋ 新增紀錄</button>
</header>
<main>
  <aside id="list"></aside>
  <section id="detail"><div class="empty">← 選擇一筆紀錄</div></section>
</main>

<div id="modal" hidden><div class="dialog">
  <h2>新增紀錄</h2>
  <label>標題</label><input id="f-title" placeholder="修復 PiP 閃退">
  <div class="row">
    <div><label>日期</label><input id="f-date"></div>
    <div><label>類型</label>
      <select id="f-type"><option>修復</option><option>新增</option><option>優化</option><option>重構</option><option>測試</option></select>
    </div>
  </div>
  <label>檔案</label><input id="f-file" placeholder="liveAPP/Socket.swift" list="gitfiles">
  <datalist id="gitfiles"></datalist>
  <div class="chips" id="chips"></div>
  <label>問題</label><textarea id="f-problem" placeholder="一句話描述症狀"></textarea>
  <label>根因（可選）</label><textarea id="f-cause"></textarea>
  <label>修改（一行一項）</label><textarea id="f-changes" placeholder="- 把 X 改成 Y"></textarea>
  <label>相關文件（可選）</label><input id="f-refs" placeholder="[crash-tracing.md](crash-tracing.md)">
  <div id="form-err" class="err"></div>
  <div class="right"><button id="cancel">取消</button><button id="submit" class="primary">插入</button></div>
</div></div>

<script>
const $=s=>document.querySelector(s);
let sel=null;
function setTheme(t){document.documentElement.dataset.theme=t;try{localStorage.setItem('theme',t);}catch(e){}
  $('#theme').textContent=t==='dark'?'☀️':'🌙';}
$('#theme').onclick=()=>setTheme(document.documentElement.dataset.theme==='dark'?'light':'dark');
setTheme(document.documentElement.dataset.theme||'light');
function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
function inline(s){
  s=s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  s=s.replace(/`([^`]+)`/g,'<code>$1</code>');
  s=s.replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');
  s=s.replace(/\[([^\]]+)\]\(([^)]+)\)/g,'<a href="$2" target="_blank" rel="noopener">$1</a>');
  return s;
}
function mdToHtml(src){
  const L=src.split('\n'); let out='',i=0;
  const row=l=>l.trim().replace(/^\||\|$/g,'').split('|').map(s=>s.trim());
  while(i<L.length){
    let l=L[i];
    if(/^```/.test(l)){let b=[];i++;while(i<L.length&&!/^```/.test(L[i])){b.push(L[i]);i++;}i++;out+='<pre class="code">'+esc(b.join('\n'))+'</pre>';continue;}
    if(/^\s*\|/.test(l)&&i+1<L.length&&/^\s*\|[\s:|-]+\|/.test(L[i+1])){
      let h=row(l);i+=2;let rs=[];while(i<L.length&&/^\s*\|/.test(L[i])){rs.push(row(L[i]));i++;}
      out+='<table><thead><tr>'+h.map(c=>'<th>'+inline(c)+'</th>').join('')+'</tr></thead><tbody>'+
        rs.map(r=>'<tr>'+r.map(c=>'<td>'+inline(c)+'</td>').join('')+'</tr>').join('')+'</tbody></table>';continue;
    }
    let m=l.match(/^(#{1,6})\s+(.*)$/);
    if(m){let n=m[1].length;out+='<h'+n+'>'+inline(m[2])+'</h'+n+'>';i++;continue;}
    if(/^\s*---+\s*$/.test(l)){out+='<hr>';i++;continue;}
    if(/^\s*>\s?/.test(l)){
      let b=[];while(i<L.length&&/^\s*>\s?/.test(L[i])){b.push(L[i].replace(/^\s*>\s?/,''));i++;}
      const am=b.length?b[0].match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*)$/i):null;
      if(am){
        const t=am[1].toLowerCase();
        let body=b.slice(1);if(am[2].trim())body.unshift(am[2]);
        const meta={note:['ℹ️','Note'],tip:['💡','Tip'],important:['📌','Important'],warning:['⚠️','Warning'],caution:['🛑','Caution']}[t];
        out+='<div class="alert alert-'+t+'"><div class="alert-title">'+meta[0]+' '+meta[1]+'</div>'+mdToHtml(body.join('\n'))+'</div>';
      }else{
        out+='<blockquote>'+inline(b.join(' '))+'</blockquote>';
      }
      continue;
    }
    if(/^\s*[-*]\s+/.test(l)){let b=[];while(i<L.length&&/^\s*[-*]\s+/.test(L[i])){b.push(L[i].replace(/^\s*[-*]\s+/,''));i++;}out+='<ul>'+b.map(x=>'<li>'+inline(x)+'</li>').join('')+'</ul>';continue;}
    if(/^\s*\d+\.\s+/.test(l)){let b=[];while(i<L.length&&/^\s*\d+\.\s+/.test(L[i])){b.push(L[i].replace(/^\s*\d+\.\s+/,''));i++;}out+='<ol>'+b.map(x=>'<li>'+inline(x)+'</li>').join('')+'</ol>';continue;}
    if(/^\s*$/.test(l)){i++;continue;}
    out+='<p>'+inline(l)+'</p>';i++;
  }
  return out;
}
async function load(){
  const q=encodeURIComponent($('#q').value), t=encodeURIComponent($('#type').value);
  const r=await fetch('/api/entries?q='+q+'&type='+t);const items=await r.json();
  $('#list').innerHTML = items.length? items.map(e=>
    `<div class="item${e.i===sel?' sel':''}" data-i="${e.i}"><div class="d">${e.date||'未標日期'}</div><div class="t">${esc(e.title)}</div></div>`).join('')
    : '<div class="empty">沒有符合的紀錄</div>';
  document.querySelectorAll('.item').forEach(el=>el.onclick=()=>show(+el.dataset.i));
}
function renderView(e){
  $('#detail').innerHTML=
    `<div class="toolbar"><button id="edit">編輯</button><button id="del">刪除</button></div>`+
    `<div id="content">`+mdToHtml(e.raw)+`</div>`;
  $('#edit').onclick=()=>renderEdit(e);
  let armed=false;
  $('#del').onclick=()=>{
    if(!armed){armed=true;$('#del').textContent='確定刪除？';$('#del').classList.add('danger');
      setTimeout(()=>{armed=false;$('#del').textContent='刪除';$('#del').classList.remove('danger');},3000);return;}
    fetch('/api/delete',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({i:e.i})})
      .then(()=>{sel=null;$('#detail').innerHTML='<div class="empty">已刪除</div>';load();});
  };
}
function renderEdit(e){
  $('#detail').innerHTML=
    `<div class="toolbar"><button id="save" class="primary">儲存</button><button id="cancel">取消</button></div>`+
    `<textarea id="raw" spellcheck="false"></textarea>`;
  const ta=$('#raw');ta.value=e.raw;
  const autosize=()=>{ta.style.height='auto';ta.style.height=Math.max(320,ta.scrollHeight+6)+'px';};
  ta.addEventListener('input',autosize);autosize();ta.focus();
  ta.addEventListener('keydown',ev=>{if((ev.ctrlKey||ev.metaKey)&&ev.key==='s'){ev.preventDefault();$('#save').click();}});
  $('#cancel').onclick=()=>renderView(e);
  $('#save').onclick=async()=>{
    await fetch('/api/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({i:e.i,raw:ta.value})});
    const ne=await(await fetch('/api/entry?i='+e.i)).json();ne.i=e.i;
    await load();renderView(ne);
  };
}
async function show(i){
  sel=i;
  const e=await(await fetch('/api/entry?i='+i)).json();e.i=i;
  document.querySelectorAll('.item').forEach(el=>el.classList.toggle('sel',+el.dataset.i===i));
  renderView(e);
}
$('#q').oninput=()=>load();
$('#type').onchange=()=>load();
$('#reload').onclick=()=>load();
$('#add').onclick=async()=>{
  $('#f-date').value=new Date().toISOString().slice(0,10).replace(/-/g,'.');
  ['f-title','f-file','f-problem','f-cause','f-changes','f-refs'].forEach(id=>$('#'+id).value='');
  const files=await (await fetch('/api/gitdiff')).json();
  $('#gitfiles').innerHTML=files.map(f=>`<option value="${f}">`).join('');
  $('#chips').innerHTML=files.slice(0,12).map(f=>`<span class="chip">${f}</span>`).join('');
  document.querySelectorAll('.chip').forEach(c=>c.onclick=()=>$('#f-file').value=c.textContent);
  $('#form-err').textContent='';$('#modal').hidden=false;$('#f-title').focus();
};
$('#cancel').onclick=()=>$('#modal').hidden=true;
$('#modal').onclick=e=>{if(e.target.id==='modal')$('#modal').hidden=true;};
$('#submit').onclick=async()=>{
  const title=$('#f-title').value.trim();
  if(!title){$('#form-err').textContent='請填標題';$('#f-title').focus();return;}
  $('#form-err').textContent='';
  const body={title,date:$('#f-date').value.trim(),type:$('#f-type').value,file:$('#f-file').value.trim(),
    problem:$('#f-problem').value.trim(),root_cause:$('#f-cause').value.trim(),
    changes:$('#f-changes').value.split('\n').map(s=>s.replace(/^\s*[-*]\s*/,'').trim()).filter(Boolean),
    refs:$('#f-refs').value.trim()};
  await fetch('/api/add',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  $('#modal').hidden=true;await load();show(0);
};
load();
</script>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if u.path == "/api/entries":
            qs = parse_qs(u.query)
            q = qs.get("q", [""])[0].lower()
            ty = qs.get("type", [""])[0].lower()
            out = []
            for i, e in enumerate(parse_entries()):
                hay = (e["title"] + "\n" + e["raw"]).lower()
                if q and q not in hay:
                    continue
                if ty and ty not in e["raw"].lower():
                    continue
                out.append({"i": i, "date": e["date"], "title": e["title"]})
            return self._send(200, json.dumps(out, ensure_ascii=False))
        if u.path == "/api/entry":
            i = int(parse_qs(u.query).get("i", ["0"])[0])
            entries = parse_entries()
            if 0 <= i < len(entries):
                return self._send(200, json.dumps(entries[i], ensure_ascii=False))
            return self._send(404, "{}")
        if u.path == "/api/gitdiff":
            return self._send(200, json.dumps(git_changed_files(), ensure_ascii=False))
        return self._send(404, "{}")

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", "0"))
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = {}
        try:
            if u.path == "/api/add":
                insert_block(build_block(
                    body.get("date") or date.today().strftime("%Y.%m.%d"),
                    body.get("title", "(無標題)"), body.get("type", "修復"),
                    body.get("file", ""), body.get("problem", ""),
                    body.get("root_cause", ""), body.get("changes", []), body.get("refs", "")))
                return self._send(200, json.dumps({"ok": True}))
            if u.path == "/api/save":
                update_entry(int(body["i"]), body["raw"])
                return self._send(200, json.dumps({"ok": True}))
            if u.path == "/api/delete":
                delete_entry(int(body["i"]))
                return self._send(200, json.dumps({"ok": True}))
        except Exception as ex:
            return self._send(400, json.dumps({"ok": False, "error": str(ex)}, ensure_ascii=False))
        return self._send(404, "{}")


class _Server(ThreadingHTTPServer):
    # Windows 上 allow_reuse_address=1 會讓第二個實例「搶綁」同一埠，
    # 造成兩個 server 同時 LISTEN、瀏覽器連到舊的。關掉它，綁不到就換埠。
    allow_reuse_address = False


def serve(port=8710, open_browser=True):
    try:
        httpd = _Server(("127.0.0.1", port), Handler)
    except OSError:
        # 埠被占用或被 Windows 保留（如 8740-8839）時改用系統自動配置
        httpd = _Server(("127.0.0.1", 0), Handler)
    url = "http://127.0.0.1:%d/" % httpd.server_address[1]
    print("變更歷史 GUI: %s" % url)
    print("（Ctrl+C 結束）")
    if open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


def main():
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

    l = sub.add_parser("list", help="檢索紀錄（CLI）")
    l.add_argument("--grep", default="")
    l.add_argument("--since", default="")
    l.add_argument("--file", default="")
    l.add_argument("--type", default="")
    l.add_argument("--limit", type=int, default=0)

    s = sub.add_parser("show", help="顯示單筆完整內容（編號或關鍵字）")
    s.add_argument("query")

    args = p.parse_args()
    if args.cmd in (None, "serve"):
        serve(getattr(args, "port", 8710), not getattr(args, "no_browser", False))
    elif args.cmd == "add":
        cmd_add(args)
    elif args.cmd == "list":
        cmd_list(args)
    elif args.cmd == "show":
        cmd_show(args)


if __name__ == "__main__":
    main()
