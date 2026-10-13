#!/bin/bash
# Academic Code Tester - Cloud Chromium via noVNC + private fetch proxy
# Launches Xvfb, fluxbox, x11vnc, Chromium, then server.py which serves
# ./public, relays WebSocket /websockify to VNC, and provides the private
# /proxy endpoint (pages fetched server-side, rendered in your own browser).
#
# Two independent browser machines:
#   machine 1: Xvfb :1, x11vnc :5901 (no password), Chromium profile 1
#   machine 2: Xvfb :2, x11vnc :5902 (password from $MACHINE2_VNC_PASS secret), Chromium profile 2
# Chromium profiles live INSIDE the workspace so cookies, history, logins and
# other browsing data survive restarts and VM recycles. Profiles are never wiped.
#
# Replit conventions followed:
# - Reads $PORT (set by Replit); defaults to 8080 for local runs.
# - Run command is `bash start.sh` (see .replit).
# - System deps installed via replit.nix (see replit.nix).
# - Machine 2 VNC password comes from the MACHINE2_VNC_PASS Replit Secret.

set -e

RES="1920x1080x24"
PORT="${PORT:-8080}"
VNC_PORT1=5901
VNC_PORT2=5902
PROFILE_DIR_1="/home/runner/workspace/.chrome-profile-1"
PROFILE_DIR_2="/home/runner/workspace/.chrome-profile-2"
DOWNLOAD_DIR="/home/runner/workspace/chrome-downloads"
NOVNC_VERSION="1.4.0"
NOVNC_DIR="./public/novnc"

echo "[start] Cleaning up any leftover processes..."
pkill Xvfb || true
pkill fluxbox || true
pkill x11vnc || true
pkill websockify || true
pkill chromium || true
sleep 1

echo "[start] Starting Xvfb on :1 and :2 (${RES})..."
Xvfb :1 -screen 0 "$RES" &
Xvfb :2 -screen 0 "$RES" &
sleep 2

echo "[start] Removing fluxbox decorations for Chromium (exact 1920x1080 fit)..."
mkdir -p ~/.fluxbox
if ! grep -q "^\[app\] (name=\[Cc\]hrom)" ~/.fluxbox/apps 2>/dev/null; then
  cat >> ~/.fluxbox/apps <<'EOF'
[app] (name=[Cc]hrom)
  [Deco] {NONE}
[end]
EOF
fi

echo "[start] Starting fluxbox window managers..."
DISPLAY=:1 fluxbox &
DISPLAY=:2 fluxbox &
sleep 2

echo "[start] Starting x11vnc for machine 1 (:1 -> 5901, no password; may frame-rate tuning)..."
x11vnc -display :1 -nopw -listen localhost -rfbport "$VNC_PORT1" -forever -shared -xkb \
  -wait 5 -defer 5 -nonap &
sleep 1

echo "[start] Starting x11vnc for machine 2 (:2 -> 5902, password-protected)..."
if [ -n "$MACHINE2_VNC_PASS" ]; then
  x11vnc -display :2 -passwd "$MACHINE2_VNC_PASS" -listen localhost -rfbport "$VNC_PORT2" -forever -shared -xkb \
    -wait 5 -defer 5 -nonap &
else
  echo "[start] WARNING: MACHINE2_VNC_PASS is not set; machine 2 VNC will have NO password."
  x11vnc -display :2 -nopw -listen localhost -rfbport "$VNC_PORT2" -forever -shared -xkb \
    -wait 5 -defer 5 -nonap &
fi
sleep 2

echo "[start] Preparing persistent Chromium profiles (never wiped)..."
for PDIR in "$PROFILE_DIR_1" "$PROFILE_DIR_2"; do
  mkdir -p "$PDIR/Default" "$DOWNLOAD_DIR"
  rm -f "$PDIR/SingletonLock" "$PDIR/SingletonSocket" "$PDIR/SingletonCookie"
  if [ ! -f "$PDIR/Default/Preferences" ]; then
    cat > "$PDIR/Default/Preferences" <<EOF
{
  "download": {
    "default_directory": "$DOWNLOAD_DIR",
    "directory_upgrade": true,
    "prompt_for_download": false
  }
}
EOF
  fi
done

echo "[start] Starting Chromium for machine 1 on :1 (windowed 1920x1080 at 0,0)..."
DISPLAY=:1 chromium \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --no-first-run \
  --no-default-browser-check \
  --window-size=1920,1080 \
  --window-position=0,0 \
  --force-device-scale-factor=1 \
  --user-data-dir="$PROFILE_DIR_1" \
  https://www.google.com &
echo "[start] Starting Chromium for machine 2 on :2 (windowed 1920x1080 at 0,0)..."
DISPLAY=:2 chromium \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage \
  --no-first-run \
  --no-default-browser-check \
  --window-size=1920,1080 \
  --window-position=0,0 \
  --force-device-scale-factor=1 \
  --user-data-dir="$PROFILE_DIR_2" \
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
echo "[start] server.py serves ./public, relays /websockify to machine 1 VNC,"
echo "[start] relays /websockify2 to machine 2 VNC, exposes the private /proxy"
echo "[start] endpoint, and reverse-proxies /sj/<token>/* to the Scramjet backend."
echo "[start] Open the Replit webview to access the browser."
echo "[start] NOTE: machine 1 VNC has no password; machine 2 VNC requires the"
echo "[start] MACHINE2_VNC_PASS secret. Anyone with the URL can control machine 1."
echo "[start] Keep it private."

exec python3 server.py "$PORT"
