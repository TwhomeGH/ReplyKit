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


def _summary_body(text):
    """把多行文字拆成 (摘要, 其餘內文)；摘要取第一個非空行。

    摘要會成為 `### 問題 - <摘要>` / `### 根因 - <摘要>` 標題的一部分，
    因此必須是能區分各筆紀錄的短句，避免 markdownlint MD024（重複標題）。
    """
    text = (text or "").strip()
    if not text:
        return "", ""
    parts = text.splitlines()
    return parts[0].strip(), "\n".join(parts[1:]).strip()


def _norm_refs(refs):
    """把多筆相關文件正規化為以 ` · ` 串接的單行字串。

    接受 list（網頁 GUI）或字串（每行一筆，CLI 用），保留每筆的
    markdown 連結寫法（如 `[說明](Docs/x.md)`）。
    """
    if not refs:
        return ""
    if isinstance(refs, str):
        refs = refs.splitlines()
    items = [str(r).strip() for r in refs if str(r).strip()]
    return " · ".join(items)


def build_block(date_str, title, type_, file_, problem="", root_cause="", changes=None, refs=""):
    if isinstance(changes, str):
        changes = changes.splitlines()
    changes = [c.strip() for c in (changes or []) if c and c.strip()]
    refs = _norm_refs(refs)
    lines = ["## %s %s" % (date_str, title), ""]
    meta = "**類型**: %s" % (type_ or "修復")
    if file_:
        meta += " · **檔案**: `%s`" % file_
    lines += [meta, ""]
    # 問題 / 根因：第一行當標題摘要，其後為詳述
    for label, text in (("問題", problem), ("根因", root_cause)):
        summary, body = _summary_body(text)
        if not summary:
            continue
        lines.append("### %s - %s" % (label, summary))
        if body:
            lines += ["", body]
        lines.append("")
    # 修改：第一項當標題摘要，其餘為條列
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
    insert_block(build_block(date_str, args.title, args.type, args.file, refs=getattr(args, "ref", [])))
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
:root{color-scheme:light;--bg:#f4f5f7;--fg:#111827;--mut:#6b7280;--card:#fff;--field:#fff;--line:#e5e7eb;--line2:#eef0f3;--accent:#2563eb;--accent-fg:#fff;--code:#f3f4f6;--ring:rgba(37,99,235,.22);--hdr:rgba(244,245,247,.85);--shadow:0 12px 36px rgba(17,24,39,.13)}
:root[data-theme="dark"]{color-scheme:dark;--bg:#0e1013;--fg:#e6e8ec;--mut:#98a1ad;--card:#191c22;--field:#14171c;--line:#2b313a;--line2:#232830;--accent:#4f8cff;--accent-fg:#fff;--code:#20242c;--ring:rgba(79,140,255,.30);--hdr:rgba(14,16,19,.85);--shadow:0 18px 52px rgba(0,0,0,.6)}
*{box-sizing:border-box}
body{margin:0;font:15px/1.65 -apple-system,"Segoe UI","Microsoft JhengHei",sans-serif;background:var(--bg);color:var(--fg);display:flex;flex-direction:column;height:100vh;overflow:hidden;-webkit-font-smoothing:antialiased}
::-webkit-scrollbar{width:10px;height:10px}::-webkit-scrollbar-thumb{background:var(--line);border-radius:9px;border:2px solid var(--bg)}::-webkit-scrollbar-thumb:hover{background:var(--mut)}
header{display:flex;gap:8px;align-items:center;flex-wrap:wrap;row-gap:8px;padding:12px 16px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--hdr);backdrop-filter:blur(10px);z-index:5}
header h1{font-size:16px;font-weight:700;margin:0 10px 0 0;white-space:nowrap}
input,select,textarea,button{font:inherit;color:var(--fg)}
input,select,textarea{padding:9px 11px;border:1px solid var(--line);border-radius:10px;background:var(--field);width:100%;transition:border-color .15s,box-shadow .15s}
input:hover,select:hover,textarea:hover{border-color:var(--mut)}
input:focus,select:focus,textarea:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--ring)}
::placeholder{color:var(--mut);opacity:.8}
header input,header select{width:auto}
input#q{flex:1;min-width:160px}
button{cursor:pointer;padding:9px 13px;border:1px solid var(--line);border-radius:10px;background:var(--card);transition:background .15s,border-color .15s,transform .05s}
button:hover{background:var(--line2)}
button:active{transform:translateY(1px)}
button.primary{background:var(--accent);color:var(--accent-fg);border-color:var(--accent)}
button.primary:hover{filter:brightness(1.07);background:var(--accent)}
main{display:flex;flex:1;min-height:0}
aside{width:340px;min-width:220px;overflow:auto;border-right:1px solid var(--line)}
.item{padding:11px 16px;border-bottom:1px solid var(--line2);cursor:pointer;transition:background .12s}
.item:hover{background:var(--card)}.item.sel{background:var(--card);box-shadow:inset 3px 0 0 var(--accent)}
.item .d{font-size:12px;color:var(--mut);font-variant-numeric:tabular-nums}.item .t{font-weight:600;margin-top:2px}
section{flex:1;overflow:auto;padding:22px 28px}
section h1,section h2,section h3{margin:.6em 0 .4em;line-height:1.35}section h2{font-size:20px;border-bottom:1px solid var(--line);padding-bottom:.3em}
pre.code{background:var(--code);padding:12px 14px;border-radius:10px;overflow:auto;border:1px solid var(--line)}
code{background:var(--code);padding:1px 6px;border-radius:6px;font-size:.92em}
table{border-collapse:collapse;margin:.6em 0}th,td{border:1px solid var(--line);padding:7px 11px;text-align:left}
blockquote{margin:.6em 0;padding:.3em 1em;border-left:3px solid var(--line);color:var(--mut)}
a{color:var(--accent);text-underline-offset:2px}hr{border:none;border-top:1px solid var(--line);margin:1em 0}
.toolbar{margin-bottom:12px;display:flex;gap:8px}
#modal{position:fixed;inset:0;background:rgba(8,10,14,.55);backdrop-filter:blur(3px);display:flex;align-items:center;justify-content:center;z-index:10}
#modal[hidden]{display:none}
.dialog{background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);padding:20px 20px 0;width:min(680px,92vw);max-height:90vh;overflow:auto}
.dialog h2{margin:0 0 6px;font-size:18px}
.dialog label{display:block;font-size:13px;font-weight:600;color:var(--mut);margin:14px 0 5px}
.dialog textarea{min-height:70px;resize:vertical;line-height:1.55}
.row{display:flex;gap:12px}.row>div{flex:1}
.ref-row{display:flex;gap:8px;margin-top:6px}.ref-row .ref-del{flex:none;padding:9px 12px}
#add-ref{margin-top:8px}
.foot{position:sticky;bottom:0;background:var(--card);border-top:1px solid var(--line);margin-top:18px;padding:12px 0 18px}
.right{display:flex;justify-content:flex-end;gap:8px}
.empty{color:var(--mut);padding:30px;text-align:center}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
.chip{font-size:12px;padding:3px 10px;border:1px solid var(--line);border-radius:20px;cursor:pointer;background:var(--bg);color:var(--mut);transition:border-color .15s,color .15s}
.chip:hover{border-color:var(--accent);color:var(--accent)}
#raw{width:100%;min-height:320px;font:13px/1.6 ui-monospace,Consolas,"Courier New",monospace;padding:14px;border:1px solid var(--line);border-radius:12px;background:var(--code);color:var(--fg);resize:vertical;white-space:pre;overflow:auto;tab-size:2}
#raw:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--ring)}
button.danger{background:#dc2626;color:#fff;border-color:#dc2626}
.err{color:#ef4444;font-size:13px;min-height:1.2em;margin-top:8px}
.alert{border:1px solid;border-left-width:4px;border-radius:10px;padding:10px 14px;margin:.9em 0}
.alert-title{font-weight:700;font-size:13px;margin-bottom:5px;letter-spacing:.02em}
.alert :last-child{margin-bottom:0}
.alert-note{border-color:#3b82f6;background:rgba(59,130,246,.10)}.alert-note .alert-title{color:#2563eb}
.alert-tip{border-color:#10b981;background:rgba(16,185,129,.10)}.alert-tip .alert-title{color:#059669}
.alert-important{border-color:#a855f7;background:rgba(168,85,247,.10)}.alert-important .alert-title{color:#9333ea}
.alert-warning{border-color:#f59e0b;background:rgba(245,158,11,.13)}.alert-warning .alert-title{color:#d97706}
.alert-caution{border-color:#ef4444;background:rgba(239,68,68,.10)}.alert-caution .alert-title{color:#dc2626}
#content{max-width:900px}
@media (max-width:640px){main{flex-direction:column}aside{width:auto;max-width:100%;max-height:42vh;border-right:none;border-bottom:1px solid var(--line)}section{padding:14px 16px}.row{flex-direction:column;gap:0}}
</style></head>
<body>
<header>
  <h1>變更歷史</h1>
  <input id="q" aria-label="搜尋標題或內容" placeholder="搜尋標題 / 內容…">
  <select id="type" aria-label="依類型篩選"><option value="">全部類型</option><option>修復</option><option>新增</option><option>優化</option><option>重構</option><option>測試</option></select>
  <button id="reload" aria-label="重新載入" title="重新載入">↻</button>
  <button id="theme" aria-label="切換深淺色" title="切換深/淺色">🌙</button>
  <button id="add" class="primary">＋ 新增紀錄</button>
</header>
<main>
  <aside id="list"></aside>
  <section id="detail"><div class="empty">← 選擇一筆紀錄</div></section>
</main>

<div id="modal" hidden><div class="dialog">
  <h2>新增紀錄</h2>
  <label for="f-title">標題</label><input id="f-title" placeholder="修復 PiP 閃退">
  <div class="row">
    <div><label for="f-date">日期</label><input id="f-date" placeholder="YYYY.MM.DD"></div>
    <div><label for="f-type">類型</label>
      <select id="f-type"><option>修復</option><option>新增</option><option>優化</option><option>重構</option><option>測試</option></select>
    </div>
  </div>
  <label for="f-file">檔案</label><input id="f-file" placeholder="liveAPP/Socket.swift" list="gitfiles">
  <datalist id="gitfiles"></datalist>
  <div class="chips" id="chips"></div>
  <label for="f-problem">問題（第一行 = 標題摘要）</label><textarea id="f-problem" placeholder="症狀摘要&#10;（其後可換行寫詳述）"></textarea>
  <label for="f-cause">根因（可選，第一行 = 標題摘要）</label><textarea id="f-cause" placeholder="根因摘要&#10;（其後可換行寫詳述）"></textarea>
  <label for="f-changes">修改（第一行 = 標題摘要，其後每行一項）</label><textarea id="f-changes" placeholder="核心手法摘要&#10;其他改動（每行一項）"></textarea>
  <label>相關文件（可選，可多筆）</label>
  <div id="refs"></div>
  <button type="button" id="add-ref">＋ 新增文件</button>
  <div class="foot">
    <div id="form-err" class="err"></div>
    <div class="right"><button id="cancel">取消</button><button id="submit" class="primary">插入</button></div>
  </div>
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
    `<div class="toolbar"><button id="save" class="primary">儲存</button><button id="cancel-edit">取消</button></div>`+
    `<textarea id="raw" spellcheck="false"></textarea>`;
  const ta=$('#raw');ta.value=e.raw;
  const autosize=()=>{ta.style.height='auto';ta.style.height=Math.max(320,ta.scrollHeight+6)+'px';};
  ta.addEventListener('input',autosize);autosize();ta.focus();
  ta.addEventListener('keydown',ev=>{if((ev.ctrlKey||ev.metaKey)&&ev.key==='s'){ev.preventDefault();$('#save').click();}});
  $('#cancel-edit').onclick=()=>renderView(e);
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
function makeRefRow(label,url){
  const d=document.createElement('div');d.className='ref-row';
  d.innerHTML='<input class="ref-label" placeholder="顯示文字（可留空）"><input class="ref-url" placeholder="連結或路徑，Docs/… 或 https://…"><button type="button" class="ref-del" title="移除">✕</button>';
  d.querySelector('.ref-label').value=label||'';
  d.querySelector('.ref-url').value=url||'';
  d.querySelector('.ref-del').onclick=()=>d.remove();
  return d;
}
function clearRefs(){const c=$('#refs');c.innerHTML='';c.appendChild(makeRefRow());}
function collectRefs(){
  return [...$('#refs').querySelectorAll('.ref-row')].map(r=>{
    const label=r.querySelector('.ref-label').value.trim();
    const url=r.querySelector('.ref-url').value.trim();
    if(!url) return label;
    return `[${label||url}](${url})`;
  }).filter(Boolean);
}
$('#add-ref').onclick=()=>$('#refs').appendChild(makeRefRow());
$('#add').onclick=async()=>{
  $('#f-date').value=new Date().toISOString().slice(0,10).replace(/-/g,'.');
  ['f-title','f-file','f-problem','f-cause','f-changes'].forEach(id=>$('#'+id).value='');
  clearRefs();
  const files=await (await fetch('/api/gitdiff')).json();
  $('#gitfiles').innerHTML=files.map(f=>`<option value="${f}">`).join('');
  $('#chips').innerHTML=files.slice(0,12).map(f=>`<span class="chip">${f}</span>`).join('');
  document.querySelectorAll('.chip').forEach(c=>c.onclick=()=>$('#f-file').value=c.textContent);
  $('#form-err').textContent='';$('#modal').hidden=false;$('#f-title').focus();
};
$('#cancel').onclick=()=>$('#modal').hidden=true;
$('#submit').onclick=async()=>{
  const title=$('#f-title').value.trim();
  if(!title){$('#form-err').textContent='請填標題';$('#f-title').focus();return;}
  $('#form-err').textContent='';
  const body={title,date:$('#f-date').value.trim(),type:$('#f-type').value,file:$('#f-file').value.trim(),
    problem:$('#f-problem').value.trim(),root_cause:$('#f-cause').value.trim(),
    changes:$('#f-changes').value.split('\n').map(s=>s.replace(/^\s*[-*]\s*/,'').trim()).filter(Boolean),
    refs:collectRefs()};
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
        if u.path == "/favicon.ico":
            return self._send(204, b"")
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
    a.add_argument("--ref", action="append", default=[], help="相關文件（可重複，格式 [說明](路徑)）")

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
