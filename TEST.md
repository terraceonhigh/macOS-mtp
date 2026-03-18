# AndroidFS Bridge Test Sequence

## Prerequisites

- Android phone connected via USB with **File Transfer** mode selected
- `mtp-detect` shows the device
- No other MTP clients running (close Android File Transfer, etc.)

## Setup

```bash
cd ~/Labs/macOS-mtp

# Build
make bridge

# Start bridge (note the PORT=XXXXX in output)
make dev &

# Mount (replace PORT with actual port number)
mkdir -p /tmp/mtp-test
mount_webdav -s -S http://127.0.0.1:PORT/ /tmp/mtp-test
```

## Tests

### 1. Directory listing (PROPFIND)

```bash
ls "/tmp/mtp-test/Internal shared storage/"
```

Expected: list of top-level folders (Pictures, Android, DCIM, etc.)

### 2. Subdirectory listing

```bash
ls "/tmp/mtp-test/Internal shared storage/Alarms/"
```

Expected: contents of Alarms folder

### 3. File download (GET)

```bash
# Pick any small file visible in a listing
cp "/tmp/mtp-test/Internal shared storage/Alarms/"* /tmp/phone-download-test 2>&1
ls -la /tmp/phone-download-test
```

Expected: file copied without error, size > 0

### 4. File upload (PUT)

```bash
echo "hello from mac" > /tmp/test-upload.txt
cp /tmp/test-upload.txt "/tmp/mtp-test/Internal shared storage/test-upload.txt"
```

Expected: no error

### 5. Verify upload

```bash
ls -la "/tmp/mtp-test/Internal shared storage/test-upload.txt"
```

Expected: file visible with correct size (15 bytes)

### 6. Create folder (MKCOL)

```bash
mkdir "/tmp/mtp-test/Internal shared storage/test-folder"
ls -d "/tmp/mtp-test/Internal shared storage/test-folder"
```

Expected: directory created

### 7. Delete file (DELETE)

```bash
rm "/tmp/mtp-test/Internal shared storage/test-upload.txt"
ls "/tmp/mtp-test/Internal shared storage/test-upload.txt" 2>&1
```

Expected: file gone, ls reports "No such file or directory"

### 8. Delete folder (DELETE)

```bash
rmdir "/tmp/mtp-test/Internal shared storage/test-folder"
ls -d "/tmp/mtp-test/Internal shared storage/test-folder" 2>&1
```

Expected: folder gone

## Teardown

```bash
umount /tmp/mtp-test
kill $(pgrep -f "build/bridge")
```

## Reset (if bridge hangs or crashes)

1. `kill $(pgrep -f "build/bridge")`
2. `umount -f /tmp/mtp-test 2>/dev/null`
3. Unplug phone
4. Replug phone, select File Transfer
5. Restart from Setup
