#!/usr/bin/env bash
# One-time setup: silence the macOS keychain password prompt that appears while
# shipping the iOS build (bash mobile/ota/ship-lan.sh).
#
# Why the prompt happens:
#   xcodebuild's `codesign` step needs the "Apple Development" private key in the
#   login keychain. If codesign isn't on that key's always-allow list, macOS
#   prompts for the keychain (login) password on every archive. The free
#   personal-team cert regenerates ~weekly, and each new key arrives with a fresh
#   ACL — so a one-time manual "Always Allow" keeps coming back.
#
# The fix (see ship-lan.sh):
#   Re-run `security set-key-partition-list` on every ship to authorize codesign
#   for all current signing keys. That command needs the login password once.
#   This script stores it in the keychain so ship-lan.sh can read it silently
#   (only /usr/bin/security is granted access to the item), no plaintext on disk.
#
# Run this ONCE (re-run any time to update the stored password):
#   bash mobile/ota/setup-signing-noprompt.sh

set -euo pipefail

ACCOUNT="${USER}"
SERVICE="dexter-signing-login-pw"
LOGIN_KC="${HOME}/Library/Keychains/login.keychain-db"

echo "This stores your macOS *login* password in the login keychain as an item"
echo "named '${SERVICE}', readable only by /usr/bin/security. ship-lan.sh uses it"
echo "to authorize codesign silently so you stop getting the password prompt."
echo ""

# -w with no value prompts interactively (hidden) for the password to store, so
# it never appears in argv / process list / this file. -U updates if it exists.
# -T grants /usr/bin/security access to the item's ACL.
security add-generic-password \
    -U \
    -a "${ACCOUNT}" \
    -s "${SERVICE}" \
    -T /usr/bin/security \
    -w

echo ""
echo "-> stored. verifying silent read..."
STORED_PW="$(security find-generic-password -a "${ACCOUNT}" -s "${SERVICE}" -w 2>/dev/null || true)"
if [ -z "${STORED_PW}" ]; then
    echo "!! could not read the item back. If macOS showed a prompt, click 'Always Allow'."
    exit 1
fi

echo "-> verifying it unlocks codesign (set-key-partition-list)..."
if security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "${STORED_PW}" \
        "${LOGIN_KC}" >/dev/null 2>&1; then
    echo "-> OK. codesign is authorized. Future ships should not prompt."
else
    echo "!! set-key-partition-list failed — the stored password may be wrong."
    echo "   Re-run this script and re-enter your login password."
    exit 1
fi
unset STORED_PW
