import subprocess, json, os, time, threading, sys
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

exe = r"C:\Users\agp05\AppData\Local\Programs\Swift\Toolchains\6.3.0+Asserts\usr\bin\sourcekit-lsp.exe"
root = r"C:\Users\agp05\OneDrive\桌面\ReplyKit"
p = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=root)
frames = []
stop = False
def reader():
    buf = b""
    while not stop:
        b = p.stdout.read(1)
        if not b: break
        buf += b
        if buf.endswith(b"\r\n\r\n"):
            h = {}
            for line in buf.decode(errors="replace").split("\r\n"):
                if ":" in line:
                    k, v = line.split(":", 1)
                    h[k.strip().lower()] = v.strip()
            ln = int(h.get("content-length", 0))
            body = b""
            while len(body) < ln:
                c = p.stdout.read(1)
                if not c: break
                body += c
            frames.append((h, body))
            buf = b""
t = threading.Thread(target=reader, daemon=True); t.start()
def send(m, rid):
    m["jsonrpc"]="2.0"; m["id"]=rid
    data = json.dumps(m).encode()
    p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
    p.stdin.flush()

fpath = os.path.join(root, "ReplyKIT", "Event.swift")
uri = "file:///" + fpath.replace("\\","/")
send({"method":"initialize","params":{"processId":None,"rootUri":"file:///"+root.replace("\\","/"),"capabilities":{}}}, 1)
time.sleep(3)
send({"method":"initialized","params":{}}, 2)
send({"method":"textDocument/didOpen","params":{"textDocument":{"uri":uri,"languageId":"swift","version":1,"text":open(fpath, encoding="utf-8").read()}}}, 3)
print("waiting 25s for prepare log...", flush=True)
time.sleep(25)
send({"method":"shutdown","params":{}}, 4)
time.sleep(1)
send({"method":"exit","params":{}}, 5)
time.sleep(1)
stop = True
p.kill()
prep_seen = []
for h, body in frames:
    try: m = json.loads(body.decode())
    except Exception: continue
    if m.get("method") == "window/logMessage":
        msg = m.get("params",{}).get("message","")
        if "Preparing" in msg or "noLazy" in msg or "prepare-for-indexing" in msg or "swift.exe build" in msg:
            prep_seen.append(msg)
print("=== prepare/build logs (%d) ===" % len(prep_seen))
for s in prep_seen[:10]:
    print(s[:220])
