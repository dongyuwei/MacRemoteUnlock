#!/bin/bash
# Start MacRemoteUnlock (Debug build from DerivedData)
#
# IMPORTANT: run from this path, NOT /Applications.
# Accessibility (TCC) permission for this ad-hoc-signed build is bound to the
# original path. Launching from a different path loses the permission and
# unlock silently fails.
#
# Usage:
#   ./start.sh          # start (kills any existing instance first)
#   ./start.sh --build  # rebuild via xcodebuild, then start

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

# Find the most recent Debug build
APP=$(ls -dt "$HOME/Library/Developer/Xcode/DerivedData"/MacRemoteUnlock-*/Build/Products/Debug/MacRemoteUnlock.app 2>/dev/null | head -1 || true)
LOG="$HOME/Library/Logs/MacRemoteUnlock/macremoteunlock.log"

if [ "$1" = "--build" ]; then
    echo "Building MacRemoteUnlock..."
    xcodebuild -project "$DIR/MacRemoteUnlock.xcodeproj" \
               -scheme MacRemoteUnlock -configuration Debug build 2>/dev/null | tail -3
    APP=$(ls -dt "$HOME/Library/Developer/Xcode/DerivedData"/MacRemoteUnlock-*/Build/Products/Debug/MacRemoteUnlock.app 2>/dev/null | head -1 || true)
fi

if [ -z "$APP" ] || [ ! -x "$APP/Contents/MacOS/MacRemoteUnlock" ]; then
    echo "ERROR: MacRemoteUnlock binary not found."
    echo "Build it first with:  ./start.sh --build"
    exit 1
fi

# Kill any existing instance (including one running from /Applications)
pkill -f "MacRemoteUnlock.app/Contents/MacOS/MacRemoteUnlock" 2>/dev/null || true
sleep 1

mkdir -p "$(dirname "$LOG")"
nohup "$APP/Contents/MacOS/MacRemoteUnlock" > "$LOG" 2>&1 &
echo "MacRemoteUnlock started from: $APP"
echo "PID: $!"
echo "Log: $LOG"

# Wait for the HTTP server (first launch may take a few seconds due to TCC checks)
for i in $(seq 1 10); do
    if lsof -nP -iTCP:8123 -sTCP:LISTEN | grep -q "MacRemote"; then
        echo "Remote Unlock server: listening on port 8123"
        break
    fi
    sleep 1
    if [ "$i" = "10" ]; then
        echo "WARNING: port 8123 not listening after 10s. Check log: $LOG"
    fi
 done
