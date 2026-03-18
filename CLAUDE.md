# CLAUDE.md — AndroidFS for macOS

> Read this document in full before writing any code, creating any files, or
> making any architectural decisions. Every section exists because a
> wrong turn in that area is expensive.

---

## Project Overview

**AndroidFS** is a macOS menu bar application that makes an Android phone
appear as a mounted volume in Finder when connected via USB — without
requiring Android developer mode, USB debugging, or any gesture more
involved than selecting "File Transfer" on the phone's USB notification.

The intended user is non-technical. The interaction model is:

1. Plug in phone
2. Pull down notification shade → tap **File Transfer**
3. Phone appears in Finder sidebar

Nothing else. No settings archaeology. No pairing ceremony beyond step 2.

This repository is a fork of OpenMTP. The Electron frontend and existing
Node.js MTP bindings are **reference material only**. This application is a
clean reimplementation with a different architecture. Do not attempt to adapt
or reuse the OpenMTP frontend.

---

## Architecture Decision Record

These decisions are final. Do not re-evaluate them unless you hit a hard
technical blocker, and if you do, document it explicitly before changing
course.

### Why not ADB?

ADB requires the user to enable USB Debugging, which requires enabling
Developer Options (Settings → About Phone → tap Build Number seven times).
This is irrecoverable friction for a non-technical user. ADB is not used
anywhere in this project.

### Why not macFUSE?

macFUSE requires a kernel extension. Kernel extensions require either
disabling System Integrity Protection or navigating Gatekeeper approval
flows that change with every macOS release. This is not acceptable for a
consumer application.

### Why not File Provider API?

Apple's File Provider API is designed for cloud storage services with
pull-based, REST-oriented backends. MTP is a stateful, session-locked,
synchronous protocol. Mapping MTP onto File Provider's model is possible
but the sandboxing restrictions make USB device access from a File Provider
extension deeply painful. The impedance mismatch isn't worth fighting.

### Why WebDAV as the Finder integration layer?

macOS Finder mounts WebDAV natively and surfaces it in the sidebar under
Locations. No extensions, no kernel code, no entitlements beyond USB access
for IOKit. A `dav://localhost:PORT` URL mounted via `NetFSMountURLAsync`
is indistinguishable to the user from any other mounted volume. This is the
cleanest available integration surface.

### Why Go for the WebDAV bridge?

- Compiles to a single static binary, trivial to bundle in the app's
  `Resources/` directory
- `golang.org/x/net/webdav` provides a standards-compliant WebDAV server
  that handles most Finder compatibility issues
- `cgo` provides straightforward bindings against `libmtp`'s C API
- Goroutines map cleanly onto the single-threaded MTP serialisation
  requirement (one goroutine owns the MTP session; all others send requests
  via a channel and block on a response channel)

### Why Swift for the menu bar app?

IOKit USB device matching, `DiskArbitration` unmount, `NSNetServiceBrowser`,
`NetFSMountURLAsync`, and SwiftUI menu bar extras are all first-class Swift
APIs. There is no reason to introduce another language for this layer.

---

## Repository Structure

```
.
├── CLAUDE.md                  ← this file
├── Makefile
├── bridge/                    ← Go WebDAV bridge
│   ├── main.go
│   ├── mtp/
│   │   ├── binding.go         ← cgo libmtp bindings
│   │   ├── session.go         ← session lifecycle, object ID map
│   │   └── operations.go      ← MTP operation implementations
│   ├── webdav/
│   │   ├── handler.go         ← golang.org/x/net/webdav FileSystem impl
│   │   └── finder.go          ← Finder-specific WebDAV quirk handling
│   └── vendor/
│       └── libmtp.h           ← copy of /opt/homebrew/include/libmtp.h
├── MenuBarApp/                ← Swift menu bar app (Xcode project)
│   ├── AndroidFS.xcodeproj
│   ├── Sources/
│   │   ├── AppDelegate.swift
│   │   ├── DeviceWatcher.swift   ← IOKit USB monitoring
│   │   ├── BridgeProcess.swift   ← bridge lifecycle management
│   │   └── MountManager.swift    ← WebDAV mount/unmount via NetFS
│   ├── Resources/
│   │   ├── bridge               ← compiled Go binary (copied by make app)
│   │   └── VendorIDs.plist      ← known Android USB vendor IDs
│   └── AndroidFS.entitlements
└── build/
    └── bridge                 ← build output for Go binary
```

---

## Environment Requirements

This project **must** be developed on a physical Mac. There is no
containerised or remote alternative.

### Required tools

```bash
# Verify each of these before starting
xcode-select -p          # must return a path; full Xcode required, not just CLT
go version               # 1.21 or later
brew list libmtp         # must be installed
mtp-detect               # run with phone connected; must show device info
```

If `mtp-detect` does not see the phone, the environment is not ready.
Debug the libmtp installation before writing any code.

### Required hardware

A physical Android device connected via USB with **File Transfer** mode
selected. MTP cannot be meaningfully mocked or simulated.

### libmtp header

Copy the installed header into the vendor directory so cgo can find it
without hardcoding Homebrew paths:

```bash
cp /opt/homebrew/include/libmtp.h bridge/vendor/libmtp.h
```

Reference it in cgo preamble as `#include "../vendor/libmtp.h"`.

---

## Build System

```makefile
# Makefile

BRIDGE_OUT := build/bridge
APP_NAME   := AndroidFS

.PHONY: bridge app dev clean

bridge:
	cd bridge && go build -o ../$(BRIDGE_OUT) .

app: bridge
	xcodebuild -project MenuBarApp/$(APP_NAME).xcodeproj \
	           -scheme $(APP_NAME) \
	           -configuration Release \
	           build
	cp $(BRIDGE_OUT) MenuBarApp/build/Release/$(APP_NAME).app/Contents/Resources/bridge

dev: bridge
	./$(BRIDGE_OUT) 2>&1

clean:
	rm -rf build/
	xcodebuild -project MenuBarApp/$(APP_NAME).xcodeproj clean
```

`make dev` builds the bridge and runs it standalone against the first
detected MTP device, printing the WebDAV URL. Use this to test the bridge
independently of the Swift app:

```
Finder → Go → Connect to Server → dav://localhost:<PORT>
```

---

## Component 1: Go WebDAV Bridge

### Responsibilities

- Open an MTP session with the connected device via libmtp
- Build and maintain an in-memory bidirectional map between fake POSIX
  paths and MTP object handles
- Serve the device filesystem over HTTP WebDAV on a random localhost port
- Print the chosen port to stdout on startup (Swift app reads this)
- Serialise all MTP operations through a single goroutine

### MTP session lifecycle

```go
// Pseudocode — expand into session.go
func runSession(device *LIBMTP_mtpdevice_t, requests <-chan MTPRequest) {
    LIBMTP_Open_Session(device)
    defer LIBMTP_Release_Session(device)
    buildObjectMap(device) // walk all storages, populate path↔handle map
    for req := range requests {
        req.respond(dispatch(device, req))
    }
}
```

All WebDAV handler goroutines send into `requests` and block on the
response channel embedded in each `MTPRequest`. This is the serialisation
boundary. **Never call libmtp functions from any goroutine other than the
session goroutine.** libmtp is not thread-safe.

### Object ID map

MTP exposes a flat object store. We present a POSIX directory tree.
The map must be maintained bidirectionally:

```go
type ObjectMap struct {
    mu      sync.RWMutex
    byPath  map[string]uint32   // "/DCIM/Camera/IMG_001.jpg" → 12345
    byID    map[uint32]string   // 12345 → "/DCIM/Camera/IMG_001.jpg"
    meta    map[uint32]MTPMeta  // cached stat-like metadata
}
```

The map is built by walking all storage folders on session open.
Operations that create or delete objects must update the map synchronously
before returning, within the session goroutine.

### cgo libmtp binding

Key functions needed (all in `binding.go`):

```go
// #cgo LDFLAGS: -lmtp
// #include "../vendor/libmtp.h"
import "C"

func DetectDevice() *C.LIBMTP_mtpdevice_t
func GetStorages(dev *C.LIBMTP_mtpdevice_t) []Storage
func GetFolderList(dev *C.LIBMTP_mtpdevice_t, storageID uint32) *C.LIBMTP_folder_t
func GetFileList(dev *C.LIBMTP_mtpdevice_t, storageID uint32) *C.LIBMTP_file_t
func GetFileToWriter(dev *C.LIBMTP_mtpdevice_t, id uint32, w io.Writer) error
func SendFileFromReader(dev *C.LIBMTP_mtpdevice_t, info FileInfo, r io.Reader) (uint32, error)
func DeleteObject(dev *C.LIBMTP_mtpdevice_t, id uint32) error
func CreateFolder(dev *C.LIBMTP_mtpdevice_t, name string, parentID uint32, storageID uint32) (uint32, error)
```

MTP has no rename operation. `MOVE` in WebDAV terms must be implemented as
a copy followed by delete. This is slow for large files and acceptable for
the initial implementation.

MTP has no partial read. `GET` must either:
- Pull the entire file to a temp file, then serve it; or
- Use `LIBMTP_Get_File_To_Handler` with a callback that writes into the
  HTTP response body

Prefer the handler approach where the libmtp version supports it.
Check at binding time whether `LIBMTP_Get_File_To_Handler` is available.

### WebDAV → MTP operation mapping

| WebDAV verb | MTP operation | Notes |
|-------------|--------------|-------|
| `PROPFIND` | enumerate objects | Walk object map, format as XML |
| `GET` | `LIBMTP_Get_File_To_Handler` | Stream to response body |
| `PUT` | `LIBMTP_Send_File_From_Handler` | Read from request body |
| `DELETE` | `LIBMTP_Delete_Object` | Update object map |
| `MKCOL` | `LIBMTP_Create_Folder` | Update object map |
| `MOVE` | Get + Send + Delete | No native MTP rename |
| `COPY` | Get + Send | |
| `HEAD` | Object map lookup | No MTP call needed |
| `OPTIONS` | Static response | |
| `LOCK`/`UNLOCK` | 200 OK (fake) | Finder requires these to not error |

### Finder-specific WebDAV quirks

These are the most likely source of silent failures. Handle all of them
explicitly in `finder.go`:

**PROPFIND on nonexistent paths must return 404, not 207.**
Finder probes for `.DS_Store`, `._filename`, `desktop.ini`, and other
platform files. Return 404 immediately for these without touching MTP:

```go
var finderProbeFiles = []string{
    ".DS_Store", "desktop.ini", "Thumbs.db", ".Spotlight-V100",
    ".fseventsd", ".Trashes", ".metadata_never_index",
}

func isFinderProbe(name string) bool {
    base := path.Base(name)
    return strings.HasPrefix(base, "._") || slices.Contains(finderProbeFiles, base)
}
```

**`getcontentlength` must be present on all file resources in PROPFIND
responses.** Missing content-length causes Finder to silently refuse to
show or download the file. For folders, omit it entirely.

**`getlastmodified` must be in RFC 1123 format.** Use
`time.RFC1123` in Go's time package. Other formats will cause Finder to
display incorrect modification dates or fail silently.

**`LOCK` and `UNLOCK` must return success.** Finder issues a `LOCK` before
any write operation. Return a valid lock token. The lock does not need to
actually be enforced — MTP's session serialisation provides the real
mutual exclusion. A fake lock response is correct behaviour here.

**Depth header in PROPFIND.** Finder issues `Depth: 1` for directory
listings and `Depth: 0` for stat-like queries. The handler must respect
these; returning full recursive listings for `Depth: 1` is a performance
problem for large directories.

**The `DAV:` namespace prefix.** Use exactly `DAV:` as the namespace URI.
Some WebDAV implementations use `DAV` without the colon. Finder is strict
here.

`golang.org/x/net/webdav` handles most of this correctly via its
`FileSystem` interface, but the MTP-specific metadata (content-length,
timestamps) must come through the `FileInfo` objects you return.

### Port selection and startup

```go
listener, err := net.Listen("tcp", "127.0.0.1:0")
port := listener.Addr().(*net.TCPAddr).Port
fmt.Printf("PORT=%d\n", port)  // Swift reads this from stdout
os.Stdout.Sync()
```

Print the port before beginning device enumeration. The Swift app will
wait on this line. Use a structured format (`PORT=N`) rather than a bare
integer so the Swift parser is robust against log lines.

---

## Component 2: Swift Menu Bar App

### Entitlements

`AndroidFS.entitlements` must include:

```xml
<key>com.apple.security.device.usb</key>
<true/>
```

Without this, IOKit USB matching returns no results silently. This is the
single most common setup failure. Verify entitlements are applied to the
correct target in Xcode before debugging IOKit.

Hardened runtime must be enabled for notarization. Set
`com.apple.security.cs.allow-unsigned-executable-memory` only if Go
binary requires it (check after first build).

### IOKit device monitoring (`DeviceWatcher.swift`)

Match on `kUSBVendorID` against the known Android vendor ID list in
`VendorIDs.plist`. Do not attempt to match on `kUSBProductID` — Android
vendor IDs are stable; product IDs are not. Known vendor IDs include
(non-exhaustive, maintain the full list in the plist):

| Manufacturer | Vendor ID |
|---|---|
| Google / HTC | 0x18D1 |
| Samsung | 0x04E8 |
| LG | 0x1004 |
| Motorola | 0x22B8 |
| Sony | 0x0FCE |
| OnePlus | 0x2A70 |
| Xiaomi | 0x2717 |
| OPPO | 0x22D9 |

```swift
// DeviceWatcher.swift — skeleton
class DeviceWatcher {
    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0

    func start(onAttach: @escaping (USBDevice) -> Void,
               onDetach: @escaping (USBDevice) -> Void) {
        // Build matching dict from VendorIDs.plist
        // IOServiceAddMatchingNotification for attach + detach
        // Run on a dedicated DispatchQueue
    }
}
```

### Bridge process lifecycle (`BridgeProcess.swift`)

```swift
class BridgeProcess {
    private var process: Process?
    private var port: Int?

    func start() async throws -> Int {
        let bridgeURL = Bundle.main.url(
            forResource: "bridge", withExtension: nil)!
        let p = Process()
        p.executableURL = bridgeURL
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()

        // Read stdout until we see PORT=N
        // Timeout after 15 seconds; if bridge doesn't respond,
        // the phone is not in File Transfer mode
        return try await readPort(from: pipe, timeout: 15)
    }

    func stop() {
        process?.terminate()
        process = nil
        port = nil
    }
}
```

### Mount management (`MountManager.swift`)

```swift
import NetFS

class MountManager {
    func mount(port: Int, displayName: String) async throws -> URL {
        let url = URL(string: "dav://127.0.0.1:\(port)/")!
        // NetFSMountURLAsync — call on main thread
        // Store mount path for unmount
        // Return mounted volume URL
    }

    func unmount(volumeURL: URL) async throws {
        // DAUnmountWithOptions via DiskArbitration
        // kDADiskUnmountOptionForce if clean unmount fails
    }
}
```

### Menu bar icon states

Use SF Symbols. Map bridge/mount states to icons:

| State | SF Symbol | Meaning |
|---|---|---|
| No device | `externaldrive` | Idle |
| Connecting | `externaldrive` (animated) | Waiting for File Transfer |
| Mounted | `externaldrive.fill` | Volume available in Finder |
| Error | `externaldrive.badge.xmark` | See menu for details |

Menu items when connected:
- Device name (disabled, informational)
- "Eject [Device Name]" → unmount + stop bridge
- Separator
- "Quit AndroidFS"

### "File Transfer not selected" UX

If the bridge process starts but does not print `PORT=N` within 15 seconds,
the user has not selected File Transfer mode. Post a `UNUserNotification`:

> **Check your phone**
> Select "File Transfer" from the USB notification to access your files
> in Finder.

Then kill the bridge and wait for the next IOKit attach event. Do not
enter a polling loop — wait for a physical detach/reattach.

### Login item

Register as a Login Item via `SMAppService.mainApp` (macOS 13+) or
`LaunchServices` for older targets. First launch should prompt the user
to enable this with a single-click affordance, not bury it in preferences.

---

## Implementation Order

Work through these phases in sequence. Verify each phase works before
proceeding to the next. Do not skip ahead.

### Phase 1 — Bridge: device connection and directory listing

1. `bridge/mtp/binding.go` — cgo bindings for device detect, session
   open/close, storage list, folder walk, file list
2. `bridge/mtp/session.go` — session goroutine, request channel,
   object map build
3. `bridge/webdav/handler.go` — `PROPFIND` only, static `OPTIONS`,
   fake `LOCK`/`UNLOCK`
4. `bridge/main.go` — port selection, stdout announcement, wire together

**Verify:** `make dev`, then Finder → Go → Connect to Server →
`dav://localhost:PORT`. Directory tree should appear.

### Phase 2 — Bridge: file operations

5. `GET` handler — `LIBMTP_Get_File_To_Handler` binding and streaming
6. `PUT` handler — `LIBMTP_Send_File_From_Handler` binding
7. `DELETE` handler
8. `MKCOL` handler
9. `MOVE` handler (copy + delete)

**Verify:** Copy a file from phone to Mac, from Mac to phone, delete on
phone, create folder on phone — all via Finder mount.

### Phase 3 — Swift app shell

10. `DeviceWatcher.swift` — IOKit attach/detach events (log to console,
    no bridge spawning yet)
11. `AppDelegate.swift` — menu bar extra, basic menu

**Verify:** Plug and unplug phone; console shows attach/detach events with
vendor ID.

### Phase 4 — Wiring

12. `BridgeProcess.swift` — spawn bridge on attach, read port, 15-second
    timeout + notification if File Transfer not selected
13. `MountManager.swift` — mount WebDAV on port received, unmount on
    detach or eject
14. Icon state management
15. Login item registration on first launch

**Verify:** Full end-to-end flow. Plug phone, select File Transfer, phone
appears in Finder without any manual steps.

### Phase 5 — Polish

16. Multiple storage support (phones with SD cards expose multiple
    MTP storages; present as subdirectories under a single mount root)
17. Error recovery — bridge crash, unexpected detach mid-transfer
18. Notarization build configuration

---

## Known Failure Modes

Document new failures here as they are discovered.

**Bridge produces no output:** libmtp found no device. Verify `mtp-detect`
sees the phone and File Transfer is selected before debugging the Go code.

**Finder shows volume but no files:** `PROPFIND` response is malformed.
Check: `getcontentlength` present on files, `DAV:` namespace correct,
depth handling correct. Use `curl -X PROPFIND http://localhost:PORT/ -H
"Depth: 1"` to inspect raw response.

**Finder shows files but download fails:** `GET` handler is not streaming
correctly, or libmtp is returning an error that is being swallowed. Check
bridge stderr.

**IOKit matching fires for non-Android devices:** Vendor ID list is too
broad. Add product ID filtering for the problematic vendor if necessary.

**Bridge crashes on large file transfer:** libmtp session state corruption
after a long-running operation. Implement session recovery — close and
reopen the MTP session, rebuild the object map, re-establish the WebDAV
server on the same port.

---

## Non-Goals for This Implementation

Do not implement these. Note them here so they are not accidentally
introduced.

- Wireless / Wi-Fi transfer (separate product decision)
- ADB or USB debugging dependency
- macFUSE or kernel extensions
- macOS App Store distribution
- Multiple simultaneous devices
- Quick Look / thumbnail generation
- Progress indication for large transfers (Finder provides its own)
- Android companion app
- Windows or Linux support

---

## Reference Material

- OpenMTP source (this repo's `main` branch) — MTP binding patterns only
- `libmtp` API docs: http://libmtp.sourceforge.net/doc/html/
- `golang.org/x/net/webdav` — FileSystem interface and server
- RFC 4918 — WebDAV specification
- Apple IOKit USB Device Interface Guide — USB matching and notification
- `NetFSMountURLAsync` — man page and header at
  `/Applications/Xcode.app/.../NetFS.framework/Headers/NetFS.h`
- DiskArbitration framework — `DADiskUnmount`

When OpenMTP's libmtp binding and this project's binding differ, prefer
the approach that keeps all MTP calls on the session goroutine, even if
it means more channel overhead. Correctness over performance in the
binding layer.
