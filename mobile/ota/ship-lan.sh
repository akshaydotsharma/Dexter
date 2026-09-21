#!/usr/bin/env bash
# Archive, sign, and export the Dexter iOS app as a .ipa. Install it on the
# phone over a USB cable or the same wifi network with:
#   xcrun devicectl device install app --device <UDID> <path/to/app.ipa>
#
# This script does not serve the IPA and does not open any tunnel. It only
# builds the artifact and prints the path (#579 — the Cloudflare OTA install
# path is retired; installs go over cable or LAN via devicectl).
#
# Usage:
#   bash mobile/ota/ship-lan.sh
#
# Prereqs:
#   - Phone paired with the Mac at least once (devicectl needs that to see it).
#   - Personal-dashboard dev server running (npm run dev), only if you rely
#     on the legacy OTA_API_URL fallback baked into the build — see below.

set -euo pipefail

# ---- Paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${MOBILE_DIR}/PersonalDashboard.xcodeproj"
SCHEME="PersonalDashboard"
# Output dir. Overridable via the environment because it's shared machine-wide,
# and this script does `rm -rf "${OTA_DIR}"` near the start: two worktrees
# shipping at once don't merely race, the second one deletes the first's build
# and leaves its own `app.ipa` at the same path. The loser then installs the
# winner's app while every log line says success.
#
# That is not hypothetical. It happened twice on 2026-07-31 while #428 and #429
# were in flight together, and both times the phone silently ended up with the
# other branch's binary.
#
#   OTA_DIR=/tmp/ota-myfeature bash mobile/ota/ship-lan.sh
#
# Default is unchanged, so a single-worktree ship behaves exactly as before.
OTA_DIR="${OTA_DIR:-/tmp/ota}"

# ---- Pre-flight ----
command -v xcodegen     >/dev/null || { echo "xcodegen not found (brew install xcodegen)"; exit 1; }
command -v xcodebuild   >/dev/null || { echo "xcodebuild not found"; exit 1; }
command -v python3      >/dev/null || { echo "python3 not found"; exit 1; }

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

# ---- Resolve OpenAI API key (voice transcription, #151) ----
# Same source order as Anthropic. Unlike Anthropic this is OPTIONAL: with no
# key the app falls back to on-device English dictation, so we warn but do
# NOT abort the build.
if [ -z "${OPENAI_API_KEY:-}" ]; then
    if [ -f "${MOBILE_DIR}/../server/.env" ]; then
        # `|| true`: under `set -euo pipefail` a grep no-match returns 1 and the
        # pipeline would abort the script. OpenAI is optional (we warn below), so
        # swallow the miss and let the empty-key fallback handle it.
        OPENAI_API_KEY="$(grep -E '^OPENAI_API_KEY=' "${MOBILE_DIR}/../server/.env" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
    fi
fi
if [ -n "${OPENAI_API_KEY:-}" ]; then
    echo "-> OPENAI_API_KEY resolved (length=${#OPENAI_API_KEY})"
else
    OPENAI_API_KEY=""
    echo "-> WARNING: OPENAI_API_KEY not set (env or server/.env). Cloud voice transcription (Hindi/Hinglish) will be DISABLED; the app falls back to on-device English dictation."
fi

# ---- Resolve USDA FoodData Central API key (meal lookups, #653) ----
# Same source order and the same optionality as OpenAI. With no key the meal
# estimator stops looking food composition and portion weights up and falls back
# to the model's own numbers, which is how it behaved before #653. Nothing
# breaks, estimates just get less accurate, so this warns and never aborts.
#
# The trailing `sed` is not decoration: a key pasted into server/.env with a
# leading space is a real thing that happened on 2026-09-22, and api.data.gov
# answers HTTP 403 API_KEY_INVALID for it with no hint that whitespace is the
# problem.
if [ -z "${USDA_FDC_API_KEY:-}" ]; then
    if [ -f "${MOBILE_DIR}/../server/.env" ]; then
        USDA_FDC_API_KEY="$(grep -E '^USDA_FDC_API_KEY=' "${MOBILE_DIR}/../server/.env" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
    fi
fi
if [ -n "${USDA_FDC_API_KEY:-}" ]; then
    echo "-> USDA_FDC_API_KEY resolved (length=${#USDA_FDC_API_KEY})"
else
    USDA_FDC_API_KEY=""
    echo "-> WARNING: USDA_FDC_API_KEY not set (env or server/.env). Meal estimates will fall back to the model's own numbers instead of looking food up. Free key: https://fdc.nal.usda.gov/api-key-signup"
fi

# ---- Regenerate project ----
echo "-> regenerating Xcode project"
xcodegen generate >/dev/null

# ---- Clean OTA staging ----
rm -rf "${OTA_DIR}"
mkdir -p "${OTA_DIR}"

# ---- Remove key-bearing artifacts if the build does not finish cleanly ----
# app.ipa and the .xcarchive both carry the Anthropic/OpenAI keys in plaintext
# (baked into Info.plist), so a half-finished build left behind is a credential
# sitting on disk. On a successful run this trap does nothing — app.ipa is the
# deliverable, and build-to-phone's stale-IPA check relies on it staying put
# with a fresh mtime (project_ship_lan_stale_ipa_trap). On any failure it wipes
# the whole staging dir so nothing key-bearing survives.
cleanup_on_failure() {
    local exit_code=$?
    if [ "${exit_code}" -ne 0 ]; then
        echo ""
        echo "-> build failed (exit ${exit_code}); removing ${OTA_DIR} (key-bearing build artifacts)"
        rm -rf "${OTA_DIR}"
    fi
}
trap cleanup_on_failure EXIT

# ---- Versioning: a.b.c (d) ----
# a.b live in mobile/VERSION (manually bumped on big refactors / minor cuts).
# c   = commits AFTER the one that last touched mobile/VERSION —
#       so the first ship after a major.minor bump reads as a.b.0
#       (matching semver "1.0.0 = first stable cut"), and each subsequent
#       merge to main bumps c by 1.
# d   = local build counter at mobile/.build_count (gitignored). Each
#       ship-lan.sh run bumps it by 1; plain Xcode builds keep their own
#       project.yml default ("1") since they don't go through this script.
VERSION_FILE="${MOBILE_DIR}/VERSION"
BUILD_COUNT_FILE="${MOBILE_DIR}/.build_count"

MAJOR_MINOR="$(tr -d '[:space:]' < "${VERSION_FILE}" 2>/dev/null)"
MAJOR_MINOR="${MAJOR_MINOR:-0.1}"

# Hash of the commit where mobile/VERSION was last touched. We count
# commits strictly AFTER it (BUMP..HEAD, exclusive) so the bump commit
# itself does NOT count toward c — first ship after a bump = a.b.0.
VERSION_BUMP_COMMIT="$(git -C "${MOBILE_DIR}/.." log -1 --format=%H -- "${VERSION_FILE}" 2>/dev/null)"
if [ -n "${VERSION_BUMP_COMMIT}" ]; then
    PATCH="$(git -C "${MOBILE_DIR}/.." rev-list --count "${VERSION_BUMP_COMMIT}..HEAD" 2>/dev/null || echo "0")"
else
    # VERSION not committed yet (e.g. brand-new branch with uncommitted file)
    PATCH="0"
fi

# Local build counter (d) — per change-cycle, not lifetime. Resets to 1
# whenever the branch changes OR the local main tip advances (i.e. a merge
# happened since the last ship). Same branch + same main tip = same change,
# so iterative re-ships during one ticket increment as expected.
#
# State format: <branch>:<main_tip>:<count>. Falls back gracefully for
# legacy formats ("<branch>:<count>" or just "<count>") by treating them
# as a fresh start.
LAST_LINE="$(cat "${BUILD_COUNT_FILE}" 2>/dev/null || echo "")"
LAST_BRANCH=""
LAST_MAIN_TIP=""
LAST_COUNT="0"
IFS=':' read -r f1 f2 f3 <<<"${LAST_LINE}"
if [ -n "${f3}" ]; then
    LAST_BRANCH="${f1}"; LAST_MAIN_TIP="${f2}"; LAST_COUNT="${f3}"
fi

CURRENT_BRANCH="$(git -C "${MOBILE_DIR}/.." rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
CURRENT_MAIN_TIP="$(git -C "${MOBILE_DIR}/.." rev-parse main 2>/dev/null || echo "")"

if [ "${LAST_BRANCH}" = "${CURRENT_BRANCH}" ] && [ "${LAST_MAIN_TIP}" = "${CURRENT_MAIN_TIP}" ]; then
    BUILD_NUMBER=$((LAST_COUNT + 1))
else
    BUILD_NUMBER=1
fi
echo "${CURRENT_BRANCH}:${CURRENT_MAIN_TIP}:${BUILD_NUMBER}" > "${BUILD_COUNT_FILE}"

SHORT_VERSION="${MAJOR_MINOR}.${PATCH}"
BUNDLE_VERSION="${BUILD_NUMBER}"
echo "-> versioning: v${SHORT_VERSION} (${BUNDLE_VERSION})"

# ---- Pre-authorize codesign (silence the keychain password prompt) ----
# The free personal-team signing cert regenerates ~weekly; each new private key
# lands in the login keychain with a fresh ACL, so codesign prompts for the
# keychain (login) password on the next archive. Re-applying the partition list
# on every ship authorizes codesign for ALL current signing keys, silently.
#
# The login password is read here only by /usr/bin/security, from the keychain
# item created by `bash mobile/ota/setup-signing-noprompt.sh`. If that setup
# hasn't been run, we skip quietly — the old GUI prompt just appears as before.
LOGIN_KC="${HOME}/Library/Keychains/login.keychain-db"
SIGNING_PW="$(security find-generic-password -a "${USER}" -s dexter-signing-login-pw -w 2>/dev/null || true)"
if [ -n "${SIGNING_PW}" ]; then
    if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${SIGNING_PW}" "${LOGIN_KC}" >/dev/null 2>&1; then
        echo "-> codesign authorized via keychain (no password prompt expected)"
    else
        echo "-> WARNING: could not pre-authorize codesign; a keychain prompt may appear"
    fi
    unset SIGNING_PW
else
    echo "-> tip: run 'bash mobile/ota/setup-signing-noprompt.sh' once to stop the keychain password prompt"
fi

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
    OPENAI_API_KEY="${OPENAI_API_KEY}" \
    USDA_FDC_API_KEY="${USDA_FDC_API_KEY}" \
    -allowProvisioningUpdates \
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

# ---- Drop the archive (key-bearing, no longer needed after export) ----
# Only app.ipa is needed to install. The .xcarchive is bulkier and carries the
# same plaintext key in its own Info.plist, so remove it now instead of
# leaving it on disk until the next ship's `rm -rf "${OTA_DIR}"`.
rm -rf "${ARCHIVE_PATH}"

IPA_PATH="${OTA_DIR}/app.ipa"

echo ""
echo "================================================================"
echo "  app.ipa: ${IPA_PATH}"
echo ""
echo "  Install over cable or wifi:"
echo "    xcrun devicectl device install app --device <UDID> ${IPA_PATH}"
echo ""
echo "  Find <UDID>: xcrun devicectl list devices"
echo ""
echo "  Profile expires: ${PROFILE_EXPIRY}  (re-run this script after that)"
echo "================================================================"

printf "%s" "${IPA_PATH}" | pbcopy 2>/dev/null || true
