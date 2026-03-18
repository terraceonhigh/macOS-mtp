# macOS-mtp Architecture

## Overview

macOS-mtp is a macOS menu bar application that makes an Android phone
appear as a mounted volume in Finder when connected via USB. It requires
no developer mode, no USB debugging, and no user action beyond selecting
"File Transfer" on the phone's USB notification.

## Components

```
┌─────────────────────────────────────────────────────────┐
│                    macOS-mtp.app                         │
│                                                         │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────┐ │
│  │ DeviceWatcher│──▶│BridgeProcess │──▶│MountManager │ │
│  │   (IOKit)    │   │  (Process)   │   │  (NetFS)    │ │
│  └──────────────┘   └──────┬───────┘   └─────────────┘ │
│                            │                            │
│                    spawns   │                            │
│                            ▼                            │
│                   ┌────────────────┐                    │
│                   │  bridge binary │                    │
│                   │   (Go + cgo)   │                    │
│                   └───────┬────────┘                    │
│                           │                             │
└───────────────────────────┼─────────────────────────────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
              ▼             ▼             ▼
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │  libmtp  │ │  WebDAV  │ │  Finder  │
        │  (cgo)   │ │  server  │ │  mount   │
        └────┬─────┘ └──────────┘ └──────────┘
             │
             ▼
        ┌──────────┐
        │  Phone   │
        │  (USB)   │
        └──────────┘
```

### Swift Menu Bar App (`MenuBarApp/`)

- **AppDelegate.swift** — Orchestrates the lifecycle: device attach →
  bridge start → mount. Device detach → unmount → bridge stop. Manages
  menu bar icon state.
- **DeviceWatcher.swift** — IOKit USB monitoring. Matches `IOUSBHostDevice`
  class (macOS 13+) filtered by known Android vendor IDs. Fires callbacks
  on attach/detach.
- **BridgeProcess.swift** — Spawns the Go bridge binary from the app
  bundle's `Resources/` directory. Reads `PORT=N` and `DEVICE=name` from
  stdout. Kills `PTPCamera`/`AMPDevicesAgent` first to free the USB
  interface. 15-second timeout with user notification if File Transfer
  mode isn't selected.
- **MountManager.swift** — Mounts the WebDAV server via `NetFSMountURLSync`
  with guest auth and no-UI options. Unmounts via `DiskArbitration` or
  fallback `umount`.

### Go WebDAV Bridge (`bridge/`)

- **main.go** — Entry point. Binds a random localhost port, detects the
  MTP device, starts the WebDAV server, prints `PORT=N` and `DEVICE=name`
  to stdout for the Swift parent to read.
- **mtp/binding.go** — cgo bindings against libmtp. Device detection,
  file streaming (via C callbacks), folder creation, deletion. Uses the
  raw device detection API (`LIBMTP_Detect_Raw_Devices` +
  `LIBMTP_Open_Raw_Device_Uncached`) for better diagnostics.
- **mtp/binding_callbacks.go** — C↔Go callback bridge for streaming file
  data. Matches the exact `MTPDataPutFunc`/`MTPDataGetFunc` signatures
  (5 parameters each).
- **mtp/session.go** — Single-goroutine MTP serialization. All MTP calls
  go through a request/response channel. Maintains a bidirectional object
  map (POSIX path ↔ MTP object handle) with lazy directory enumeration.
- **webdav/handler.go** — Implements `golang.org/x/net/webdav.FileSystem`.
  Translates WebDAV operations to MTP operations. Handles file upload via
  buffered `mtpNewFile` (buffers entire file, sends on Close).
- **webdav/finder.go** — Intercepts Finder probe files (`.DS_Store`,
  `._*`, `.Spotlight-V100`, etc.) and returns 404 without touching MTP.

## Key Design Decisions

### Why WebDAV?

macOS Finder mounts WebDAV natively and surfaces it in the sidebar. No
kernel extensions, no File Provider complexity, no entitlement pain beyond
USB access. A `localhost` WebDAV server mounted via `NetFSMountURLSync` is
indistinguishable to the user from any other volume.

### Why a separate Go binary?

libmtp is a C library. cgo provides straightforward bindings. Go's
goroutines map cleanly onto the single-threaded MTP serialization
requirement. The `golang.org/x/net/webdav` package handles most WebDAV
protocol details. A single static binary is trivial to bundle.

### Why lazy enumeration?

A full recursive walk of a phone with thousands of files (YouTube Music
caches, photo thumbnails) takes minutes over MTP. Lazy enumeration fetches
directory contents only when Finder actually browses into them, making
startup near-instant.

### Why kill PTPCamera?

macOS automatically launches `PTPCamera` when it detects a PTP/MTP USB
device, claiming the interface before libmtp can. Killing it before
bridge startup frees the interface. This is the same approach used by
other macOS MTP tools.

## Data Flow

### File Download (GET)

```
Finder → HTTP GET → webdav.Handler → mtpFile.Read()
  → session.Do(OpGetFile) → [session goroutine]
  → binding.GetFileToWriter() → LIBMTP_Get_File_To_Handler
  → goDataPutFunc callback → io.Writer (bytes.Reader)
  → HTTP response body
```

### File Upload (PUT)

```
Finder → HTTP PUT → webdav.Handler → mtpNewFile.Write()
  → bytes.Buffer (accumulate entire file)
  → mtpNewFile.Close()
  → session.Do(OpSendFile) → [session goroutine]
  → binding.SendFileFromReader() → LIBMTP_Send_File_From_Handler
  → goDataGetFunc callback → io.Reader (bytes.Reader)
  → MTP device
```

### Directory Listing (PROPFIND)

```
Finder → HTTP PROPFIND Depth:1 → webdav.Handler → mtpDir.Readdir()
  → session.EnsurePopulated(path)
    → if not cached: session.Do(OpListDir)
      → [session goroutine] → LIBMTP_Get_Files_And_Folders
      → populate ObjectMap, mark as populated
  → ObjectMap.ListChildren(path)
  → XML multistatus response
```
