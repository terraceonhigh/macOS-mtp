# Testing macOS-mtp

## Automated Integration Tests

### Bridge test suite (`test.sh`)

Tests the Go WebDAV bridge against a real device. Requires a phone
connected in File Transfer mode.

```bash
./test.sh
```

Tests:
1. Root directory listing
2. Subdirectory listing
3. File download (round-trip: upload → download → verify)
4. File upload
5. Verify uploaded file exists
6. Create folder
7. Delete file (+ verify gone)
8. Delete folder (+ verify gone)

### Swift app diagnostic (`test-swift.sh`)

Tests IOKit USB device detection. Launches the app binary directly and
monitors for attach/detach events.

```bash
./test-swift.sh
```

Prompts you to unplug and replug the phone while monitoring output for
30 seconds.

## Manual Testing

### Bridge standalone

```bash
make dev
# Note the PORT=XXXXX line

# In another terminal:
mkdir -p /tmp/mtp-test
mount_webdav -s -S http://127.0.0.1:PORT/ /tmp/mtp-test

# Test operations
ls "/tmp/mtp-test/Internal shared storage/"
cp /tmp/some-file.txt "/tmp/mtp-test/Internal shared storage/"
cp "/tmp/mtp-test/Internal shared storage/some-file.txt" /tmp/roundtrip.txt
diff /tmp/some-file.txt /tmp/roundtrip.txt

# Cleanup
umount /tmp/mtp-test
```

### Full app

```bash
make run
# App appears in menu bar
# Plug phone, select File Transfer
# Wait ~15-30s for mount
# Browse phone in Finder
# Click "Eject" in menu bar menu or unplug phone
```

### WebDAV debugging with curl

```bash
# Check server is responding
curl -v -X OPTIONS http://127.0.0.1:PORT/

# List root
curl -X PROPFIND -H "Depth: 1" http://127.0.0.1:PORT/

# Stat a file
curl -X PROPFIND -H "Depth: 0" http://127.0.0.1:PORT/Internal%20shared%20storage/

# Download a file
curl -o /tmp/test http://127.0.0.1:PORT/Internal%20shared%20storage/some-file.txt
```

## Reset Procedure

When things go wrong (bridge hangs, stale mount, USB session locked):

```bash
# Kill everything
killall macOS-mtp bridge 2>/dev/null
umount -f /Volumes/127.0.0.1 2>/dev/null

# If USB session is locked:
# 1. Unplug phone
# 2. Wait 3 seconds
# 3. Replug phone
# 4. Select File Transfer
```

## Common Failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| `mtp-detect` sees nothing | Cable is charge-only, or File Transfer not selected | Try different cable; check `system_profiler SPUSBDataType` |
| Bridge prints "no MTP device found" | File Transfer not selected, or PTPCamera claimed interface | Select File Transfer; the app kills PTPCamera automatically |
| Bridge hangs at "Detecting MTP device" | Previous session still locked | Unplug/replug phone |
| Mount shows empty directory | PROPFIND response malformed | Check with `curl -X PROPFIND` |
| Files copy but are empty on phone | Write path returns read-only file handle | Ensure O_WRONLY/O_TRUNC triggers mtpNewFile |
| `libusb_claim_interface() = -3` | PTPCamera or another process holds USB | Kill PTPCamera; check `ps aux \| grep PTP` |
