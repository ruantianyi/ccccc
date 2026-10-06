#!/bin/bash
# verify-v2.sh - end-to-end verification for server.py build.
# Tests: static serving, token injection, proxy auth + rewriting,
# WebSocket->VNC relay with full RFB handshake and framebuffer bytes.
set -u
cd "$(dirname "$0")"

PORT=18081
ORIGIN_PORT=8901
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "== syntax =="
bash -n start.sh && ok "start.sh syntax" || bad "start.sh syntax"
python3 -m py_compile server.py && ok "server.py compiles" || bad "server.py compiles"

echo "== starting scripted RFB server on 5901 =="
pkill -f "server.py $PORT" 2>/dev/null; pkill -f "v2-fakevnc" 2>/dev/null
pkill -f "v2-origin-server" 2>/dev/null; sleep 1
cat > /tmp/v2-fakevnc.py <<'PY'
import socket, struct, threading, time
def recvn(c, n):
    d = b""
    while len(d) < n:
        ch = c.recv(n - len(d))
        if not ch: raise ConnectionError("eof")
        d += ch
    return d
def handle(c):
    try:
        c.sendall(b"RFB 003.008\n")
        assert recvn(c, 12) == b"RFB 003.008\n"
        c.sendall(bytes([1, 1]))
        assert recvn(c, 1) == bytes([1])
        c.sendall(b"\x00\x00\x00\x00")
        recvn(c, 1)
        pixfmt = struct.pack(">BBBBHHHBBB3s", 32, 24, 0, 1,
                             255, 255, 255, 16, 8, 0, b"\x00\x00\x00")
        c.sendall(struct.pack(">HH", 1280, 720) + pixfmt
                  + struct.pack(">I", 4) + b"fake")
        while True:
            t = recvn(c, 1)[0]
            if t == 0: recvn(c, 19)
            elif t == 2:
                hdr3 = recvn(c, 3)  # pad(1) + n_enc(2)
                n = struct.unpack(">H", hdr3[1:3])[0]
                recvn(c, 4 * n)
            elif t == 3: recvn(c, 9); break
            elif t == 4: recvn(c, 7)
            elif t == 5: recvn(c, 5)
            elif t == 6:
                recvn(c, 3); n = struct.unpack(">I", recvn(c, 4))[0]
                recvn(c, n)
            else: raise ValueError("unknown msg %d" % t)
        w, h = 1280, 720
        px = bytes([250, 128, 64, 0]) * (w * h)
        c.sendall(struct.pack(">BBH", 0, 0, 1)
                  + struct.pack(">HHHHI", 0, 0, w, h, 0) + px)
        time.sleep(10)
    except Exception as e:
        print("fakevnc:", e)
    finally:
        c.close()
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 5901)); srv.listen(5)
print("fakevnc on 5901", flush=True)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
python3 /tmp/v2-fakevnc.py >/tmp/v2-fakevnc.log 2>&1 &
sleep 1
python3 -c "import socket; socket.create_connection(('127.0.0.1',5901),timeout=5).close()" \
  && ok "scripted RFB server listening on 5901" \
  || bad "scripted RFB server listening on 5901"

echo "== starting server.py =="
python3 server.py $PORT >/tmp/v2-server.log 2>&1 &
SRV=$!
sleep 2
kill -0 $SRV 2>/dev/null && ok "server.py listening on $PORT" || bad "server.py listening"

echo "== static + token =="
PAGE=$(curl -s -o /tmp/v2-index.html -w "%{http_code}" http://127.0.0.1:$PORT/)
[ "$PAGE" = "200" ] && ok "GET / -> 200" || bad "GET / -> $PAGE"
grep -q "<title>Academic Code Tester</title>" /tmp/v2-index.html && ok "title correct" || bad "title"
grep -q "__PROXY_TOKEN__" /tmp/v2-index.html && bad "token placeholder leaked" || ok "token injected"
grep -q 'id="btn-fullscreen"' /tmp/v2-index.html && ok "fullscreen button present" || bad "fullscreen button"
grep -q 'id="btn-mode"' /tmp/v2-index.html && ok "mode button present" || bad "mode button"
grep -q 'id="proxy-view"' /tmp/v2-index.html && ok "proxy iframe present" || bad "proxy iframe"
grep -q "Cloud Chromium desktop streamed" /tmp/v2-index.html && bad "description still present" || ok "description removed"
TOKEN=$(grep -o 'const PROXY_TOKEN = "[a-f0-9]*"' /tmp/v2-index.html | cut -d'"' -f2)
[ ${#TOKEN} -eq 32 ] && ok "token extracted (${TOKEN:0:8}...)" || bad "token extract"

echo "== proxy auth =="
C=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/proxy?url=http://example.com/")
[ "$C" = "403" ] && ok "no token -> 403" || bad "no token -> $C"
C=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/proxy?url=file:///etc/passwd&token=$TOKEN")
[ "$C" = "400" ] && ok "file:// rejected -> 400" || bad "file:// -> $C"
C=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/proxy?url=http://example.com/&token=wrong")
[ "$C" = "403" ] && ok "bad token -> 403" || bad "bad token -> $C"

echo "== proxy rewrite (local origin) =="
cat > /tmp/v2-origin-server.py <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
PAGE = b'''<html><head><base href="http://127.0.0.1:8901/sub/">
<link rel="stylesheet" href="style.css"></head><body>
<a href="/page2">rel</a><a href="http://127.0.0.1:8901/abs">abs</a>
<img src="pic.png"><form action="/search" method="get"></form>
</body></html>'''
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 8901), H).serve_forever()
PY
python3 /tmp/v2-origin-server.py >/tmp/v2-origin.log 2>&1 &
sleep 1
OUT=$(curl -s -D /tmp/v2-hdrs.txt "http://127.0.0.1:$PORT/proxy?url=http://127.0.0.1:$ORIGIN_PORT/&token=$TOKEN")
echo "$OUT" | grep -q '/proxy?url=http%3A%2F%2F127.0.0.1%3A8901%2Fpage2' \
  && ok "relative link rewritten" || bad "relative link rewrite"
echo "$OUT" | grep -q '/proxy?url=http%3A%2F%2F127.0.0.1%3A8901%2Fsub%2Fstyle.css' \
  && ok "<base href> respected" || bad "base href"
echo "$OUT" | grep -q '/proxy?url=http%3A%2F%2F127.0.0.1%3A8901%2Fabs' \
  && ok "absolute link rewritten" || bad "absolute link rewrite"
grep -qi "x-frame-options" /tmp/v2-hdrs.txt \
  && bad "X-Frame-Options not stripped" || ok "X-Frame-Options stripped"
grep -qi "content-security-policy" /tmp/v2-hdrs.txt \
  && bad "CSP not stripped" || ok "CSP stripped"

echo "== WebSocket -> VNC relay =="
python3 - $PORT <<'PY'
import socket, base64, os, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=15)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET /websockify HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n"
           "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
           "Sec-WebSocket-Version: 13\r\n\r\n" % key).encode())
resp = b""
while b"\r\n\r\n" not in resp:
    c = s.recv(4096)
    if not c: sys.exit("no handshake response")
    resp += c
assert b"101" in resp.split(b"\r\n")[0], resp[:80]
print("  PASS: WS upgrade -> 101")

def recvn(n):
    d = b""
    while len(d) < n:
        c = s.recv(n - len(d))
        if not c: sys.exit("eof")
        d += c
    return d

def ws_send(payload):
    mask = os.urandom(4)
    n = len(payload)
    hdr = bytes([0x82])
    if n < 126: hdr += bytes([0x80 | n])
    elif n < 65536: hdr += bytes([0x80 | 126]) + n.to_bytes(2, "big")
    else: hdr += bytes([0x80 | 127]) + n.to_bytes(8, "big")
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

class Reader:
    def __init__(self): self.buf = bytearray()
    def read(self, n):
        while len(self.buf) < n:
            h = recvn(2)
            op, ln = h[0] & 0x0F, h[1] & 0x7F
            if ln == 126: ln = int.from_bytes(recvn(2), "big")
            elif ln == 127: ln = int.from_bytes(recvn(8), "big")
            assert op == 0x2, "expected binary frame, got %d" % op
            self.buf += recvn(ln)
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

r = Reader()
ver = r.read(12)
assert ver.startswith(b"RFB 003.008"), ver
print("  PASS: RFB handshake", ver.strip().decode())
ws_send(b"RFB 003.008\n")
ntypes = r.read(1)[0]
stypes = r.read(ntypes)
assert 1 in stypes, stypes
ws_send(bytes([1]))
assert r.read(4) == b"\x00\x00\x00\x00", "security result"
ws_send(bytes([1]))  # ClientInit shared
sinit = r.read(24)
w, h = int.from_bytes(sinit[0:2], "big"), int.from_bytes(sinit[2:4], "big")
assert (w, h) == (1280, 720), (w, h)
print("  PASS: framebuffer 1280x720")
namelen = int.from_bytes(sinit[20:24], "big")  # name-length is the last 4 of the 24
r.read(namelen)
# SetPixelFormat: 32bpp true colour; SetEncodings: raw; full update request
ws_send(bytes([0,0,0,0, 32,24,0,1, 0,255,0,255,0,255, 16,8,0, 0,0,0]))
ws_send(bytes([2, 0, 0, 1]) + (0).to_bytes(4, "big"))
ws_send(bytes([3, 0]) + (0).to_bytes(2, "big")*2
        + (1280).to_bytes(2, "big") + (720).to_bytes(2, "big"))
assert r.read(1) == b"\x00", "FramebufferUpdate type"
r.read(1)  # padding byte
nrects = int.from_bytes(r.read(2), "big")
assert nrects >= 1, "no rects"
print("  PASS: got %d rect(s)" % nrects)
need = 1280*720*4
px = r.read(12 + need)  # rect header (12) + pixels
px = px[12:12+need]
mean = sum(px) / len(px)
print("  PASS: framebuffer bytes=%d mean=%.1f" % (len(px), mean))
assert mean > 10, "framebuffer black?"
print("  PASS: framebuffer non-black")
PY
[ $? -eq 0 ] && ok "WS/VNC/RFB end-to-end" || bad "WS/VNC/RFB end-to-end"

echo "== cleanup =="
pkill -f "server.py $PORT"; pkill -f "v2-fakevnc"; pkill -f "v2-origin-server"
sleep 1
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
