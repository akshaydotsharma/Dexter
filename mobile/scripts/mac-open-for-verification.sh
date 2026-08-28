#!/bin/bash
#
# mac-open-for-verification.sh — put a freshly built DexterMac in front of the
# user, on their real store, already on the section that changed.
#
# The macOS equivalent of `ota/ship-lan.sh` + `devicectl install` for iOS: the
# last mile of a macOS change, so verification is "look at the window" instead of
# "here are some commands to run".
#
# Why this exists (#376): a macOS change built and screenshotted from a worktree
# looks fine to the agent while the user's own Mac app shows the OLD behaviour,
# because their app was launched from a DIFFERENT worktree's DerivedData. Handing
# them a path to `open` puts the work on them and reads as "it doesn't work".
#
# Usage:
#   bash mobile/scripts/mac-open-for-verification.sh [section] [expected-window-title]
#
#   section  lowercase AppSection raw value passed as LAUNCH_SECTION
#            (chat today tasks notes lists itineraries wallet finance
#             vocabulary activity settings — NOT helpCenter, see project memory)
#            default: tasks
#
# What it does:
#   1. Builds the DexterMac scheme from THIS worktree.
#   2. Gracefully quits any running DexterMac, pid-scoped (never `pkill -x`,
#      which would kill a teammate's or another agent's instance).
#   3. Launches this worktree's build with LAUNCH_SECTION so it lands on the
#      surface under review — no synthetic clicks needed.
#   4. Raises it, asserts the window belongs to OUR pid and carries the expected
#      title, and screenshots it as proof of what is on screen.
#
# Caveat: quitting discards the running app's in-memory state, and Chat turns are
# NOT persisted. Don't run this while the user is mid-conversation in Chat
# without saying so first.
set -euo pipefail

SECTION="${1:-tasks}"
EXPECT_TITLE="${2:-}"
MOBILE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${TMPDIR:-/tmp}/dexter-mac-verify"
mkdir -p "$OUT_DIR"

# Default the expected title to the section, capitalised — matches
# `navigationTitle`, which drives the macOS window title.
#
# Two sections' titles are not their capitalised raw value, so they need naming
# here. `AppSection.visionBoard` spells its raw value `visionboard` so
# `LAUNCH_SECTION` can reach it, but its `displayName` — and therefore its window
# title — is "Vision Board". `AppSection.itineraries` displays as "Trips", which
# capitalising the raw value can never produce either. Without these the script
# navigates correctly and then fails its own assertion, which is worse than no
# assertion: it reports a working surface as broken.
#
# `trips` is accepted as an alias for the same reason: it is what the sidebar
# says, so it is what anyone reaching for this script will type.
case "$SECTION" in
    trips) SECTION="itineraries"; TITLE_DEFAULT="Trips" ;;
    itineraries) TITLE_DEFAULT="Trips" ;;
    visionboard) TITLE_DEFAULT="Vision Board" ;;
    *) TITLE_DEFAULT="$(echo "$SECTION" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')" ;;
esac
if [ -z "$EXPECT_TITLE" ]; then
    EXPECT_TITLE="$TITLE_DEFAULT"
fi

echo "==> generating project"
(cd "$MOBILE_DIR" && xcodegen generate >/dev/null)

echo "==> building DexterMac (this worktree)"
BUILD_LOG="$OUT_DIR/build.log"
(cd "$MOBILE_DIR" && xcodebuild -project PersonalDashboard.xcodeproj -scheme DexterMac \
    -destination 'platform=macOS' -configuration Debug build >"$BUILD_LOG" 2>&1) || {
    echo "FAIL: build failed. Last 30 lines:"; tail -30 "$BUILD_LOG"; exit 1
}

# Ask the build system where the product actually is rather than guessing the
# DerivedData hash — that hash is per-worktree and is the whole trap this script
# exists to close.
BUILD_DIR="$(cd "$MOBILE_DIR" && xcodebuild -project PersonalDashboard.xcodeproj -scheme DexterMac \
    -destination 'platform=macOS' -configuration Debug -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ TARGET_BUILD_DIR =/ {print $2; exit}')"
APP="$BUILD_DIR/DexterMac.app"
BIN="$APP/Contents/MacOS/DexterMac"
[ -x "$BIN" ] || { echo "FAIL: no binary at $BIN"; exit 1; }
echo "==> built: $APP"

# --- schema pre-flight, BEFORE anything is quit or launched (#449) ---
#
# Every build from every worktree opens the same store file, and a build whose
# schema lacks an entity the store holds DROPS that entity and every row in it,
# reporting nothing but a CoreData line that reads like housekeeping. This
# script is how that happened on 2026-08-07: it quit the running instance and
# launched a build that did not know `LocalVisionBlock`.
#
# So the question is asked first, by the binary itself, in a mode that opens no
# container and writes nothing. Ordering is the whole point — a check that ran
# after the quit would still have destroyed the data it was meant to protect.
echo "==> schema pre-flight"
if ! CHECK="$(DEXTER_SCHEMA_CHECK=1 "$BIN" 2>&1)"; then
    echo "$CHECK"
    echo
    echo "FAIL: this build would DESTROY data in the shared store. Nothing was quit or launched."
    echo "      Run the branch that has those models, merge it first, or point this build at a"
    echo "      copy: DEXTER_STORE_PATH=/tmp/dexter-qa.sqlite (copy the .sqlite, -wal and -shm)."
    exit 1
fi
echo "    $CHECK"

# Window probe, used both to assert identity after launch and to decide how hard
# we are allowed to push on a stubborn instance below.
#
# System Events / Accessibility is not reliably granted to a shell here, so use
# the CG window list, which honours the owner pid. On-screen first, then the full
# list: a window that has not been raised yet (or sits on another Space) is
# invisible to .optionOnScreenOnly and reads as "the app never opened a window".
cat > "$OUT_DIR/winid.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments[1])!
func list(_ o: CGWindowListOption) -> [[String: Any]] {
    ((CGWindowListCopyWindowInfo([o, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
}
var wins = list(.optionOnScreenOnly)
if wins.isEmpty { wins = list(.optionAll) }
for w in wins {
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let width = b["Width"] as? Double, let height = b["Height"] as? Double,
          width >= 200, height >= 200,                      // skip shadow/tooltip helpers
          let id = w[kCGWindowNumber as String] as? Int else { continue }
    print("\(id)\t\(Int(width))x\(Int(height))\t\((w[kCGWindowName as String] as? String) ?? "")")
}
SWIFT

# --- quit any running instance, by pid ---
#
# Escalation policy, and the window count is what licenses it. A polite
# `terminate()` goes first always, because it is the only path that runs the
# app's own quit handling. If it is ignored, WHY decides what happens next:
#
#   * still has windows -> stop. That is a modal or a sheet with the user's
#     unsaved text in it, and no screenshot is worth discarding that.
#   * no windows at all -> it cannot be showing the user anything and has no
#     interactive state to lose, so escalate SIGTERM then SIGKILL.
#
# The second case is not hypothetical: it is where a leftover instance lands
# after its worktree is cleaned up while it runs, and on this script's first real
# use (2026-07-28) such an orphan ignored `terminate()` for 20s and blocked the
# whole handoff, which is the one thing this script exists to prevent.
quit_instance() {
    local pid="$1"
    local where windows
    where="$(ps -o command= -p "$pid" | grep -o 'DerivedData/[^/]*' | head -1 || true)"
    echo "==> quitting running instance pid=$pid ${where:+($where)}"
    /usr/bin/swift - "$pid" <<'SWIFT' 2>/dev/null || true
import AppKit
NSRunningApplication(processIdentifier: Int32(CommandLine.arguments[1])!)?.terminate()
SWIFT
    for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done

    windows="$(swift "$OUT_DIR/winid.swift" "$pid" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$windows" != "0" ]; then
        echo "    pid=$pid ignored the quit and still has $windows window(s) — modal or unsaved sheet. Leaving it alone."
        return 1
    fi
    echo "    pid=$pid ignored the quit and has no windows (orphan — e.g. its worktree was removed). Escalating."
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 5); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
    for _ in $(seq 1 5); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
    return 1
}

blocked=0
for pid in $(pgrep -x DexterMac || true); do
    quit_instance "$pid" || blocked=1
done
if [ "$blocked" != "0" ] || pgrep -x DexterMac >/dev/null; then
    echo "FAIL: a running instance would not quit. Left it alone — close its sheet/modal by hand, then re-run."
    exit 1
fi

# --- launch this worktree's build on the real store ---
LAUNCH_SECTION="$SECTION" nohup "$BIN" >"$OUT_DIR/app.log" 2>&1 &
PID=$!
disown 2>/dev/null || true
echo "==> launched pid=$PID section=$SECTION"

# --- identity assertion + capture ---
WIN=""
for _ in $(seq 1 30); do
    sleep 1
    WIN="$(swift "$OUT_DIR/winid.swift" "$PID" 2>/dev/null | head -1 || true)"
    [ -n "$WIN" ] && break
done
[ -n "$WIN" ] || { echo "FAIL: no window for pid $PID"; exit 1; }

TITLE="$(echo "$WIN" | cut -f3)"
if [ "$TITLE" != "$EXPECT_TITLE" ]; then
    echo "FAIL: window title '$TITLE' != expected '$EXPECT_TITLE' — refusing to claim the right surface is open"
    exit 1
fi
echo "==> window: $WIN"

# Raise it, so the user is actually looking at it.
/usr/bin/swift - "$PID" <<'SWIFT' >/dev/null 2>&1 || true
import AppKit
NSRunningApplication(processIdentifier: Int32(CommandLine.arguments[1])!)?
    .activate(options: [.activateAllWindows])
SWIFT
sleep 2

SHOT="$OUT_DIR/$SECTION.png"
screencapture -x -o -l "$(echo "$WIN" | cut -f1)" "$SHOT"
echo "==> screenshot: $SHOT"
echo "==> DexterMac is open on '$TITLE' from this worktree's build (pid $PID). Ready to verify."
