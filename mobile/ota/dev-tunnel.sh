#!/usr/bin/env bash
# Expose the local Express dev server (port 3000) at /api over Tailscale Serve.
#
# Use this after `bash mobile/ota/ship.sh` has installed the app on your phone.
# While this script is running, the installed app can reach your live dev server
# at https://<host>.ts.net/api from anywhere on the Tailnet.
#
# Usage:
#   npm start &            # or in a separate terminal
#   bash mobile/ota/dev-tunnel.sh
#
# Override the API port:
#   API_PORT=4000 bash mobile/ota/dev-tunnel.sh
#
# Ctrl-C resets the /api Tailscale Serve config.

set -euo pipefail

# ---- PATH fallback for orphan Tailscale shim ----
# An uninstalled Tailscale.app can leave behind a broken shim in /usr/local/bin
# or wherever the PATH resolves `tailscale`. Detect and prefer the brew CLI.
if ! tailscale version >/dev/null 2>&1; then
  if [ -x /opt/homebrew/bin/tailscale ]; then
    export PATH="/opt/homebrew/bin:${PATH}"
  fi
fi

API_PORT="${API_PORT:-3000}"

# ---- Pre-flight: tooling ----
command -v tailscale >/dev/null 2>&1 || { echo "tailscale not found (brew install tailscale)"; exit 1; }
tailscale version >/dev/null 2>&1 || { echo "tailscale not working — is tailscaled running?"; exit 1; }

# ---- Pre-flight: dev server ----
if ! lsof -nP -iTCP:"${API_PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "(error) Nothing listening on :${API_PORT}. Run 'npm start' first (Express dev server expected on :${API_PORT})." >&2
  exit 1
fi

# ---- Resolve Tailscale hostname ----
TS_HOSTNAME="$(tailscale status --json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["Self"]["DNSName"].rstrip("."))' 2>/dev/null \
  || true)"
if [ -z "${TS_HOSTNAME}" ]; then
  echo "(error) Could not resolve Tailscale hostname. Is Tailscale running and logged in?" >&2
  echo "        Run: tailscale status" >&2
  exit 1
fi

# ---- Expose /api via Tailscale Serve ----
echo "-> exposing /api -> http://127.0.0.1:${API_PORT} via Tailscale Serve"
if ! tailscale serve --bg --set-path=/api "http://127.0.0.1:${API_PORT}" >/tmp/ts-dev-tunnel.log 2>&1; then
  echo "(error) tailscale serve failed:" >&2
  cat /tmp/ts-dev-tunnel.log >&2
  exit 1
fi

# ---- Cleanup on exit ----
cleanup() {
  echo ""
  echo "-> resetting Tailscale Serve config"
  tailscale serve reset 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- Status block ----
cat <<INFO
================================================================
  Dev API exposed at:
  https://${TS_HOSTNAME}/api

  Test from another Tailnet device:
    curl https://${TS_HOSTNAME}/api/health

  Edit server/, nodemon restarts, the phone sees it immediately.

  Press Ctrl-C to stop and reset the Tailscale Serve config.
================================================================
INFO

# ---- Block until Ctrl-C ----
while true; do sleep 60; done
