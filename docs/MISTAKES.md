# Mistakes & Pitfalls

Everything we got wrong building AndroidFS, so you don't have to.

## MTP / libmtp

### 1. `LIBMTP_Get_First_Device` blocks forever

**What happened:** Our first attempt used `LIBMTP_Get_First_Device()` which
is a convenience function. It blocked indefinitely when the USB interface
was claimed by another process.

**Fix:** Switched to the raw detection API:
`LIBMTP_Detect_Raw_Devices()` → `LIBMTP_Open_Raw_Device_Uncached()`.
This gives granular error reporting and doesn't block.

### 2. Wrong root parent ID for enumeration

**What happened:** `LIBMTP_Get_Files_And_Folders(dev, storageID, 0)`
returned zero results. We passed `0` as the parent ID thinking it meant
"root".

**Fix:** The root parent constant is `0xFFFFFFFF`
(`LIBMTP_FILES_AND_FOLDERS_ROOT`), defined in `libmtp.h` line 923.
Parent ID `0` means something else entirely in MTP.

### 3. Wrong root parent ID for object creation

**What happened:** After fixing enumeration to use `0xFFFFFFFF`, we tried
`0` as parent ID for `LIBMTP_Create_Folder` and
`LIBMTP_Send_File_From_Handler`. Got `PTP Invalid Object Handle (2009)`.

**Fix:** Object creation at storage root also needs `0xFFFFFFFF`, not `0`.
We added `resolveParentID()` which converts our internal storage ID
(which equals the storage root's object ID in our map) to `0xFFFFFFFF`.

### 4. Full recursive enumeration is impractical

**What happened:** First attempt walked the entire phone filesystem at
startup. A Pixel 6 with YouTube Music cache and photo thumbnails had
thousands of entries. Startup took over 5 minutes and hadn't finished.

**Fix:** Lazy enumeration. Only fetch directory contents when Finder
actually browses into them via PROPFIND. Startup drops to under 1 second.

### 5. `GetFolderList` doesn't work with uncached devices

**What happened:** `LIBMTP_Get_Folder_List_For_Storage` returned NULL
for devices opened with `LIBMTP_Open_Raw_Device_Uncached`.

**Fix:** Dropped the folder tree API entirely. Use
`LIBMTP_Get_Files_And_Folders` with `LIBMTP_FILES_AND_FOLDERS_ROOT`
recursively instead — it works with both cached and uncached devices.

### 6. `LIBMTP_destroy_file_t` frees the filename

**What happened:** We allocated a C string for the filename with
`C.CString()`, assigned it to `fi.filename`, then called both
`C.free(cname)` and `LIBMTP_destroy_file_t(fi)` via defers. Double-free
caused a SIGTRAP crash.

**Fix:** Let `LIBMTP_destroy_file_t` own the string. Don't free it
separately:
```go
// BAD
cname := C.CString(name)
defer C.free(unsafe.Pointer(cname))  // double-free!
fi.filename = cname
defer C.LIBMTP_destroy_file_t(fi)

// GOOD
fi.filename = C.CString(name)
defer C.LIBMTP_destroy_file_t(fi)  // frees fi.filename
```

## cgo Callbacks

### 7. Wrong callback signature — 3 params instead of 5

**What happened:** We wrote `goGetFileCallback(buf, size, data)` with 3
parameters. The actual `MTPDataPutFunc` signature has 5:
`(void* params, void* priv, uint32_t sendlen, unsigned char *data, uint32_t *putlen)`.
The bridge would hang on any file download because the stack was corrupted.

**Fix:** Read `libmtp.h` carefully. The typedefs are at lines 498 and 513.
Match the exact signature including the `params` pointer (unused but
present) and the output length pointer.

### 8. `io.EOF` treated as error in upload callback

**What happened:** When uploading a file, the `goDataGetFunc` callback
returned `LIBMTP_HANDLER_RETURN_ERROR` when `io.Reader.Read()` returned
`(0, io.EOF)`. This caused `LIBMTP_Send_File_From_Handler` to abort
with `PTP I/O Error`.

**Fix:** `io.EOF` is normal end-of-data, not an error:
```go
// BAD
if err != nil && n == 0 {
    return C.LIBMTP_HANDLER_RETURN_ERROR
}

// GOOD
if err != nil && err != io.EOF && n == 0 {
    return C.LIBMTP_HANDLER_RETURN_ERROR
}
```

## WebDAV / Finder

### 9. `Seek` always returned `(0, nil)`

**What happened:** Our `mtpFile.Seek()` fetched the file into a
`bytes.Buffer` but always returned `(0, nil)`. The WebDAV handler calls
`Seek(0, SeekEnd)` to determine file size before serving — getting `0`
back meant every file appeared empty.

**Fix:** Replaced `bytes.Buffer` with `bytes.Reader`, which implements
`io.ReadSeeker` properly.

### 10. Existing files can't be overwritten

**What happened:** When Finder drags a file to the phone, the WebDAV
handler first creates a 0-byte file (PUT with O_CREATE), then tries to
write content. On the second PUT, the file already exists in our cache,
so `OpenFile` returns a read-only `mtpFile` instead of a writable
`mtpNewFile`. Content goes nowhere.

**Fix:** When `O_WRONLY`, `O_RDWR`, `O_CREATE`, or `O_TRUNC` flags are
set, always return `mtpNewFile`. If the file already exists, delete it
first then create a fresh writable file.

### 11. Cache not invalidated after mutations

**What happened:** After uploading a file, the parent directory's
"populated" flag wasn't reset. A subsequent PROPFIND returned the stale
cached listing without the new file.

**Fix:** Call `ObjectMap.InvalidateDir(parent)` after every mutation:
Mkdir, RemoveAll, Rename, and mtpNewFile.Close.

## macOS / IOKit

### 12. `IOUSBDevice` vs `IOUSBHostDevice`

**What happened:** Used `kIOUSBDeviceClassName` (`"IOUSBDevice"`) for IOKit
matching. No devices were ever matched. No error — just silence.

**Fix:** macOS 13+ uses `IOUSBHostDevice`. Check with:
```bash
ioreg -p IOUSB -l | grep "class"
```
Use `IOServiceMatching("IOUSBHostDevice")` instead.

### 13. `kUSBVendorID` vs `"idVendor"`

**What happened:** Used the legacy `kUSBVendorID` constant for IOKit
property matching and lookup. Didn't match anything.

**Fix:** Modern IOKit uses `"idVendor"` and `"idProduct"` as property
keys. Same for `IORegistryEntryCreateCFProperty`.

### 14. NSApplication.delegate is weak

**What happened:** Created `AppDelegate()` as a local variable in the
`@main` struct's `main()` function. Assigned it to
`NSApplication.shared.delegate` (which is weak). The delegate was
immediately deallocated by ARC. No lifecycle methods ever fired.

**Fix:** Use a separate `main.swift` file:
```swift
let delegate = AppDelegate()  // strong reference
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
```

### 15. NSLog not visible in `log stream`

**What happened:** Ran the app via `open Foo.app` and watched
`log stream --process AndroidFS`. Our NSLog messages didn't appear.
System framework messages appeared, but not ours.

**Fix:** Launch the binary directly
(`Foo.app/Contents/MacOS/Foo > log.txt 2>&1`) to capture NSLog output.
The `log stream` tool has filtering quirks with NSLog from unsigned apps.

### 16. Per-vendor IOKit matching dict + ARC = silent failure

**What happened:** Registered separate IOKit matching notifications for
each of 15 vendor IDs. Each required a matching dictionary. The
`mutableCopy()` + Swift ARC + IOKit's CFDictionary consumption semantics
interacted badly — notifications silently failed to register.

**Fix:** Register ONE notification for ALL `IOUSBHostDevice` connections,
then filter by vendor ID in the callback. Simpler and avoids the ARC
memory management issue.

## USB / Process Management

### 17. PTPCamera claims the USB interface

**What happened:** macOS's `PTPCamera` process auto-launches and claims
the MTP/PTP USB interface before our bridge can.
`libusb_claim_interface()` returns `-3` (`LIBUSB_ERROR_ACCESS`).

**Fix:** Kill `PTPCamera` and `AMPDevicesAgent` before starting the bridge:
```swift
Process("/usr/bin/killall", ["-9", "PTPCamera"])
```

### 18. SIP strips DYLD_LIBRARY_PATH

**What happened:** The bridge binary links `libmtp.9.dylib` from
`/opt/homebrew/opt/libmtp/lib/`. Set `DYLD_LIBRARY_PATH` on the spawned
process. Binary still couldn't find the library — macOS SIP strips all
`DYLD_*` environment variables from child processes.

**Fix:** Bundle `libmtp.9.dylib` (and `libusb-1.0.0.dylib`) in the app's
`Frameworks/` directory. Use `install_name_tool -change` to rewrite the
load path to `@executable_path/../Frameworks/`.

### 19. USB re-enumeration storm on MTP mode switch

**What happened:** When an Android phone switches to File Transfer (MTP)
mode, the USB interface re-enumerates — causing 3-4 rapid detach/attach
IOKit events within seconds. Our detach handler killed the bridge
mid-startup every time.

**Fix:** Added `isConnecting` flag that locks out all attach/detach
handling during connection. Initial 5-second delay before first bridge
attempt. Retry logic with increasing delays. The phone needs time to
settle into MTP mode.

### 20. `mount_webdav` silently fails with custom mount point

**What happened:** Tried calling `/sbin/mount_webdav` directly to control
the volume name (mount at `/Volumes/Pixel 6` instead of
`/Volumes/127.0.0.1`). Exit code 2, no error message, regardless of
whether the directory existed or not.

**Fix:** Reverted to `NetFSMountURLSync` which works reliably. The volume
name issue (`127.0.0.1` in Finder sidebar) remains an open TODO.
`kNetFSMountAtMountDirKey` also returns error 2. The volume name appears
to be derived from the server hostname and cannot be easily overridden
through the mount API.

## Build System

### 21. Go's `vendor/` directory conflict

**What happened:** Put the libmtp C header in `bridge/vendor/libmtp.h`.
Go's module system interpreted `vendor/` as a Go vendor directory and
complained about inconsistent vendoring.

**Fix:** Renamed to `bridge/cvendor/`.

### 22. Charge-only USB cables

**What happened:** `mtp-detect` returned no devices, phone showed File
Transfer mode selected. `system_profiler SPUSBDataType` showed no phone
at all.

**Fix:** The USB-C cable had no data lines (charge-only). A different cable
fixed it instantly. Always check `system_profiler SPUSBDataType` first —
if the device doesn't appear there, it's a cable/port issue, not software.

### 23. Xcode not selected / not initialized

**What happened:** `xcodebuild` failed with three separate errors on a
fresh machine:
1. "active developer directory is a command line tools instance"
2. "You have not agreed to the Xcode license"
3. "A required plugin failed to load" (CoreSimulator missing)

**Fix:** Three commands, in order:
```bash
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```
