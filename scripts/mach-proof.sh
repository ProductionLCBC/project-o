#!/bin/sh
# Spec 10 §2 — "Area 19 proves the call on the dev Mac at its first stop for review":
# a Mach service registered with bootstrap_check_in, or the deprecated
# bootstrap_register, under a name launchd has not seen, and looked up "from an app
# that didn't start the engine" (Spec 10 §18).
#
# What it does, with `oengine mach-proof` on each side:
#   1. a helper registers a new name with bootstrap_check_in;
#   2. a child of this shell looks it up and reads the surface the helper sends;
#   3. a throwaway .app, started by LaunchServices so its parent is launchd, does the same;
#   4. a second helper registers another name with bootstrap_register, beside the first;
#   5. the first helper is killed: its name is gone, and the second still answers.
# It opens no screen, output or audio device. Worth running again after a macOS update.
#
# usage: scripts/mach-proof.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
echo "building oengine"
swift build --package-path "$ROOT" --product oengine >/dev/null 2>&1 || { echo "the build failed: run swift build"; exit 1; }
BIN="$ROOT/.build/debug/oengine"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/o-mach-proof.XXXXXX")
FIRST_PID=""
SECOND_PID=""
FAILED=0

cleanup() {
    for pid in $FIRST_PID $SECOND_PID; do
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
    echo "FAILED: $1"
    FAILED=1
}

# Waits up to five seconds for a helper's first line.
registered() {
    tries=0
    while [ "$tries" -lt 50 ]; do
        grep -q "registered" "$1" 2>/dev/null && return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    return 1
}

# A lookup from an app LaunchServices starts: its parent is launchd, not this shell.
from_app() {
    rm -f "$WORK/app.txt"
    # The app is gone in a few milliseconds, sometimes before `open` can wait on it, so the wait is on its file.
    open -n "$WORK/Proof.app" --args mach-proof lookup "$1" "$WORK/app.txt"
    tries=0
    while [ ! -s "$WORK/app.txt" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    if [ -s "$WORK/app.txt" ]; then cat "$WORK/app.txt"; else echo "lookup: the app wrote nothing"; fi
}

mkdir -p "$WORK/Proof.app/Contents/MacOS"
cp "$BIN" "$WORK/Proof.app/Contents/MacOS/oengine-proof"
cat > "$WORK/Proof.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>oengine-proof</string>
    <key>CFBundleIdentifier</key><string>org.lcbc.projecto.machproof</string>
    <key>CFBundleName</key><string>Project O Mach proof</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

FIRST="org.lcbc.projecto.engine.$(uuidgen | tr 'A-Z' 'a-z')"
SECOND="org.lcbc.projecto.engine.$(uuidgen | tr 'A-Z' 'a-z')"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), this shell is pid $$"

echo
echo "1. a helper registers $FIRST"
"$BIN" mach-proof serve "$FIRST" > "$WORK/first.log" 2>&1 &
FIRST_PID=$!
registered "$WORK/first.log" || fail "the first helper did not register"
cat "$WORK/first.log"
grep -q "bootstrap_check_in" "$WORK/first.log" || fail "bootstrap_check_in did not take the name"

echo
echo "2. a child of this shell looks it up"
"$BIN" mach-proof lookup "$FIRST" || fail "the lookup from this shell"

echo
echo "3. an app started by LaunchServices looks it up"
from_app "$FIRST"
grep -q "as sent" "$WORK/app.txt" 2>/dev/null || fail "the lookup from the app"
grep -q "started by pid 1," "$WORK/app.txt" 2>/dev/null || fail "the app was not started by launchd"

echo
echo "4. a second helper registers $SECOND with the deprecated call, beside the first"
"$BIN" mach-proof serve "$SECOND" --register > "$WORK/second.log" 2>&1 &
SECOND_PID=$!
registered "$WORK/second.log" || fail "the second helper did not register"
cat "$WORK/second.log"
grep -q "bootstrap_register" "$WORK/second.log" || fail "bootstrap_register did not take the name"
from_app "$SECOND"
grep -q "as sent" "$WORK/app.txt" 2>/dev/null || fail "the lookup of the second name from the app"
grep -q "served by pid $SECOND_PID," "$WORK/app.txt" 2>/dev/null || fail "the second name did not reach the second helper"
"$BIN" mach-proof lookup "$FIRST" | grep "served by" || fail "the first name stopped answering"

echo
echo "5. the first helper is killed"
kill -9 "$FIRST_PID" 2>/dev/null
wait "$FIRST_PID" 2>/dev/null
FIRST_PID=""
sleep 0.5
if "$BIN" mach-proof lookup "$FIRST"; then fail "the dead helper's name still resolves"; fi
"$BIN" mach-proof lookup "$SECOND" | grep "served by" || fail "the second name stopped answering"

echo
echo "what the helpers saw:"
cat "$WORK/first.log" "$WORK/second.log"

echo
if [ "$FAILED" -eq 0 ]; then
    echo "PROVED: both calls register a name launchd had not seen, and an app that did not start the helper finds it"
else
    echo "NOT PROVED: see the failures above"
fi
exit "$FAILED"
