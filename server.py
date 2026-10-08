#!/usr/bin/env python3
"""
Academic Code Tester - single-port server (stdlib only).

Does three jobs on one port (Replit only exposes $PORT):

1. Serves ./public statically (the web UI + vendored noVNC client).
2. Relays WebSocket /websockify to the local VNC server (x11vnc on
   127.0.0.1:5901). This is the "VNC mode": the remote desktop is rendered
   on the cloud server and streamed as pixels.
3. Serves a private fetch-and-rewrite web proxy at /proxy. This is the
   "Proxy mode": the cloud server fetches pages server-side and the
   visitor's own browser renders them locally. Downloads therefore land on
   the visitor's computer and the clipboard is local, while all origin
   traffic still goes through the cloud server. /proxy requires the
   per-start token that the server embeds into index.html, so it is as
   private as the page URL itself.

Proxy mode compatibility (no tradeoffs for simple pages):
  - HTML/CSS links, forms (GET and POST), and meta refresh targets are
    rewritten to stay inside /proxy.
  - Every proxied HTML page gets a small defensive in-page shim
    (SHIM_BODY) that reroutes the page's own fetch(), XMLHttpRequest, and
    WebSocket calls through the proxy, so JS-heavy pages and in-page
    sockets keep working. The shim is wrapped in try/catch and only
    changes behavior for pages that actually use those APIs; simple pages
    render exactly as before.
  - /proxy-ws relays page websockets to the origin (ws:// and wss://).
  - /proxy answers CORS preflights so the shim's fetch()/XHR calls are
    allowed from the sandboxed iframe.

Honest limits: pages that build request URLs from location.host, pages
using ServiceWorkers, and exotic subprotocols may still break. Cookies
are kept in a single server-side jar (single-user design).
"""
import base64
import hashlib
import http.client
import http.cookiejar
import http.server
import json
import os
import re
import secrets
import select
import socket
import ssl
import sys
import urllib.parse
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT", "8080"))
VNC_HOST, VNC_PORT = "127.0.0.1", 5901
SJ_HOST, SJ_PORT = "127.0.0.1", int(os.environ.get("SJ_PORT", "18091"))
ROOT = os.path.dirname(os.path.abspath(__file__))
PUBLIC_DIR = os.path.join(ROOT, "public")
PROXY_TOKEN = secrets.token_hex(16)
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ORIGIN_UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
             "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

ATTR_RE = re.compile(r'''(href|src|action|data-src)\s*=\s*(["'])(.*?)\2''',
                     re.IGNORECASE)
CSS_URL_RE = re.compile(r'''url\(\s*(["']?)(.*?)\1\s*\)''', re.IGNORECASE)
BASE_RE = re.compile(r'''<base[^>]+href\s*=\s*(["'])(.*?)\1''', re.IGNORECASE)
META_CSP_RE = re.compile(
    r'''<meta[^>]+http-equiv\s*=\s*(["'])content-security-policy\1[^>]*>''',
    re.IGNORECASE)

# In-page compatibility shim, injected into every proxied HTML page right
# after <head>. Defensive by design: everything is inside try/catch, each
# API is only wrapped if it exists, and wrappers fall back to the native
# call whenever a URL cannot be proxified. Pages that never call
# fetch/XHR/WebSocket behave exactly as if the shim were not there.
SHIM_BODY = r"""
(function(){
try{
var ORIGIN=window.__PROXY_ORIGIN__,TOKEN=window.__PROXY_TOKEN__;
if(!ORIGIN||!TOKEN)return;
function proxify(u){
  try{
    var a=new URL(u,ORIGIN).href;
    if(!/^https?:\/\//i.test(a))return null;
    return '/proxy?url='+encodeURIComponent(a)+'&token='+encodeURIComponent(TOKEN);
  }catch(e){return null;}
}
if(window.fetch){
  var _fetch=window.fetch.bind(window);
  window.fetch=function(input,init){
    var u=(typeof input==='string')?input:(input&&input.url);
    var p=u?proxify(u):null;
    if(p===null)return _fetch(input,init);
    if(typeof input==='string')return _fetch(p,init);
    try{return _fetch(new Request(p,input),init);}catch(e){return _fetch(input,init);}
  };
}
if(window.XMLHttpRequest){
  var _open=window.XMLHttpRequest.prototype.open;
  window.XMLHttpRequest.prototype.open=function(method,url){
    var p=proxify(url);
    if(p!==null){
      var args=Array.prototype.slice.call(arguments);
      args[1]=p;
      return _open.apply(this,args);
    }
    return _open.apply(this,arguments);
  };
}
if(window.WebSocket){
  var _WS=window.WebSocket;
  function PWS(url,protocols){
    var abs=null;
    try{abs=new URL(url,ORIGIN).href;}catch(e){abs=null;}
    if(abs===null||!/^wss?:\/\//i.test(abs)){
      return protocols===undefined?new _WS(url):new _WS(url,protocols);
    }
    var rs=(location.protocol==='https:')?'wss':'ws';
    var relay=rs+'://'+location.host+'/proxy-ws?url='+encodeURIComponent(abs)
      +'&token='+encodeURIComponent(TOKEN);
    return protocols===undefined?new _WS(relay):new _WS(relay,protocols);
  }
  PWS.prototype=_WS.prototype;
  PWS.CONNECTING=_WS.CONNECTING;PWS.OPEN=_WS.OPEN;
  PWS.CLOSING=_WS.CLOSING;PWS.CLOSED=_WS.CLOSED;
  window.WebSocket=PWS;
}
}catch(e){}
})();
"""


def proxify_url(val, base):
    """Rewrite an origin URL to our /proxy URL, or None to leave it alone."""
    val = (val or "").strip()
    if not val:
        return None
    low = val.lower()
    if low.startswith(("data:", "javascript:", "mailto:", "#")) \
            or val.startswith("/proxy?"):
        return None
    absu = urllib.parse.urljoin(base, val)
    if not absu.lower().startswith(("http://", "https://")):
        return None
    return ("/proxy?url=" + urllib.parse.quote(absu, safe="") +
            "&token=" + PROXY_TOKEN)


def rewrite_html(text, base):
    """Rewrite page URLs so navigation stays inside /proxy."""
    m = BASE_RE.search(text)
    if m:
        base = urllib.parse.urljoin(base, m.group(2))

    def attr_repl(mo):
        new = proxify_url(mo.group(3), base)
        if new is None:
            return mo.group(0)
        return "%s=%s%s%s" % (mo.group(1), mo.group(2), new, mo.group(2))

    def css_repl(mo):
        q, val = mo.group(1), mo.group(2)
        if not val or val.startswith(("data:", "/proxy?")):
            return mo.group(0)
        new = proxify_url(val, base)
        if new is None:
            return mo.group(0)
        return "url(%s%s%s)" % (q, new, q)

    text = META_CSP_RE.sub("", text)  # let our injected shim run
    text = ATTR_RE.sub(attr_repl, text)
    return CSS_URL_RE.sub(css_repl, text)


def inject_shim(text, origin_url):
    """Inject the compatibility shim right after <head> (or <html>)."""
    init = ("<script>window.__PROXY_ORIGIN__=%s;window.__PROXY_TOKEN__=%s;</script>"
            "<script>%s</script>"
            % (json.dumps(origin_url), json.dumps(PROXY_TOKEN), SHIM_BODY))
    m = re.search(r"<head[^>]*>", text, re.IGNORECASE)
    if m:
        return text[:m.end()] + init + text[m.end():]
    m = re.search(r"<html[^>]*>", text, re.IGNORECASE)
    if m:
        return text[:m.end()] + init + text[m.end():]
    return init + text


def recvn(sock, n):
    data = b""
    while len(data) < n:
        try:
            chunk = sock.recv(n - len(data))
        except OSError:
            return None
        if not chunk:
            return None
        data += chunk
    return data


def build_ws_frame(opcode, payload):
    """Build an unmasked server->client WebSocket frame."""
    hdr = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        hdr += bytes([n])
    elif n < 65536:
        hdr += bytes([126]) + n.to_bytes(2, "big")
    else:
        hdr += bytes([127]) + n.to_bytes(8, "big")
    return hdr + payload


def build_masked_frame(opcode, payload):
    """Build a masked client->server WebSocket frame."""
    mask = os.urandom(4)
    hdr = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        hdr += bytes([0x80 | n])
    elif n < 65536:
        hdr += bytes([0x80 | 126]) + n.to_bytes(2, "big")
    else:
        hdr += bytes([0x80 | 127]) + n.to_bytes(8, "big")
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    return hdr + mask + masked


class Handler(http.server.SimpleHTTPRequestHandler):
    server_version = "ACT/1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=PUBLIC_DIR, **kwargs)

    def log_message(self, fmt, *args):  # quieter logs
        sys.stderr.write("[server] " + fmt % args + "\n")

    def list_directory(self, path):  # no directory listings
        self.send_error(404, "Not found")

    # -- routing ---------------------------------------------------------
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/websockify":
            if self.headers.get("Upgrade", "").lower() == "websocket":
                self.relay_websocket_vnc()
            else:
                self.send_error(400, "WebSocket upgrade required")
        elif parsed.path == "/proxy":
            self.serve_proxy(parsed, "GET")
        elif parsed.path == "/proxy-ws":
            if self.headers.get("Upgrade", "").lower() == "websocket":
                self.relay_websocket_proxy(parsed)
            else:
                self.send_error(400, "WebSocket upgrade required")
        elif parsed.path == "/sj" or parsed.path.startswith("/sj/"):
            self.serve_sj(parsed)
        elif parsed.path in ("/", "/index.html"):
            self.serve_index()
        else:
            super().do_GET()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/proxy":
            self.serve_proxy(parsed, "POST")
        else:
            self.send_error(405, "Method not allowed")

    def do_OPTIONS(self):
        # CORS preflight for the in-page shim's fetch()/XHR calls.
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path in ("/proxy", "/proxy-ws"):
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods",
                             "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers",
                             self.headers.get("Access-Control-Request-Headers",
                                              "*"))
            self.send_header("Access-Control-Max-Age", "86400")
            self.end_headers()
        else:
            self.send_error(404, "Not found")

    def serve_index(self):
        try:
            with open(os.path.join(PUBLIC_DIR, "index.html"), "rb") as f:
                data = f.read().replace(b"__PROXY_TOKEN__",
                                        PROXY_TOKEN.encode())
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # -- WebSocket helpers ------------------------------------------------
    def ws_handshake(self, extra_headers=()):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            self.send_error(400, "Missing Sec-WebSocket-Key")
            return False
        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        for k, v in extra_headers:
            self.send_header(k, v)
        self.end_headers()
        self.close_connection = True
        return True

    def read_client_frame(self, ws):
        """Read one client frame. Returns (opcode, payload) or None."""
        hdr = recvn(ws, 2)
        if not hdr:
            return None
        b1, b2 = hdr[0], hdr[1]
        opcode = b1 & 0x0F
        masked = b2 & 0x80
        length = b2 & 0x7F
        if length == 126:
            ext = recvn(ws, 2)
            if not ext:
                return None
            length = int.from_bytes(ext, "big")
        elif length == 127:
            ext = recvn(ws, 8)
            if not ext:
                return None
            length = int.from_bytes(ext, "big")
        mask = recvn(ws, 4) if masked else None
        if masked and not mask:
            return None
        payload = recvn(ws, length) if length else b""
        if payload is None:
            return None
        if masked:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return opcode, payload

    # -- WebSocket -> VNC relay (VNC mode) ---------------------------------
    def relay_websocket_vnc(self):
        if not self.ws_handshake():
            return
        try:
            vnc = socket.create_connection((VNC_HOST, VNC_PORT), timeout=10)
        except OSError as e:
            sys.stderr.write("[server] VNC connect failed: %s\n" % e)
            return
        try:
            self.pump_vnc(self.connection, vnc)
        finally:
            try:
                vnc.close()
            except OSError:
                pass

    def pump_vnc(self, ws, vnc):
        while True:
            r, _, _ = select.select([ws, vnc], [], [], 60)
            if ws in r:
                fr = self.read_client_frame(ws)
                if fr is None:
                    return
                opcode, payload = fr
                if opcode == 0x8:  # close
                    try:
                        ws.sendall(build_ws_frame(0x8, b""))
                    except OSError:
                        pass
                    return
                if opcode == 0x9:  # ping -> pong
                    try:
                        ws.sendall(build_ws_frame(0xA, payload))
                    except OSError:
                        return
                    continue
                if opcode in (0x0, 0x1, 0x2):  # data: forward to VNC
                    try:
                        vnc.sendall(payload)
                    except OSError:
                        return
            if vnc in r:
                try:
                    chunk = vnc.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                try:
                    ws.sendall(build_ws_frame(0x2, chunk))
                except OSError:
                    return

    # -- page websocket relay (proxy mode) ----------------------------------
    def relay_websocket_proxy(self, parsed):
        q = urllib.parse.parse_qs(parsed.query)
        if not secrets.compare_digest(q.get("token", [""])[0], PROXY_TOKEN):
            self.send_error(403, "Forbidden: bad proxy token")
            return
        url = q.get("url", [""])[0].strip()
        if not url.lower().startswith(("ws://", "wss://")):
            self.send_error(400, "Only ws/wss URLs are proxied")
            return
        conn = self.origin_ws_connect(
            url, self.headers.get("Sec-WebSocket-Protocol"))
        if conn is None:
            self.send_error(502, "Could not reach origin websocket")
            return
        origin, proto = conn
        extra = [("Sec-WebSocket-Protocol", proto)] if proto else []
        if not self.ws_handshake(extra):
            try:
                origin.close()
            except OSError:
                pass
            return
        try:
            self.pump_ws_proxy(self.connection, origin)
        finally:
            try:
                origin.close()
            except OSError:
                pass

    def origin_ws_connect(self, url, protocols):
        """Act as a WS client toward the origin. Returns (sock, proto)."""
        u = urllib.parse.urlparse(url)
        if not u.hostname:
            return None
        secure = u.scheme == "wss"
        port = u.port or (443 if secure else 80)
        try:
            raw = socket.create_connection((u.hostname, port), timeout=10)
            if secure:
                raw = ssl.create_default_context().wrap_socket(
                    raw, server_hostname=u.hostname)
        except OSError:
            return None
        path = u.path or "/"
        if u.query:
            path += "?" + u.query
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            "GET %s HTTP/1.1" % path,
            "Host: %s" % u.hostname,
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: %s" % key,
            "Sec-WebSocket-Version: 13",
            "Origin: %s://%s" % ("https" if secure else "http", u.hostname),
            "User-Agent: %s" % ORIGIN_UA,
        ]
        if protocols:
            lines.append("Sec-WebSocket-Protocol: %s" % protocols)
        try:
            raw.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
            resp = b""
            while b"\r\n\r\n" not in resp:
                chunk = raw.recv(4096)
                if not chunk:
                    raise OSError("origin closed during handshake")
                resp += chunk
                if len(resp) > 16384:
                    raise OSError("handshake too large")
        except OSError:
            try:
                raw.close()
            except OSError:
                pass
            return None
        head = resp.split(b"\r\n\r\n")[0].decode("latin1")
        if "101" not in head.split("\r\n")[0]:
            try:
                raw.close()
            except OSError:
                pass
            return None
        m = re.search(r"Sec-WebSocket-Protocol:\s*(\S+)", head,
                      re.IGNORECASE)
        return raw, (m.group(1) if m else None)

    def pump_ws_proxy(self, client, origin):
        """Relay between the visitor's browser and the origin WS server.

        client->origin: parsed client frames are re-masked toward origin.
        origin->client: origin bytes are already WS frames; pass through.
        """
        while True:
            r, _, _ = select.select([client, origin], [], [], 60)
            if client in r:
                fr = self.read_client_frame(client)
                if fr is None:
                    return
                opcode, payload = fr
                if opcode == 0x8:  # close both ways
                    for s, f in ((client, build_ws_frame(0x8, b"")),
                                 (origin, build_masked_frame(0x8, b""))):
                        try:
                            s.sendall(f)
                        except OSError:
                            pass
                    return
                if opcode == 0x9:  # ping -> pong to client
                    try:
                        client.sendall(build_ws_frame(0xA, payload))
                    except OSError:
                        return
                    continue
                if opcode in (0x0, 0x1, 0x2):
                    try:
                        origin.sendall(build_masked_frame(opcode, payload))
                    except OSError:
                        return
            if origin in r:
                try:
                    chunk = origin.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                try:
                    client.sendall(chunk)
                except OSError:
                    return

    # -- private fetch proxy -------------------------------------------------
    def serve_proxy(self, parsed, method):
        q = urllib.parse.parse_qs(parsed.query)
        if not secrets.compare_digest(q.get("token", [""])[0], PROXY_TOKEN):
            self.send_error(403, "Forbidden: bad proxy token")
            return
        url = q.get("url", [""])[0].strip()
        if not url.lower().startswith(("http://", "https://")):
            self.send_error(400, "Only http/https URLs are proxied")
            return
        data = None
        fwd_headers = {"User-Agent": ORIGIN_UA}
        if method == "POST":
            try:
                length = int(self.headers.get("Content-Length", 0))
            except (TypeError, ValueError):
                length = 0
            data = self.rfile.read(length) if length > 0 else b""
            ctype = self.headers.get("Content-Type")
            if ctype:
                fwd_headers["Content-Type"] = ctype
        try:
            req = urllib.request.Request(url, data=data, headers=fwd_headers,
                                         method=method)
            resp = opener.open(req, timeout=25)
            body = resp.read()
        except Exception as e:
            self.send_error(502, "Fetch failed: %s: %s"
                          % (type(e).__name__, e))
            return
        final_url = resp.geturl()
        ctype = resp.headers.get_content_type() or ""
        if ctype == "text/html":
            charset = resp.headers.get_content_charset() or "utf-8"
            try:
                text = body.decode(charset, errors="replace")
            except LookupError:
                text = body.decode("utf-8", errors="replace")
            text = rewrite_html(text, final_url)
            body = inject_shim(text, final_url).encode("utf-8")
            out_ctype = "text/html; charset=utf-8"
        else:
            out_ctype = (resp.headers.get("Content-Type")
                         or "application/octet-stream")
        self.send_response(resp.getcode() or 200)
        self.send_header("Content-Type", out_ctype)
        disp = resp.headers.get("Content-Disposition")
        if disp:
            self.send_header("Content-Disposition", disp)
        # Drop framing defenses so pages can render in our iframe; allow
        # the in-page shim's fetch()/XHR calls from the sandboxed frame.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    # -- Scramjet backend (service-worker proxy mode) ------------------------
    # /sj/<token>/* is reverse-proxied to the local Node Scramjet backend.
    # The token is checked here in Python; Node trusts localhost.
    def serve_sj(self, parsed):
        rest = parsed.path[3:]  # strip "/sj"
        if not rest.startswith("/"):
            self.send_error(404, "Not found")
            return
        seg = rest[1:].split("/", 1)
        if not secrets.compare_digest(seg[0], PROXY_TOKEN):
            self.send_error(403, "Forbidden: bad proxy token")
            return
        node_path = "/" + seg[1] if len(seg) > 1 else "/"
        if parsed.query:
            node_path += "?" + parsed.query
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self.relay_sj_upgrade(node_path)
        else:
            self.forward_sj_http(node_path)

    def forward_sj_http(self, node_path):
        try:
            conn = http.client.HTTPConnection(SJ_HOST, SJ_PORT, timeout=25)
            headers = {}
            for k, v in self.headers.items():
                kl = k.lower()
                if kl in ("host", "connection", "upgrade", "proxy-connection",
                          "keep-alive", "transfer-encoding"):
                    continue
                headers[k] = v
            conn.request("GET", node_path, headers=headers)
            resp = conn.getresponse()
            body = resp.read()
        except Exception as e:
            self.send_error(502, "sj backend unreachable: %s" % e)
            return
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in ("transfer-encoding", "connection",
                             "keep-alive"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def relay_sj_upgrade(self, node_path):
        # Raw TCP pipe for the Wisp WebSocket: forward the HTTP upgrade
        # request verbatim (rewritten path), then shuttle bytes both ways.
        try:
            upstream = socket.create_connection((SJ_HOST, SJ_PORT),
                                                timeout=10)
        except OSError:
            self.send_error(502, "sj backend unreachable")
            return
        lines = ["GET %s HTTP/1.1" % node_path]
        for k, v in self.headers.items():
            kl = k.lower()
            if kl == "host":
                lines.append("Host: %s:%d" % (SJ_HOST, SJ_PORT))
            elif kl not in ("proxy-connection", "keep-alive"):
                lines.append("%s: %s" % (k, v))
        try:
            upstream.sendall(("\r\n".join(lines) + "\r\n\r\n")
                             .encode("latin1"))
            resp = b""
            while b"\r\n\r\n" not in resp:
                chunk = upstream.recv(4096)
                if not chunk:
                    raise OSError("sj closed during handshake")
                resp += chunk
                if len(resp) > 16384:
                    raise OSError("handshake too large")
            self.connection.sendall(resp)
            self.pump_raw(self.connection, upstream)
        except OSError:
            pass
        finally:
            try:
                upstream.close()
            except OSError:
                pass

    def pump_raw(self, a, b):
        while True:
            r, _, _ = select.select([a, b], [], [], 60)
            for src, dst in ((a, b), (b, a)):
                if src in r:
                    try:
                        chunk = src.recv(65536)
                    except OSError:
                        return
                    if not chunk:
                        return
                    try:
                        dst.sendall(chunk)
                    except OSError:
                        return


def main():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print("[server] Academic Code Tester on :%d (proxy token %s...)"
          % (PORT, PROXY_TOKEN[:8]))
    dump = os.environ.get("TOKEN_DUMP_PATH")
    if dump:
        with open(dump, "w") as f:
            f.write(PROXY_TOKEN)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
