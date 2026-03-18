#!/bin/bash
set -euo pipefail

# AndroidFS Bridge Integration Test
# Requires: Android phone connected via USB in File Transfer mode

MOUNT_POINT="/tmp/mtp-test"
BRIDGE_PID=""
PORT=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}  PASS${NC}: $1"; }
fail() { echo -e "${RED}  FAIL${NC}: $1"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${YELLOW}=>>${NC} $1"; }
prompt() {
    echo ""
    echo -e "${YELLOW}ACTION REQUIRED:${NC} $1"
    read -rp "Press Enter when ready (or Ctrl-C to abort)..."
    echo ""
}

cleanup() {
    info "Cleaning up..."
    umount -f "$MOUNT_POINT" 2>/dev/null || true
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
    rm -f /tmp/test-upload.txt /tmp/phone-download-test
}
trap cleanup EXIT

FAILURES=0
TESTS=0

run_test() {
    TESTS=$((TESTS + 1))
    local name="$1"
    shift
    if "$@" 2>/dev/null; then
        pass "$name"
    else
        fail "$name"
    fi
}

# ============================================================
echo "========================================"
echo " AndroidFS Bridge Integration Tests"
echo "========================================"
echo ""

# --- Preflight ---
info "Checking build..."
make bridge 2>&1 | tail -1
echo ""

# --- Ensure clean state ---
umount -f "$MOUNT_POINT" 2>/dev/null || true
kill "$(pgrep -f 'build/bridge')" 2>/dev/null || true
sleep 1

prompt "Connect Android phone via USB and select 'File Transfer' mode.
       Verify with: mtp-detect | head -10"

# --- Start bridge ---
info "Starting bridge..."
mkdir -p "$MOUNT_POINT"
rm -f /tmp/bridge-stdout.log /tmp/bridge-stderr.log
./build/bridge > /tmp/bridge-stdout.log 2>/tmp/bridge-stderr.log &
BRIDGE_PID=$!

# Wait for PORT= line in stdout
PORT=""
for i in $(seq 1 30); do
    if grep -q '^PORT=' /tmp/bridge-stdout.log 2>/dev/null; then
        PORT=$(grep -m1 '^PORT=' /tmp/bridge-stdout.log | cut -d= -f2)
        break
    fi
    # Check bridge hasn't died
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
        echo -e "${RED}ERROR${NC}: Bridge exited early."
        echo "Bridge stderr:"
        cat /tmp/bridge-stderr.log
        exit 1
    fi
    sleep 1
done

if [ -z "$PORT" ]; then
    echo -e "${RED}ERROR${NC}: Bridge did not output PORT= within 30 seconds."
    echo "Bridge stderr:"
    cat /tmp/bridge-stderr.log
    exit 1
fi

info "Bridge running on port $PORT (PID $BRIDGE_PID)"

# --- Mount ---
info "Mounting WebDAV..."
if ! mount_webdav -s -S "http://127.0.0.1:${PORT}/" "$MOUNT_POINT"; then
    echo -e "${RED}ERROR${NC}: mount_webdav failed"
    echo "Bridge stderr:"
    cat /tmp/bridge-stderr.log
    exit 1
fi
info "Mounted at $MOUNT_POINT"
echo ""

# --- Detect storage name ---
STORAGE=$(ls "$MOUNT_POINT" | head -1)
if [ -z "$STORAGE" ]; then
    echo -e "${RED}ERROR${NC}: No storage found at mount point"
    exit 1
fi
BASE="$MOUNT_POINT/$STORAGE"
info "Using storage: $STORAGE"
echo ""

# ============================================================
echo "--- Test 1: Root directory listing ---"
run_test "Root listing shows storage" test -d "$BASE"

echo ""
echo "--- Test 2: Subdirectory listing ---"
SUBDIR=$(ls "$BASE" 2>/dev/null | head -1)
if [ -n "$SUBDIR" ]; then
    run_test "Subdirectory '$SUBDIR' is accessible" test -e "$BASE/$SUBDIR"
else
    fail "No subdirectories found in storage root"
    FAILURES=$((FAILURES + 1))
fi

echo ""
echo "--- Test 3: File download ---"
# Upload a known file first, then download it back to verify round-trip.
# This avoids 'find' on the WebDAV mount which triggers deep MTP enumeration.
echo "download-test-content-$(date +%s)" > /tmp/test-download-src.txt
DOWNLOAD_OK=false
if cp /tmp/test-download-src.txt "$BASE/test-download-verify.txt" 2>/dev/null; then
    sleep 1
    rm -f /tmp/phone-download-test
    if cp "$BASE/test-download-verify.txt" /tmp/phone-download-test 2>/dev/null; then
        if [ -s /tmp/phone-download-test ]; then
            pass "Download file (round-trip)"
            TESTS=$((TESTS + 1))
            DOWNLOAD_OK=true
        else
            fail "Downloaded file is empty"
        fi
    else
        fail "Download cp failed"
    fi
    # Clean up the test file on device
    rm -f "$BASE/test-download-verify.txt" 2>/dev/null || true
else
    fail "Could not upload test file for download verification"
fi
rm -f /tmp/test-download-src.txt

echo ""
echo "--- Test 4: File upload ---"
echo "hello from androidfs test $(date)" > /tmp/test-upload.txt
if cp /tmp/test-upload.txt "$BASE/test-upload.txt" 2>/dev/null; then
    pass "Upload file"
    TESTS=$((TESTS + 1))
else
    fail "Upload file"
fi

echo ""
echo "--- Test 5: Verify upload ---"
# Give MTP a moment to settle
sleep 1
run_test "Uploaded file exists" test -f "$BASE/test-upload.txt"

echo ""
echo "--- Test 6: Create folder ---"
if mkdir "$BASE/test-folder" 2>/dev/null; then
    pass "Create folder"
    TESTS=$((TESTS + 1))
else
    fail "Create folder"
fi

echo ""
echo "--- Test 7: Delete file ---"
if rm "$BASE/test-upload.txt" 2>/dev/null; then
    pass "Delete file"
    TESTS=$((TESTS + 1))
    sleep 1
    if [ ! -f "$BASE/test-upload.txt" ]; then
        pass "File confirmed gone"
        TESTS=$((TESTS + 1))
    else
        fail "File still exists after delete"
    fi
else
    fail "Delete file"
fi

echo ""
echo "--- Test 8: Delete folder ---"
if rmdir "$BASE/test-folder" 2>/dev/null; then
    pass "Delete folder"
    TESTS=$((TESTS + 1))
    sleep 1
    if [ ! -d "$BASE/test-folder" ]; then
        pass "Folder confirmed gone"
        TESTS=$((TESTS + 1))
    else
        fail "Folder still exists after delete"
    fi
else
    fail "Delete folder"
fi

# ============================================================
echo ""
echo "========================================"
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}ALL TESTS PASSED${NC} ($TESTS tests)"
else
    echo -e "${RED}$FAILURES FAILURE(S)${NC} out of $TESTS tests"
    echo ""
    echo "Bridge stderr (last 20 lines):"
    tail -20 /tmp/bridge-stderr.log
fi
echo "========================================"
exit "$FAILURES"
