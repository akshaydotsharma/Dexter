#!/usr/bin/env bash
# Same-network ship: build with the Mac's LAN IP baked in for API calls,
# and serve the OTA install page via a Cloudflare quick tunnel (HTTPS is
# required by itms-services://, plain LAN HTTP cannot install IPAs).
#
# Why this exists:
#   ship.sh ties install AND API to a single Tailscale tunnel. If MagicDNS
#   on the phone hiccups, the App Intent can't reach the API. ship-lan.sh
#   decouples the two: install via public-DNS Cloudflare URL, API direct
#   over wifi to the Mac's LAN IP.
#
# Usage:
#   bash mobile/ota/ship-lan.sh
#
# Prereqs:
#   - Phone and Mac on the same wifi.
#   - cloudflared installed (brew install cloudflared).
#   - Personal-dashboard dev server running (npm run dev). Port is
#     auto-detected: tries 3001 first (where it lives when 3000 is taken),
#     then 3000.

set -euo pipefail

# ---- Paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${MOBILE_DIR}/PersonalDashboard.xcodeproj"
SCHEME="PersonalDashboard"
OTA_DIR="/tmp/ota"
PORT=8081

# ---- Pre-flight ----
command -v xcodegen     >/dev/null || { echo "xcodegen not found (brew install xcodegen)"; exit 1; }
command -v xcodebuild   >/dev/null || { echo "xcodebuild not found"; exit 1; }
command -v python3      >/dev/null || { echo "python3 not found"; exit 1; }
command -v cloudflared  >/dev/null || { echo "cloudflared not found (brew install cloudflared)"; exit 1; }

cd "${MOBILE_DIR}"

# ---- Resolve LAN IP and dev server port (legacy — see note) ----
# Once the iOS app moved on-device for AI + storage (PR #22-onwards),
# OTA_API_URL is no longer load-bearing for the iPhone; AppConfig only
# falls through to it if a future feature adds a server-bound call. We
# still bake a sensible value so the Info.plist is well-formed.
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")"

DEV_PORT=""
for p in 3001 3000 3030; do
    if curl -s --max-time 1 "http://127.0.0.1:${p}/api/dashboard/config" | grep -q layout_preference 2>/dev/null; then
        DEV_PORT="${p}"; break
    fi
done
DEV_PORT="${DEV_PORT:-3001}"

API_URL="http://${LAN_IP}:${DEV_PORT}/api"
echo "-> Mac LAN: ${LAN_IP}"
echo "-> dev server port (best-effort): ${DEV_PORT}"
echo "-> OTA_API_URL baked into IPA: ${API_URL} (legacy, unused by on-device AI path)"

# ---- Resolve Anthropic API key ----
# Source order: env override > server/.env. The key is baked into the IPA
# so the on-device AI pipeline can reach api.anthropic.com without any
# per-device setup. AppConfig.swift reads it from Info.plist at runtime.
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    if [ -f "${MOBILE_DIR}/../server/.env" ]; then
        ANTHROPIC_API_KEY="$(grep -E '^ANTHROPIC_API_KEY=' "${MOBILE_DIR}/../server/.env" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    fi
fi
[ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "ANTHROPIC_API_KEY not set (env or server/.env). Aborting — AI features won't work without it."; exit 1; }
echo "-> ANTHROPIC_API_KEY resolved (length=${#ANTHROPIC_API_KEY})"

# ---- Regenerate project ----
echo "-> regenerating Xcode project"
xcodegen generate >/dev/null

# ---- Clean OTA staging ----
rm -rf "${OTA_DIR}"
mkdir -p "${OTA_DIR}"

# ---- Versioning: a.b.c (d) ----
# a.b live in mobile/VERSION (manually bumped on big refactors / minor cuts).
# c   = commits on the current branch since mobile/VERSION last changed —
#       so it auto-resets to 0 when you bump a or b, and increments by 1
#       on every merge to main thereafter.
# d   = local build counter at mobile/.build_count (gitignored). Each
#       ship-lan.sh run bumps it by 1; plain Xcode builds keep their own
#       project.yml default ("1") since they don't go through this script.
VERSION_FILE="${MOBILE_DIR}/VERSION"
BUILD_COUNT_FILE="${MOBILE_DIR}/.build_count"

MAJOR_MINOR="$(tr -d '[:space:]' < "${VERSION_FILE}" 2>/dev/null)"
MAJOR_MINOR="${MAJOR_MINOR:-0.1}"

# Hash of the commit where mobile/VERSION was last touched. We count from
# its PARENT (^) so that the VERSION-change merge itself counts toward c —
# i.e. the first build after introducing a new major.minor reads as
# a.b.1 rather than a.b.0 (matches the user-facing rule "every merge bumps
# c by 1"). If the bump commit is the very first commit in the repo,
# fall back to total commit count.
VERSION_BUMP_COMMIT="$(git -C "${MOBILE_DIR}/.." log -1 --format=%H -- "${VERSION_FILE}" 2>/dev/null)"
if [ -n "${VERSION_BUMP_COMMIT}" ]; then
    if git -C "${MOBILE_DIR}/.." rev-parse "${VERSION_BUMP_COMMIT}^" >/dev/null 2>&1; then
        PATCH="$(git -C "${MOBILE_DIR}/.." rev-list --count "${VERSION_BUMP_COMMIT}^..HEAD" 2>/dev/null || echo "1")"
    else
        PATCH="$(git -C "${MOBILE_DIR}/.." rev-list --count HEAD 2>/dev/null || echo "1")"
    fi
else
    # VERSION not committed yet (e.g. brand-new branch with uncommitted file)
    PATCH="1"
fi

# Bump local build counter.
PREV_BUILD="$(cat "${BUILD_COUNT_FILE}" 2>/dev/null || echo "0")"
BUILD_NUMBER=$((PREV_BUILD + 1))
echo "${BUILD_NUMBER}" > "${BUILD_COUNT_FILE}"

SHORT_VERSION="${MAJOR_MINOR}.${PATCH}"
BUNDLE_VERSION="${BUILD_NUMBER}"
echo "-> versioning: v${SHORT_VERSION} (${BUNDLE_VERSION})"

# ---- Archive (Release, dev signing) ----
ARCHIVE_PATH="${OTA_DIR}/PersonalDashboard.xcarchive"
echo "-> archiving (1-2 min)"
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "${ARCHIVE_PATH}" \
    CURRENT_PROJECT_VERSION="${BUNDLE_VERSION}" \
    MARKETING_VERSION="${SHORT_VERSION}" \
    OTA_API_URL="${API_URL}" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
    archive \
    2>&1 | grep -E "(error:|warning: .*\.swift:|\*\* )" || true

[ -d "${ARCHIVE_PATH}" ] || { echo "archive failed"; exit 1; }

# ---- Export .ipa ----
echo "-> exporting development .ipa"
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist "${SCRIPT_DIR}/ExportOptions.plist" \
    -exportPath "${OTA_DIR}" \
    -allowProvisioningUpdates \
    2>&1 | grep -E "(error:|warning:|\*\* )" || true

EXPORTED_IPA="$(find "${OTA_DIR}" -maxdepth 1 -name "*.ipa" | head -1)"
[ -f "${EXPORTED_IPA}" ] || { echo "export failed: no .ipa produced"; exit 1; }
mv "${EXPORTED_IPA}" "${OTA_DIR}/app.ipa"

# ---- Profile expiry (informational) ----
PROFILE_EXPIRY="$(security cms -D -i "${ARCHIVE_PATH}/Products/Applications/PersonalDashboard.app/embedded.mobileprovision" 2>/dev/null \
    | plutil -extract ExpirationDate raw - 2>/dev/null | cut -d'T' -f1 || echo "unknown")"

# ---- Start local HTTP server (will be reverse-proxied by cloudflared) ----
echo "-> starting HTTP server on :${PORT}"
cd "${OTA_DIR}"
python3 -m http.server "${PORT}" --bind 127.0.0.1 >"${OTA_DIR}/http.log" 2>&1 &
HTTP_PID=$!

# ---- Cloudflare quick tunnel for the install page ----
echo "-> starting cloudflared quick tunnel"
cloudflared tunnel --url "http://127.0.0.1:${PORT}" >"${OTA_DIR}/cloudflared.log" 2>&1 &
TUNNEL_PID=$!

cleanup() {
    echo ""
    echo "-> cleaning up (cloudflared + http server)"
    kill "${TUNNEL_PID}" 2>/dev/null || true
    kill "${HTTP_PID}" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- Wait for tunnel URL ----
TUNNEL_URL=""
for i in {1..40}; do
    TUNNEL_URL="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "${OTA_DIR}/cloudflared.log" | head -1 || true)"
    [ -n "${TUNNEL_URL}" ] && break
    sleep 0.5
done
[ -n "${TUNNEL_URL}" ] || { echo "tunnel did not come up in 20s — see ${OTA_DIR}/cloudflared.log"; exit 1; }
echo "-> tunnel: ${TUNNEL_URL}"

# ---- Render manifest.plist + index.html ----
IPA_URL="${TUNNEL_URL}/app.ipa"
MANIFEST_URL="${TUNNEL_URL}/manifest.plist"

sed -e "s|__IPA_URL__|${IPA_URL}|g" \
    -e "s|__BUNDLE_VERSION__|${SHORT_VERSION}|g" \
    "${SCRIPT_DIR}/manifest.template.plist" > "${OTA_DIR}/manifest.plist"

sed -e "s|__MANIFEST_URL__|${MANIFEST_URL}|g" \
    -e "s|__BUNDLE_VERSION__|${SHORT_VERSION} (${BUNDLE_VERSION})|g" \
    -e "s|__PROFILE_EXPIRY__|${PROFILE_EXPIRY}|g" \
    "${SCRIPT_DIR}/index.template.html" > "${OTA_DIR}/index.html"

INSTALL_URL="${TUNNEL_URL}/"

echo ""
echo "================================================================"
echo "  Open this URL in Safari on your iPhone, then tap Install:"
echo ""
echo "  ${INSTALL_URL}"
echo ""
echo "  Profile expires: ${PROFILE_EXPIRY}  (re-run this script after that)"
echo "================================================================"
echo ""
echo "  After install, the app will call the API at: ${API_URL}"
echo "  Phone and Mac must stay on the same wifi for that to work."
echo "  iOS will prompt 'Allow find devices on local network' the first"
echo "  time you run anything that touches the API. Tap Allow."
echo ""
echo "  Ctrl-C here once the install starts on your phone."

printf "%s" "${INSTALL_URL}" | pbcopy 2>/dev/null || true

wait "${TUNNEL_PID}"
