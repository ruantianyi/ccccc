#!/bin/bash
# verify-proxy3.sh - tests for proxy-mode optimizations:
# POST forwarding, in-page shim (fetch/XHR/WebSocket), /proxy-ws relay,
# CORS preflight. Run after verify-v2.sh (regression).
set -u
cd "$(dirname "$0")"

PORT=18082
ORIGIN_PORT=8902
WS_PORT=8903
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "== syntax =="
python3 -m py_compile server.py && ok "server.py compiles" || bad "server.py compiles"

echo "== shim JS syntax + logic (node) =="
python3 - <<'PY'
import re
src = open("server.py").read()
m = re.search(r'SHIM_BODY = r"""(.*?)"""\n', src, re.DOTALL)
assert m, "SHIM_BODY not found"
open("/tmp/shim.js", "w").write(m.group(1))
print("shim extracted: %d bytes" % len(m.group(1)))
PY
node --check /tmp/shim.js && ok "shim JS parses" || bad "shim JS parse"
cat > /tmp/shim-test.js <<'JS'
const fs = require('fs'), vm = require('vm');
const shimSrc = fs.readFileSync('/tmp/shim.js', 'utf8');
const fetchCalls = [], xhrCalls = [], wsCalls = [];
function FakeXHR() {}
FakeXHR.prototype.open = function (m, u) { xhrCalls.push([m, u]); };
function FakeWS(url, proto) { wsCalls.push([url, proto]); }
FakeWS.prototype = {};
FakeWS.CONNECTING = 0; FakeWS.OPEN = 1; FakeWS.CLOSING = 2; FakeWS.CLOSED = 3;
function Request(u, r) { this.url = u; }
const fakeWindow = {
  __PROXY_ORIGIN__: 'http://127.0.0.1:8902/sub/page.html',
  __PROXY_TOKEN__: 'tok123',
  fetch: function (u, init) { fetchCalls.push(['NATIVE', u]); return Promise.resolve(0); },
  XMLHttpRequest: FakeXHR,
  WebSocket: FakeWS,
};
const sandbox = { window: fakeWindow,
  location: { protocol: 'http:', host: '127.0.0.1:18082' },
  URL, encodeURIComponent, Request, Array };
vm.createContext(sandbox);
vm.runInContext(shimSrc, sandbox);
const W = sandbox.window;
const enc = encodeURIComponent;
let fails = 0;
function check(name, cond, extra) {
  if (cond) console.log('  PASS: ' + name);
  else { console.log('  FAIL: ' + name + (extra ? ' :: ' + extra : '')); fails++; }
}
// fetch with relative URL -> proxified against ORIGIN
W.fetch('api/data.json');
check('fetch(relative) proxified',
  fetchCalls[0][1] === '/proxy?url=' + enc('http://127.0.0.1:8902/sub/api/data.json') + '&token=' + enc('tok123'),
  JSON.stringify(fetchCalls[0]));
// fetch with absolute URL
W.fetch('https://example.com/x?q=1');
check('fetch(absolute) proxified',
  fetchCalls[1][1] === '/proxy?url=' + enc('https://example.com/x?q=1') + '&token=' + enc('tok123'),
  JSON.stringify(fetchCalls[1]));
// fetch with data: URL -> native passthrough
W.fetch('data:text/plain,hi');
check('fetch(data:) passthrough', fetchCalls[2][0] === 'NATIVE' && fetchCalls[2][1] === 'data:text/plain,hi',
  JSON.stringify(fetchCalls[2]));
// fetch with Request object
W.fetch(new Request('other.json', {}), { method: 'POST' });
check('fetch(Request) proxified',
  fetchCalls[3][1] && fetchCalls[3][1].url === '/proxy?url=' + enc('http://127.0.0.1:8902/sub/other.json') + '&token=' + enc('tok123'),
  JSON.stringify(fetchCalls[3][1] && fetchCalls[3][1].url));
// XHR open rewritten
const x = new W.XMLHttpRequest();
x.open('POST', '/abs/path');
check('XHR open rewritten',
  xhrCalls[0][0] === 'POST' && xhrCalls[0][1] === '/proxy?url=' + enc('http://127.0.0.1:8902/abs/path') + '&token=' + enc('tok123'),
  JSON.stringify(xhrCalls[0]));
// WebSocket -> relay URL (page is http: so relay is ws:)
new W.WebSocket('ws://127.0.0.1:8903/echo');
check('WebSocket -> relay URL',
  wsCalls[0][0] === 'ws://127.0.0.1:18082/proxy-ws?url=' + enc('ws://127.0.0.1:8903/echo') + '&token=' + enc('tok123'),
  JSON.stringify(wsCalls[0]));
check('WebSocket statics preserved', W.WebSocket.OPEN === 1 && W.WebSocket.CLOSED === 3);
process.exit(fails ? 1 : 0);
JS
node /tmp/shim-test.js && ok "shim logic (fetch/XHR/WS)" || bad "shim logic (fetch/XHR/WS)"

echo "== starting origin + ws-echo + server.py =="
pkill -f "server.py $PORT" 2>/dev/null; pkill -f "p3-origin" 2>/dev/null
pkill -f "p3-wsecho" 2>/dev/null; sleep 1
cat > /tmp/p3-origin.py <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def page(self, body, ctype="text/html; charset=utf-8", code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == "/":
            self.page(b'<html><head>'
                      b'<meta http-equiv="Content-Security-Policy" content="script-src \'self\'">'
                      b'<title>Origin</title></head><body>'
                      b'<p id="marker">SIMPLE-PAGE-MARKER</p>'
                      b'<a href="/other">other</a>'
                      b'<form action="/submit" method="post">'
                      b'<input name="q" value="1"></form>'
                      b'</body></html>')
        elif self.path == "/data.json":
            self.page(b'{"ok": true, "n": 42}', "application/json")
        else:
            self.page(b"not found", "text/plain", 404)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        pbody = self.rfile.read(n) if n else b""
        self.page(("<html><head></head><body>METHOD=POST BODY=%s "
                   '<a href="/back">back</a></body></html>'
                   % pbody.decode()).encode())
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 8902), H).serve_forever()
PY
cat > /tmp/p3-wsecho.py <<'PY'
# minimal WS echo server (stdlib only)
import socket, threading, base64, hashlib
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
def recvn(c, n):
    d = b""
    while len(d) < n:
        ch = c.recv(n - len(d))
        if not ch: raise ConnectionError("eof")
        d += ch
    return d
def frame(op, payload):
    h = bytes([0x80 | op])
    n = len(payload)
    h += bytes([n]) if n < 126 else bytes([126]) + n.to_bytes(2, "big")
    return h + payload
def handle(c):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            ch = c.recv(4096)
            if not ch: return
            req += ch
        head = req.split(b"\r\n\r\n")[0].decode("latin1")
        if "upgrade" not in head.lower(): return
        key = [l.split(":", 1)[1].strip() for l in head.split("\r\n")
               if l.lower().startswith("sec-websocket-key")][0]
        acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                   "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
        while True:
            h = recvn(c, 2)
            op, ln = h[0] & 0x0F, h[1] & 0x7F
            if ln == 126: ln = int.from_bytes(recvn(c, 2), "big")
            mask = recvn(c, 4)
            pl = recvn(c, ln) if ln else b""
            pl = bytes(b ^ mask[i % 4] for i, b in enumerate(pl))
            if op == 0x8:
                c.sendall(frame(0x8, b"")); return
            c.sendall(frame(0x1, pl))  # echo as text
    except Exception:
        pass
    finally:
        c.close()
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 8903)); srv.listen(5)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
PY
python3 /tmp/p3-origin.py >/tmp/p3-origin.log 2>&1 &
python3 /tmp/p3-wsecho.py >/tmp/p3-wsecho.log 2>&1 &
python3 server.py $PORT >/tmp/p3-server.log 2>&1 &
SRV=$!
sleep 2
kill -0 $SRV 2>/dev/null && ok "server.py on $PORT" || bad "server.py start"
TOKEN=$(curl -s http://127.0.0.1:$PORT/ | grep -o 'const PROXY_TOKEN = "[a-f0-9]*"' | cut -d'"' -f2)
[ ${#TOKEN} -eq 32 ] && ok "token extracted" || bad "token extract"

echo "== POST through proxy =="
OUT=$(curl -s -X POST -d 'a=1&b=2' "http://127.0.0.1:$PORT/proxy?url=http://127.0.0.1:$ORIGIN_PORT/submit&token=$TOKEN")
echo "$OUT" | grep -q "METHOD=POST BODY=a=1&b=2" \
  && ok "POST forwarded with body" || bad "POST forward: $(echo "$OUT" | head -c 120)"
echo "$OUT" | grep -q '/proxy?url=http%3A%2F%2F127.0.0.1%3A8902%2Fback' \
  && ok "POST response HTML rewritten" || bad "POST response rewrite"
C=$(curl -s -o /dev/null -w "%{http_code}" -X POST -d 'a=1' \
  "http://127.0.0.1:$PORT/proxy?url=http://127.0.0.1:$ORIGIN_PORT/submit&token=wrong")
[ "$C" = "403" ] && ok "POST bad token -> 403" || bad "POST bad token -> $C"

echo "== shim injection + simple-page safety =="
OUT=$(curl -s "http://127.0.0.1:$PORT/proxy?url=http://127.0.0.1:$ORIGIN_PORT/&token=$TOKEN")
echo "$OUT" | grep -q "SIMPLE-PAGE-MARKER" \
  && ok "simple page content intact" || bad "simple page content"
echo "$OUT" | grep -q 'window.__PROXY_ORIGIN__="http://127.0.0.1:8902/"' \
  && ok "shim origin injected (final URL)" || bad "shim origin"
echo "$OUT" | grep -q "window.fetch=function" \
  && ok "shim fetch wrapper present" || bad "shim fetch wrapper"
echo "$OUT" | grep -qi 'http-equiv="content-security-policy"' \
  && bad "meta CSP not stripped" || ok "meta CSP stripped"
echo "$OUT" | grep -q '/proxy?url=http%3A%2F%2F127.0.0.1%3A8902%2Fother' \
  && ok "links still rewritten with shim" || bad "link rewrite with shim"

echo "== CORS =="
curl -s -D /tmp/p3-cors.txt -o /dev/null "http://127.0.0.1:$PORT/proxy?url=http://127.0.0.1:$ORIGIN_PORT/data.json&token=$TOKEN"
grep -qi "access-control-allow-origin: \*" /tmp/p3-cors.txt \
  && ok "ACAO: * on /proxy" || bad "ACAO header"
C=$(curl -s -o /dev/null -w "%{http_code}" -X OPTIONS \
  -H "Access-Control-Request-Headers: content-type" \
  "http://127.0.0.1:$PORT/proxy?url=http://127.0.0.1:$ORIGIN_PORT/&token=$TOKEN")
[ "$C" = "204" ] && ok "OPTIONS preflight -> 204" || bad "OPTIONS -> $C"

echo "== /proxy-ws auth =="
C=$(curl -s -o /dev/null -w "%{http_code}" -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "http://127.0.0.1:$PORT/proxy-ws?url=ws://127.0.0.1:$WS_PORT/echo&token=wrong")
[ "$C" = "403" ] && ok "/proxy-ws bad token -> 403" || bad "/proxy-ws bad token -> $C"
C=$(curl -s -o /dev/null -w "%{http_code}" -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  "http://127.0.0.1:$PORT/proxy-ws?url=http://127.0.0.1:$ORIGIN_PORT/&token=$TOKEN")
[ "$C" = "400" ] && ok "/proxy-ws http URL -> 400" || bad "/proxy-ws http URL -> $C"
C=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/proxy-ws?url=ws://127.0.0.1:$WS_PORT/echo&token=$TOKEN")
[ "$C" = "400" ] && ok "/proxy-ws no upgrade -> 400" || bad "/proxy-ws no upgrade -> $C"

echo "== /proxy-ws relay end-to-end =="
python3 - $PORT $WS_PORT "$TOKEN" <<'PY'
import socket, base64, os, sys
port, wsport, token = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
s = socket.create_connection(("127.0.0.1", port), timeout=15)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET /proxy-ws?url=ws://127.0.0.1:%d/echo&token=%s HTTP/1.1\r\n"
           "Host: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"
           % (wsport, token, key)).encode())
resp = b""
while b"\r\n\r\n" not in resp:
    c = s.recv(4096)
    if not c: sys.exit("no handshake")
    resp += c
assert b"101" in resp.split(b"\r\n")[0], resp[:80]
print("  PASS: /proxy-ws upgrade -> 101")
def recvn(n):
    d = b""
    while len(d) < n:
        c = s.recv(n - len(d))
        if not c: sys.exit("eof")
        d += c
    return d
def send_text(payload):
    mask = os.urandom(4); n = len(payload)
    s.sendall(bytes([0x81, 0x80 | n]) + mask
              + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
def read_frame():
    h = recvn(2)
    op, ln = h[0] & 0x0F, h[1] & 0x7F
    assert not (h[1] & 0x80), "server frame must not be masked"
    if ln == 126: ln = int.from_bytes(recvn(2), "big")
    return op, recvn(ln)
send_text(b"hello-proxy")
op, pl = read_frame()
assert op == 0x1 and pl == b"hello-proxy", (op, pl)
print("  PASS: echo round-trip through relay")
mask = os.urandom(4)
s.sendall(bytes([0x88, 0x80]) + mask)  # masked close, empty payload
op, _ = read_frame()
assert op == 0x8, op
print("  PASS: close relayed")
PY
[ $? -eq 0 ] && ok "/proxy-ws relay works" || bad "/proxy-ws relay"

echo "== cleanup =="
pkill -f "server.py $PORT"; pkill -f "p3-origin"; pkill -f "p3-wsecho"
sleep 1
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
