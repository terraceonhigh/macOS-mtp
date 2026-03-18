# AndroidFS — Android File Transfer for macOS

Mount your Android phone as a Finder volume over USB. Just plug in, select File Transfer, and your phone appears in Finder.

## How It Works

1. Plug in your Android phone via USB
2. Pull down notification shade → tap **File Transfer**
3. Phone appears in Finder sidebar

That's it.

## Screenshot

```
┌──────────────────────────────────┐
│  Finder                          │
│  ┌────────────┐ ┌──────────────┐ │
│  │ Locations  │ │ Internal     │ │
│  │            │ │  shared      │ │
│  │ 💾 Pixel 6 │ │  storage/    │ │
│  │            │ │              │ │
│  │            │ │ 📁 DCIM      │ │
│  │            │ │ 📁 Download  │ │
│  │            │ │ 📁 Pictures  │ │
│  │            │ │ 📁 Music     │ │
│  └────────────┘ └──────────────┘ │
└──────────────────────────────────┘
```

## Download

Grab the latest release from
[Releases](https://github.com/terraceonhigh/macOS-mtp/releases).

**First launch:** Right-click the app → Open (macOS will warn about an
unsigned app — click "Open" to proceed).

### Requirements

- macOS 13 (Ventura) or later
- Apple Silicon Mac (ARM)
- An Android phone with a data-capable USB cable

## Building from Source

```bash
# Prerequisites
brew install libmtp go
# Xcode must be installed (not just Command Line Tools)

# Build the distributable app
make dist

# Output: dist/AndroidFS.zip (~5 MB)
```

See [docs/BUILDING.md](docs/BUILDING.md) for full build instructions.

## Architecture

AndroidFS has two components:

**Go WebDAV Bridge** — A standalone binary that connects to the phone
via libmtp (cgo) and serves its filesystem over HTTP WebDAV on localhost.

**Swift Menu Bar App** — Watches for USB devices via IOKit, spawns the
bridge when an Android phone is detected, and mounts the WebDAV server
as a Finder volume via `NetFSMountURLSync`.

```
Phone ←USB→ libmtp ←cgo→ Go bridge ←HTTP→ WebDAV ←mount→ Finder
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design.

## What Works

- Browse phone filesystem in Finder
- Copy files from phone to Mac (drag & drop or cp)
- Copy files from Mac to phone
- Create folders on phone
- Delete files and folders on phone
- Menu bar icon with device status
- Automatic mount on plug-in, unmount on unplug

## Known Limitations

- Volume appears as "127.0.0.1" in Finder sidebar (cosmetic — files work fine)
- First connection takes ~15-30 seconds (USB interface settling)
- Large directories (700+ files) are slow to enumerate (MTP protocol limitation)
- ARM Macs only (no Intel build yet)
- Not notarized (requires right-click → Open on first launch)

See [TODO.md](TODO.md) for the full roadmap.

## Why Not...

**ADB?** Requires enabling Developer Options (Settings → About → tap Build
Number 7 times). Too much friction for non-technical users.

**macFUSE?** Requires a kernel extension, which means disabling SIP or
navigating Gatekeeper. Not acceptable for a consumer app.

**Android File Transfer?** Abandoned by Google, buggy, 4GB file limit.

**File Provider API?** Designed for cloud storage. MTP's stateful,
session-locked protocol doesn't map well to File Provider's pull-based model.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — Component design, data flow
- [Building](docs/BUILDING.md) — Prerequisites, build targets
- [Testing](docs/TESTING.md) — Test suites, manual testing, debugging
- [Mistakes](docs/MISTAKES.md) — 23 pitfalls we hit and how we fixed them

## Credits

This project is a fork of [OpenMTP](https://github.com/ganeshrvel/openmtp)
by Ganesh Rathinavel. The original Electron frontend and Node.js MTP
bindings are not used — AndroidFS is a clean reimplementation with a
different architecture (Go + Swift instead of Electron + Node).

## License

[MIT](LICENSE)
