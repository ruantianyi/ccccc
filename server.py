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

Limitations of proxy mode (honest): simple pages work; complex JS-heavy
sites, POST forms, websockets inside pages, and some embedded media may
break. Cookies are kept in a single server-side jar (single-user design).
"""
import base64
import hashlib
import http.cookiejar
import http.server
import os
import re
import secrets
import select
import socket
import sys
import urllib.parse
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("PORT", "8080"))
VNC_HOST, VNC_PORT = "127.0.0.1", 5901
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

    text = ATTR_RE.sub(attr_repl, text)
    return CSS_URL_RE.sub(css_repl, text)


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
    hdr = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        hdr += bytes([n])
    elif n < 65536:
        hdr += bytes([126]) + n.to_bytes(2, "big")
    else:
        hdr += bytes([127]) + n.to_bytes(8, "big")
    return hdr + payload


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
                self.relay_websocket()
            else:
                self.send_error(400, "WebSocket upgrade required")
        elif parsed.path == "/proxy":
            self.serve_proxy(parsed)
        elif parsed.path in ("/", "/index.html"):
            self.serve_index()
        else:
            super().do_GET()

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

    # -- WebSocket -> VNC relay ------------------------------------------
    def relay_websocket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if not key:
            self.send_error(400, "Missing Sec-WebSocket-Key")
            return
        accept = base64.b64encode(
            hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.close_connection = True
        try:
            vnc = socket.create_connection((VNC_HOST, VNC_PORT), timeout=10)
        except OSError as e:
            sys.stderr.write("[server] VNC connect failed: %s\n" % e)
            return
        ws = self.connection
        try:
            self.pump(ws, vnc)
        finally:
            try:
                vnc.close()
            except OSError:
                pass

    def pump(self, ws, vnc):
        while True:
            r, _, _ = select.select([ws, vnc], [], [], 60)
            if ws in r:
                if not self.ws_to_vnc(ws, vnc):
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

    def ws_to_vnc(self, ws, vnc):
        hdr = recvn(ws, 2)
        if not hdr:
            return False
        b1, b2 = hdr[0], hdr[1]
        opcode = b1 & 0x0F
        masked = b2 & 0x80
        length = b2 & 0x7F
        if length == 126:
            ext = recvn(ws, 2)
            if not ext:
                return False
            length = int.from_bytes(ext, "big")
        elif length == 127:
            ext = recvn(ws, 8)
            if not ext:
                return False
            length = int.from_bytes(ext, "big")
        mask = recvn(ws, 4) if masked else None
        if masked and not mask:
            return False
        payload = recvn(ws, length) if length else b""
        if payload is None:
            return False
        if masked:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        if opcode == 0x8:  # close
            try:
                ws.sendall(build_ws_frame(0x8, b""))
            except OSError:
                pass
            return False
        if opcode == 0x9:  # ping -> pong
            try:
                ws.sendall(build_ws_frame(0xA, payload))
            except OSError:
                return False
            return True
        if opcode in (0x0, 0x1, 0x2):  # data: forward bytes to VNC
            try:
                vnc.sendall(payload)
            except OSError:
                return False
        return True

    # -- private fetch proxy --------------------------------------------
    def serve_proxy(self, parsed):
        q = urllib.parse.parse_qs(parsed.query)
        if not secrets.compare_digest(q.get("token", [""])[0], PROXY_TOKEN):
            self.send_error(403, "Forbidden: bad proxy token")
            return
        url = q.get("url", [""])[0].strip()
        if not url.lower().startswith(("http://", "https://")):
            self.send_error(400, "Only http/https URLs are proxied")
            return
        try:
            req = urllib.request.Request(url, headers={"User-Agent": ORIGIN_UA})
            resp = opener.open(req, timeout=25)
            body = resp.read()
        except Exception as e:
            self.send_error(502, "Fetch failed: %s: %s"
                          % (type(e).__name__, e))
            return
        ctype = resp.headers.get_content_type() or ""
        if ctype == "text/html":
            charset = resp.headers.get_content_charset() or "utf-8"
            try:
                text = body.decode(charset, errors="replace")
            except LookupError:
                text = body.decode("utf-8", errors="replace")
            body = rewrite_html(text, resp.geturl()).encode("utf-8")
            out_ctype = "text/html; charset=utf-8"
        else:
            out_ctype = (resp.headers.get("Content-Type")
                         or "application/octet-stream")
        self.send_response(resp.getcode() or 200)
        self.send_header("Content-Type", out_ctype)
        disp = resp.headers.get("Content-Disposition")
        if disp:
            self.send_header("Content-Disposition", disp)
        # Drop framing defenses so pages can render in our iframe.
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print("[server] Academic Code Tester on :%d (proxy token %s...)"
          % (PORT, PROXY_TOKEN[:8]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
