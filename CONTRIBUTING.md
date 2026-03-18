# Contributing to AndroidFS

## How to Contribute

1. Create a new issue describing the bug or feature.
2. Fork the repo and create your branch from **master**.
3. Make your changes.
4. Test with a real Android device — MTP cannot be meaningfully mocked.
5. Run `./test.sh` to verify the bridge integration tests pass.
6. Issue a pull request to **master**.

## Development Setup

See [docs/BUILDING.md](docs/BUILDING.md) for prerequisites and build
instructions.

Quick start:

```bash
brew install libmtp go
make run    # builds everything, launches the app
```

## Project Structure

```
bridge/              Go WebDAV bridge (cgo + libmtp)
  mtp/               MTP device bindings and session management
  webdav/            WebDAV filesystem implementation + Finder quirks
MenuBarApp/          Swift menu bar app (Xcode project)
  Sources/           Swift source files
  Resources/         Plist files, bundled assets
docs/                Architecture, building, testing, pitfalls
test.sh              Bridge integration test suite
test-swift.sh        IOKit device watcher diagnostic
```

## Testing

A physical Android device in File Transfer mode is required for testing.
See [docs/TESTING.md](docs/TESTING.md) for details.

Before submitting a PR, read [docs/MISTAKES.md](docs/MISTAKES.md) — it
documents 23 pitfalls we've already encountered. Many of them are
non-obvious (wrong MTP parent IDs, cgo callback signatures, IOKit class
names, macOS SIP stripping environment variables).

## License

Contributions are under the [MIT License](LICENSE).
