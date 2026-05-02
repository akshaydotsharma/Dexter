#!/usr/bin/env bash
# Ship a development-signed build of personal-dashboard to your iPhone over the
# internet via a Cloudflare quick tunnel + itms-services OTA install.
#
# No App Store Connect, no paid Apple Developer Program required. Works with the
# free "personal team" provisioning profile — but it expires every 7 days, so
# you'll re-run this weekly.
#
# Usage:
#   bash mobile/ota/ship.sh
#
# What this does:
#   1. Regenerates the Xcode project (xcodegen).
#   2. Archives + exports a development-signed .ipa to /tmp/ota/.
#   3. Generates manifest.plist + index.html for OTA install.
#   4. Starts a local HTTP server on :8081.
#   5. Starts a Cloudflare quick tunnel; captures the public HTTPS URL.
#   6. Writes the public URL into manifest.plist + index.html.
#   7. Prints (and copies to clipboard) the install URL.
#
# Open the install URL on your iPhone in Safari and tap "Install".
# Ctrl-C in this terminal cleans up the tunnel and HTTP server.

set -euo pipefail

# ---- Paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${MOBILE_DIR}/PersonalDashboard.xcodeproj"
SCHEME="PersonalDashboard"
BUNDLE_ID="com.akshaysharma.personaldashboard"
APP_TITLE="Dashboard"
OTA_DIR="/tmp/ota"
PORT=8081

# ---- Pre-flight ----
command -v xcodegen >/dev/null  || { echo "❌ xcodegen not found (brew install xcodegen)"; exit 1; }
command -v cloudflared >/dev/null || { echo "❌ cloudflared not found (brew install cloudflared)"; exit 1; }
command -v xcodebuild >/dev/null || { echo "❌ xcodebuild not found"; exit 1; }
command -v python3 >/dev/null    || { echo "❌ python3 not found"; exit 1; }

cd "${MOBILE_DIR}"

echo "→ regenerating Xcode project"
xcodegen generate >/dev/null

# ---- Clean OTA staging ----
rm -rf "${OTA_DIR}"
mkdir -p "${OTA_DIR}"

# ---- Bundle version: timestamp-based so iOS treats every install as a new build ----
BUNDLE_VERSION="$(date +%s)"
SHORT_VERSION="$(awk -F'"' '/CFBundleShortVersionString/{print $2; exit}' "${MOBILE_DIR}/project.yml" 2>/dev/null)"
SHORT_VERSION="${SHORT_VERSION:-0.1.0}"
echo "→ bundle ${SHORT_VERSION} (${BUNDLE_VERSION})"

# ---- Archive ----
ARCHIVE_PATH="${OTA_DIR}/PersonalDashboard.xcarchive"
echo "→ archiving (this takes ~1-2 minutes the first time)"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "${ARCHIVE_PATH}" \
  CURRENT_PROJECT_VERSION="${BUNDLE_VERSION}" \
  MARKETING_VERSION="${SHORT_VERSION}" \
  archive \
  2>&1 | grep -E "(error:|warning:|\*\* )" || true

[ -d "${ARCHIVE_PATH}" ] || { echo "❌ archive failed"; exit 1; }

# ---- Export .ipa ----
echo "→ exporting development .ipa"
xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportOptionsPlist "${SCRIPT_DIR}/ExportOptions.plist" \
  -exportPath "${OTA_DIR}" \
  -allowProvisioningUpdates \
  2>&1 | grep -E "(error:|warning:|\*\* )" || true

EXPORTED_IPA="$(find "${OTA_DIR}" -maxdepth 1 -name "*.ipa" | head -1)"
[ -f "${EXPORTED_IPA}" ] || { echo "❌ export failed: no .ipa produced"; exit 1; }
mv "${EXPORTED_IPA}" "${OTA_DIR}/app.ipa"

# ---- Profile expiry (informational) ----
PROFILE_EXPIRY="$(security cms -D -i "${ARCHIVE_PATH}/Products/Applications/PersonalDashboard.app/embedded.mobileprovision" 2>/dev/null \
  | plutil -extract ExpirationDate raw - 2>/dev/null | cut -d'T' -f1 || echo "unknown")"

# ---- Start HTTP server ----
echo "→ starting HTTP server on :${PORT}"
cd "${OTA_DIR}"
python3 -m http.server "${PORT}" --bind 127.0.0.1 >"${OTA_DIR}/http.log" 2>&1 &
HTTP_PID=$!

# ---- Start cloudflared quick tunnel ----
echo "→ starting cloudflared quick tunnel"
cloudflared tunnel --url "http://127.0.0.1:${PORT}" >"${OTA_DIR}/cloudflared.log" 2>&1 &
TUNNEL_PID=$!

cleanup() {
  echo ""
  echo "→ cleaning up (tunnel + http server)"
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
[ -n "${TUNNEL_URL}" ] || { echo "❌ tunnel did not come up in 20s — see ${OTA_DIR}/cloudflared.log"; exit 1; }
echo "→ tunnel: ${TUNNEL_URL}"

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

# ---- Output ----
INSTALL_URL="${TUNNEL_URL}/"
ITMS_URL="itms-services://?action=download-manifest&url=${MANIFEST_URL}"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Open this URL in Safari on your iPhone, then tap Install:"
echo ""
echo "  ${INSTALL_URL}"
echo ""
echo "  Profile expires: ${PROFILE_EXPIRY}  (re-run this script after that)"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  Tip: this URL has been copied to your clipboard."
echo "  AirDrop or text it to yourself, or type it into Safari."
echo ""
echo "  Press Ctrl-C here once the install starts on your phone"
echo "  (the IPA download streams from this Mac through the tunnel)."

printf "%s" "${INSTALL_URL}" | pbcopy 2>/dev/null || true

# ---- Block until user kills it ----
wait "${TUNNEL_PID}"
