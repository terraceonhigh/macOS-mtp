#!/bin/bash
set -euo pipefail

# Test the Swift menu bar app's IOKit device watching
# Writes diagnostic output to help debug USB event detection

APP_PATH="/Users/terrace/Library/Developer/Xcode/DerivedData/AndroidFS-bbyhmnynyabnsgdtvugojqojheus/Build/Products/Debug/AndroidFS.app"
LOG_FILE="/tmp/androidfs-test.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "========================================"
echo " AndroidFS Swift App Diagnostic"
echo "========================================"
echo ""

# 1. Check app exists
if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}App not found at $APP_PATH${NC}"
    echo "Run: xcodebuild -project MenuBarApp/AndroidFS.xcodeproj -scheme AndroidFS -configuration Debug build"
    exit 1
fi
echo -e "${GREEN}App found${NC}"

# 2. Kill any existing instance
killall AndroidFS 2>/dev/null && echo "Killed existing instance" && sleep 1 || true

# 3. Check if phone is connected
echo ""
echo "--- USB device check ---"
system_profiler SPUSBDataType 2>/dev/null | grep -A 3 -i "pixel\|android\|samsung\|google\|nexus\|18d1\|Vendor ID: 0x18d1" || echo "No known Android device found in system_profiler"

# 4. Launch app and capture ALL output
echo ""
echo "--- Launching app ---"
rm -f "$LOG_FILE"

# Launch the binary directly (not via open) to capture stdout/stderr
"$APP_PATH/Contents/MacOS/AndroidFS" > "$LOG_FILE" 2>&1 &
APP_PID=$!
echo "Launched AndroidFS (PID $APP_PID)"

# Give it a moment to start
sleep 3

# 5. Check if still running
if kill -0 "$APP_PID" 2>/dev/null; then
    echo -e "${GREEN}App is running${NC}"
else
    echo -e "${RED}App crashed on startup${NC}"
    echo "Output:"
    cat "$LOG_FILE"
    exit 1
fi

# 6. Show any startup output
echo ""
echo "--- App startup output ---"
if [ -s "$LOG_FILE" ]; then
    cat "$LOG_FILE"
else
    echo "(no output captured)"
fi

# 7. Wait for user to plug/unplug
echo ""
echo -e "${YELLOW}ACTION: Unplug the phone, wait 3 seconds, then plug it back in.${NC}"
echo "Watching for 30 seconds..."
echo ""

# Monitor the log file for changes
INITIAL_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
for i in $(seq 1 30); do
    CURRENT_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$CURRENT_SIZE" -gt "$INITIAL_SIZE" ]; then
        echo ""
        echo "--- New output detected ---"
        tail -c +$((INITIAL_SIZE + 1)) "$LOG_FILE"
        INITIAL_SIZE=$CURRENT_SIZE
    fi
    printf "\r  Waiting... %d/30s" "$i"
    sleep 1
done

echo ""
echo ""
echo "--- Final app output ---"
cat "$LOG_FILE"

# 8. Also check log stream separately
echo ""
echo "--- System log entries (last 60s) ---"
log show --process AndroidFS --last 60s 2>/dev/null | grep -i "android\|vendor\|usb\|device\|attach\|loaded\|register" || echo "(no matching log entries)"

# Cleanup
echo ""
echo "--- Cleanup ---"
kill "$APP_PID" 2>/dev/null && echo "Killed AndroidFS" || echo "Already exited"
