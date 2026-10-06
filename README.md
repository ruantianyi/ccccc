# Academic Code Tester - Manual Build (no Replit AI quota used)

Cloud Chromium with two viewing modes, packaged for a classic Replit Repl.

## Modes

- **VNC mode** (default): the remote desktop is rendered on the cloud
  server and streamed as pixels via noVNC. Click Connect.
- **Proxy mode**: click "Proxy mode", type a URL, and the cloud server
  fetches the page server-side while **your own browser renders it
  locally**. All origin traffic still goes through the cloud server, but
  downloads land on your computer and copy/paste uses your local
  clipboard. The proxied page runs sandboxed in an iframe with an opaque
  origin, so it cannot reach the surrounding page.

## What's included

- `server.py` (stdlib only, no extra deps): serves `./public` statically,
  relays WebSocket `/websockify` to the local VNC server, and serves the
  private fetch-and-rewrite proxy at `/proxy`. Single process on `$PORT`
  (Replit exposes only one port).
- `start.sh`: Launches Xvfb :1 (1280x720x24), fluxbox, x11vnc (localhost
  only, no password), Chromium (`--no-sandbox --disable-gpu
  --disable-dev-shm-usage --no-first-run --no-default-browser-check
  --window-size=1280,720 --window-position=0,0`), vendors the noVNC v1.4.0
  client from GitHub on first run (cached on disk afterwards), then runs
  `server.py` **in the foreground** on `$PORT` (defaults to 8080).
- `replit.nix`: `{ pkgs }: { deps = [...] }` with chromium, xorg.xvfb,
  x11vnc, fluxbox, python3.
- `.replit`: `run = "bash start.sh"`, `[nix] channel = "stable-23_11"`,
  `[deployment]` with `run = ["bash", "start.sh"]` and
  `deploymentTarget = "gce"` (Reserved VM — correct for a stateful server;
  autoscale/static targets don't fit a persistent VNC session).
- `public/index.html`: Light-mode UI importing `./novnc/core/rfb.js`
  (vendored, no CDN dependency). Controls: Connect, Disconnect,
  "Maximize to tab" (fills the tab container via CSS), **Fullscreen**
  (real browser fullscreen API, like video streaming), and the
  **VNC/Proxy mode switch** with address bar. WebSocket connects to
  `/websockify` on the same host/port.

## Proxy mode details (honest)

- `/proxy` requires a per-start token that `server.py` generates and
  embeds into the served page. It is as private as the page URL itself:
  anyone with the URL can use it, nobody without it can. There is no
  separate login.
- The server rewrites page links/images/forms to route through `/proxy`,
  strips `X-Frame-Options`/`Content-Security-Policy` framing defenses so
  pages render in the iframe, and keeps cookies in a single server-side
  jar (single-user design).
- Limitations: simple pages work; complex JS-heavy sites, POST forms,
  in-page websockets, and some embedded media may break. Only
  http/https URLs are fetched.

## Download handling

- VNC mode: Chromium's `Preferences` is preseeded so remote downloads
  land in `/home/runner/chrome-downloads` on the server, visible in the
  Repl's file pane for retrieval. A website cannot silently save to an
  arbitrary folder on your computer — your browser controls the save.
- Proxy mode: downloads go straight to your computer, like normal browsing.

## How to use (no AI quota)

1. The Replit project was created via GitHub import from
   `ruantianyi/ccccc`. Pushes to that repo are the sync path; pull in the
   Replit project's Git pane to bring changes into the live project
   (Replit does not auto-pull).
2. Press **Run**. First run downloads noVNC (~a few MB) and caches it.
3. Open the webview: VNC mode -> click **Connect**; or switch to
   **Proxy mode** and type a URL.

## Security notes (honest)

- VNC has no password (per the original spec) and is bound to localhost,
  but the web UI has no sign-in: anyone with the URL controls the same
  Chromium session. Keep the URL private.
- Single session: per-visitor isolation (separate profiles, token-routed
  sessions, idle expiry) and a public-only egress proxy were started by
  the Replit Agent but need backend work to finish. Not implemented here.
- Chrome Web Store extensions install inside the remote Chromium
  (no `--disable-extensions` flag is passed).

## Verification done (local end-to-end)

**Round 1 (2026-10-05, websockify build):** full stack on Ubuntu 24.04 —
Xvfb :1 @1280x720x24, fluxbox, x11vnc (localhost:5901, nopw), Chrome with
the exact flags from `start.sh`, websockify serving `./public`. HTTP 200,
vendored noVNC v1.4.0, WebSocket upgrade -> 101, full RFB handshake,
non-black framebuffer (mean byte 250/255), headless-Chrome render test
(Connect -> "Connected."), maximize/restore toggling. Found and fixed 3
bugs (Chrome 10x10 window; canvas passed to noVNC RFB; maximized overlay
covering Restore).

**Round 2 (2026-10-06, server.py build):** `verify-v2.sh`, 21/21 passed.
Static serving, token injection (placeholder never leaks), 403 without
token, 400 for non-http(s) URLs, link rewriting incl. `<base href>`,
X-Frame-Options/CSP stripping, and the WebSocket->VNC relay carrying a
complete RFB handshake (version, security, ServerInit 1280x720) plus
3,686,400 framebuffer bytes (mean 110.5, non-black). Note: x11vnc could
not be reinstalled on the VM this round (apt blocked), so the relay was
verified against a scripted RFB peer instead of the real x11vnc. The
relay is protocol-opaque (it shuttles bytes untouched), and round 1
verified the real x11vnc+Chromium byte path, so this covers the new code.

## Not verified

- An actual run on Replit. The stack is proven locally; only Replit's
  environment remains untested — press Run in the Replit project and
  check the webview.

## Not included

- The 1000-word single-paragraph claim that the site is "solely" an
  academic coding interface. The description stays honest about what the
  app does.
