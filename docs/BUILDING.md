# Building AndroidFS

## Prerequisites

### Required software

```bash
# Go 1.21+
/opt/homebrew/bin/go version

# Xcode (full, not just Command Line Tools)
xcode-select -p    # must point to Xcode.app, not CommandLineTools
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch

# libmtp (via Homebrew)
brew install libmtp

# Verify libmtp works with a connected phone
mtp-detect    # should show device info
```

### Required hardware

A physical Android device connected via USB with **File Transfer** mode
selected. A data-capable USB cable (not charge-only).

### libmtp header

The cgo bindings need the libmtp header. It's already checked into
`bridge/cvendor/libmtp.h`. If your libmtp version differs:

```bash
cp $(brew --prefix libmtp)/include/libmtp.h bridge/cvendor/libmtp.h
```

## Build Targets

```bash
# Build just the Go bridge binary
make bridge

# Build the Swift app (Debug) with bridge bundled
make app-debug

# Build and run the app (kills existing instance)
make run

# Build the Go bridge and run standalone (for manual WebDAV testing)
make dev

# Build distributable Release .app + .zip
make dist

# Clean all build artifacts
make clean
```

## What `make dist` produces

```
dist/
├── AndroidFS.app/
│   ├── Contents/
│   │   ├── MacOS/AndroidFS          # Swift menu bar app
│   │   ├── Resources/
│   │   │   ├── bridge               # Go WebDAV bridge binary
│   │   │   └── VendorIDs.plist      # Android vendor IDs
│   │   ├── Frameworks/
│   │   │   ├── libmtp.9.dylib       # MTP library (rpath rewritten)
│   │   │   └── libusb-1.0.0.dylib   # USB library (rpath rewritten)
│   │   └── Info.plist
│   └── ...
└── AndroidFS.zip                     # ~5MB, ready to share
```

All dynamic library paths are rewritten with `install_name_tool` to use
`@executable_path/../Frameworks/`, so the app is self-contained. No
Homebrew installation needed on the target Mac.

## Development Workflow

### Testing the bridge standalone

```bash
make dev
# Bridge prints PORT=XXXXX
# In Finder: Go → Connect to Server → dav://localhost:XXXXX
```

### Testing the full app

```bash
make run
# App appears in menu bar
# Plug in phone, select File Transfer
# Phone appears as volume in Finder
```

### Running the integration test suite

```bash
# Requires phone connected in File Transfer mode
./test.sh
```

## Platform Notes

- **ARM only**: The bridge binary and bundled dylibs are arm64. No x86_64
  (Intel Mac) support in the current build config. To add it, build the
  bridge as a universal binary and bundle both architectures of the dylibs.
- **macOS 13+**: The Swift app uses `IOUSBHostDevice` matching (introduced
  in macOS 13). Older macOS would need `IOUSBDevice` matching.
- **Not notarized**: The app is ad-hoc signed. First launch requires
  right-click → Open to bypass Gatekeeper. Notarization requires an
  Apple Developer account ($99/year).
