#!/bin/bash
# Academic Code Tester - Cloud Chromium via noVNC
# Single-session build (no Replit AI quota needed).
# Launches Xvfb, fluxbox, x11vnc, Chromium, and websockify/noVNC.
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

echo "[start] Starting Chromium on :1..."
DISPLAY=:1 chromium \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --no-first-run \
  --no-default-browser-check \
  --window-size=1280,720 \
  --window-position=0,0 \
  --user-data-dir="$PROFILE_DIR" \
  about:blank &
sleep 3

echo "[start] Fetching noVNC client files (cached on disk after first run)..."
mkdir -p "$NOVNC_DIR"
if [ ! -f "$NOVNC_DIR/vnc.html" ]; then
  curl -sSL "https://github.com/novnc/noVNC/archive/refs/tags/v${NOVNC_VERSION}.tar.gz" \
    | tar xz -C "$NOVNC_DIR" --strip-components=1
fi
test -f "$NOVNC_DIR/core/rfb.js" || { echo "[ERROR] noVNC download failed"; exit 1; }

echo "[start] Launching websockify on port ${PORT} (foreground)..."
echo "[start] Open the Replit webview to access the browser."
echo "[start] WARNING: VNC has no password and the web UI has no sign-in."
echo "[start] Anyone with the URL can control this Chromium session. Keep it private."

# Run websockify in the foreground so the Replit run command stays alive
# exactly as long as the web server does. --web serves ./public
# (our UI at / and noVNC files under /novnc/); /websockify proxies to VNC.
exec websockify --web ./public "$PORT" "localhost:$VNC_PORT"
