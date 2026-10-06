# Academic Code Tester - Manual Build (no Replit AI quota used)

Single-session cloud Chromium via noVNC, packaged for a classic Replit Repl.

## What's included
- `start.sh`: Launches Xvfb :1 (1280x720x24), fluxbox, x11vnc (localhost only,
  no password), Chromium (`--no-sandbox --disable-gpu --disable-dev-shm-usage
  --no-first-run --no-default-browser-check`), vendors the noVNC v1.4.0 client
  from GitHub on first run (cached on disk afterwards), then runs websockify
  **in the foreground** on `$PORT` (defaults to 8080) serving `./public`.
- `replit.nix`: `{ pkgs }: { deps = [...] }` with chromium, xorg.xvfb, x11vnc,
  fluxbox, python3Packages.websockify. (Dropped the unneeded `xvfb_run`
  wrapper and the `novnc` package — the client is vendored at runtime instead,
  so there's no dependency on the package's install layout.)
- `.replit`: `run = "bash start.sh"`, `[nix] channel = "stable-23_11"`,
  `[deployment]` with `run = ["bash", "start.sh"]` and
  `deploymentTarget = "gce"` (Reserved VM — correct for a stateful server;
  autoscale/static targets don't fit a persistent VNC session).
- `public/index.html`: Light-mode UI importing `./novnc/core/rfb.js`
  (vendored, no CDN dependency). Controls: Connect, Disconnect, and
  "Maximize to tab", which fills the tab container via CSS without using
  browser fullscreen. WebSocket connects to `/websockify` on the same
  host/port, matching websockify's `--web` proxy convention.
- Download handling: Chromium's `Preferences` is preseeded so remote
  downloads land in `/home/runner/chrome-downloads` on the server, visible
  in the Repl's file pane for retrieval. A website cannot silently save to
  an arbitrary folder on your computer — your browser controls the save.

## How to use (no AI quota)
1. Create a **new classic Repl** (Bash template), not the Agent-built App —
   these files follow classic Repl conventions (`replit.nix` + `.replit`).
2. Upload the contents of `academic-code-tester-upload.zip` to the Repl root.
3. Press **Run**. First run downloads noVNC (~a few MB) and caches it.
4. Open the webview and click **Connect**.

## Security notes (honest)
- VNC has no password (per the original spec) and is bound to localhost, but
  the web UI has no sign-in: anyone with the URL controls the same Chromium
  session. Keep the URL private.
- Single session: per-visitor isolation (separate profiles, token-routed
  websockify, idle expiry) and a public-only egress proxy were started by the
  Replit Agent but need backend work to finish. Not implemented here.
- Chrome Web Store extensions install inside the remote Chromium
  (no `--disable-extensions` flag is passed).

## Verification done (local end-to-end, 2026-10-05)
Ran the full stack on Ubuntu 24.04: Xvfb :1 @1280x720x24, fluxbox, x11vnc
(localhost:5901, nopw), Chrome with the exact flags from `start.sh`,
websockify on :18080 serving `./public`.
- HTTP 200 on `/` with correct `<title>`; noVNC v1.4.0 vendored at runtime.
- WebSocket upgrade at `/websockify` -> 101; full RFB handshake through the
  proxy; raw framebuffer pixels confirmed non-black (mean byte 250/255).
- Headless-Chrome render test: page loads, Connect -> "Connected.", remote
  desktop visibly renders (Chromium window + fluxbox panel) in the canvas.
- Maximize-to-tab toggles correctly both ways; floating Restore button stays
  clickable above the overlay.
- Two real bugs found and fixed during verification:
  1. Chrome opens at 10x10 on a fresh profile -> added
     `--window-size=1280,720 --window-position=0,0` to `start.sh`.
  2. noVNC's `RFB` must be constructed with a container `<div>`, not a
     `<canvas>` (it appends its own canvas; canvas children never render,
     which left the viewport black) -> fixed `index.html`.
  3. The maximized overlay covered the header's Restore button -> added a
     floating `#btn-restore` (fixed, z-index above the overlay).

## Not verified
- An actual run on Replit (blocked: see status file). The stack itself is
  proven; only Replit's environment remains untested.

## Not included
- The 1000-word single-paragraph claim that the site is "solely" an academic
  coding interface. The description stays honest about what the app does.
