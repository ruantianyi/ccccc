#!/bin/bash
# Academic Code Tester - Cloud Chromium via noVNC + private fetch proxy
# Single-session build (no Replit AI quota needed).
# Launches Xvfb, fluxbox, x11vnc, Chromium, then server.py which serves
# ./public, relays WebSocket /websockify to VNC, and provides the private
# /proxy endpoint (pages fetched server-side, rendered in your own browser).
#
# Replit conventions followed:
# - Reads $PORT (set by Replit); defaults to 8080 for local runs.
# - Run command is `bash start.sh` (see .replit).
# - System deps installed via replit.nix (see replit.nix).

set -e

export DISPLAY=:1
RES="1280x720x24"
PORT="${PORT:-8080}"
VNC_PORT=5901
PROFILE_DIR="/home/runner/chrome-profile"
DOWNLOAD_DIR="/home/runner/chrome-downloads"
NOVNC_VERSION="1.4.0"
NOVNC_DIR="./public/novnc"

echo "[start] Cleaning up any leftover processes..."
pkill Xvfb || true
pkill fluxbox || true
pkill x11vnc || true
pkill websockify || true
pkill chromium || true
sleep 1

echo "[start] Starting Xvfb on :1 (${RES})..."
Xvfb :1 -screen 0 "$RES" &
sleep 2

echo "[start] Starting fluxbox window manager..."
DISPLAY=:1 fluxbox &
sleep 2

echo "[start] Starting x11vnc (localhost only, no password)..."
x11vnc -display :1 -nopw -listen localhost -rfbport "$VNC_PORT" -forever -shared &
sleep 2

echo "[start] Preparing Chromium profile..."
# Wipe the profile's Default dir each run: a stale Singleton lock or
# corrupted profile state can leave Chromium running without ever
# mapping a window (observed: healthy Sl processes, no X window).
rm -rf "${PROFILE_DIR:?PROFILE_DIR unset}/Default"
mkdir -p "$PROFILE_DIR/Default" "$DOWNLOAD_DIR"
# Preseed the download location; Chromium reads this on first run.
# Files downloaded in the remote browser land here on the server,
# where they can be retrieved from the Repl's file pane.
cat > "$PROFILE_DIR/Default/Preferences" <<EOF
{
  "download": {
    "default_directory": "$DOWNLOAD_DIR",
    "directory_upgrade": true,
    "prompt_for_download": false
  }
}
EOF

echo "[start] Starting Chromium on :1 (kiosk: fills the 1280x720 display exactly)..."
DISPLAY=:1 chromium \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --no-first-run \
  --no-default-browser-check \
  --kiosk \
  --user-data-dir="$PROFILE_DIR" \
  https://www.google.com &
sleep 3

echo "[start] Fetching noVNC client files (cached on disk after first run)..."
mkdir -p "$NOVNC_DIR"
if [ ! -f "$NOVNC_DIR/vnc.html" ]; then
  curl -sSL "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz" \
    | tar xz -C "$NOVNC_DIR" --strip-components=1
fi
test -f "$NOVNC_DIR/core/rfb.js" || { echo "[ERROR] noVNC download failed"; exit 1; }

echo "[start] Installing Scramjet proxy backend deps (cached in sj/node_modules)..."
if [ ! -d "sj/node_modules" ]; then
  (cd sj && npm install --no-audit --no-fund)
fi
test -f "sj/node_modules/@mercuryworkshop/scramjet/dist/scramjet.all.js" \
  || { echo "[ERROR] scramjet npm install failed"; exit 1; }

echo "[start] Starting Scramjet backend (Node, localhost only)..."
export SJ_PORT=18091
node sj/sj-server.js &
SJ_PID=$!
sleep 2
kill -0 "$SJ_PID" 2>/dev/null || { echo "[ERROR] sj-server.js exited"; exit 1; }

echo "[start] Launching server.py on port ${PORT} (foreground)..."
echo "[start] server.py serves ./public, relays /websockify to VNC,"
echo "[start] exposes the private /proxy endpoint, and reverse-proxies"
echo "[start] /sj/<token>/* to the Scramjet backend (service-worker mode)."
echo "[start] Open the Replit webview to access the browser."
echo "[start] WARNING: VNC has no password and the web UI has no sign-in."
echo "[start] Anyone with the URL can control this session. Keep it private."

# Run the server in the foreground so the Replit run command stays alive
# exactly as long as the web server does.
exec python3 server.py "$PORT"
