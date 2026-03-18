import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var deviceWatcher: DeviceWatcher!

    // Current state
    private var connectedDevice: USBDevice?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupDeviceWatcher()
        updateIcon(state: .idle)
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if let device = connectedDevice {
            let deviceItem = NSMenuItem(title: device.displayName, action: nil, keyEquivalent: "")
            deviceItem.isEnabled = false
            menu.addItem(deviceItem)

            menu.addItem(NSMenuItem(title: "Eject \(device.displayName)",
                                    action: #selector(ejectDevice),
                                    keyEquivalent: "e"))
        } else {
            let noDevice = NSMenuItem(title: "No device connected", action: nil, keyEquivalent: "")
            noDevice.isEnabled = false
            menu.addItem(noDevice)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit AndroidFS",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Icon State

    enum IconState {
        case idle
        case connecting
        case mounted
        case error
    }

    private func updateIcon(state: IconState) {
        guard let button = statusItem.button else { return }

        let symbolName: String
        switch state {
        case .idle:
            symbolName = "externaldrive"
        case .connecting:
            symbolName = "externaldrive"
        case .mounted:
            symbolName = "externaldrive.fill"
        case .error:
            symbolName = "externaldrive.badge.xmark"
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AndroidFS")
        button.image?.size = NSSize(width: 18, height: 18)
    }

    // MARK: - Device Watcher

    private func setupDeviceWatcher() {
        deviceWatcher = DeviceWatcher()
        deviceWatcher.start(
            onAttach: { [weak self] device in
                DispatchQueue.main.async {
                    self?.handleDeviceAttached(device)
                }
            },
            onDetach: { [weak self] device in
                DispatchQueue.main.async {
                    self?.handleDeviceDetached(device)
                }
            }
        )
    }

    private func handleDeviceAttached(_ device: USBDevice) {
        NSLog("AndroidFS: Device attached — \(device.displayName) (vendor: 0x%04X, product: 0x%04X)",
              device.vendorID, device.productID)
        connectedDevice = device
        updateIcon(state: .connecting)
        rebuildMenu()
        // Phase 4: spawn bridge, mount WebDAV
    }

    private func handleDeviceDetached(_ device: USBDevice) {
        NSLog("AndroidFS: Device detached — \(device.displayName) (vendor: 0x%04X, product: 0x%04X)",
              device.vendorID, device.productID)
        connectedDevice = nil
        updateIcon(state: .idle)
        rebuildMenu()
        // Phase 4: unmount, stop bridge
    }

    @objc private func ejectDevice() {
        NSLog("AndroidFS: Eject requested")
        // Phase 4: unmount + stop bridge
        connectedDevice = nil
        updateIcon(state: .idle)
        rebuildMenu()
    }
}
