import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var deviceWatcher: DeviceWatcher!
    private var bridge: BridgeProcess?
    private var mountManager = MountManager()

    // Current state
    private var connectedDevice: USBDevice?
    private var isConnecting = false  // lock out spurious events during connection

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupDeviceWatcher()
        updateIcon(state: .idle)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await teardown()
        }
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

            if mountManager.isMounted {
                menu.addItem(NSMenuItem(title: "Eject \(device.displayName)",
                                        action: #selector(ejectDevice),
                                        keyEquivalent: "e"))
            } else if isConnecting {
                let connecting = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
                connecting.isEnabled = false
                menu.addItem(connecting)
            }
        } else {
            let noDevice = NSMenuItem(title: "No device connected", action: nil, keyEquivalent: "")
            noDevice.isEnabled = false
            menu.addItem(noDevice)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit macOS-mtp",
                                action: #selector(quitApp),
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

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "macOS-mtp")
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
        NSLog("macOS-mtp: Device attached — \(device.displayName) (vendor: 0x%04X, product: 0x%04X)",
              device.vendorID, device.productID)

        // Ignore attach events while we're already connecting or mounted
        if isConnecting {
            NSLog("macOS-mtp: Ignoring attach — connection already in progress")
            return
        }
        if mountManager.isMounted {
            NSLog("macOS-mtp: Ignoring attach — already mounted")
            return
        }

        connectedDevice = device
        isConnecting = true
        updateIcon(state: .connecting)
        rebuildMenu()

        Task {
            await connectDevice(device)
        }
    }

    private func handleDeviceDetached(_ device: USBDevice) {
        NSLog("macOS-mtp: Device detached — \(device.displayName) (vendor: 0x%04X, product: 0x%04X)",
              device.vendorID, device.productID)

        // Ignore spurious detach events during connection — USB re-enumeration
        // causes rapid detach/attach cycles when the phone switches to MTP mode
        if isConnecting {
            NSLog("macOS-mtp: Ignoring detach — connection in progress (USB re-enumeration)")
            return
        }

        // Only tear down if we're actually mounted
        guard mountManager.isMounted || bridge?.isRunning == true else {
            connectedDevice = nil
            updateIcon(state: .idle)
            rebuildMenu()
            return
        }

        Task {
            await teardown()
            await MainActor.run {
                connectedDevice = nil
                updateIcon(state: .idle)
                rebuildMenu()
            }
        }
    }

    @objc private func ejectDevice() {
        NSLog("macOS-mtp: Eject requested")
        isConnecting = false
        Task {
            await teardown()
            await MainActor.run {
                connectedDevice = nil
                updateIcon(state: .idle)
                rebuildMenu()
            }
        }
    }

    @objc private func quitApp() {
        Task {
            await teardown()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Bridge + Mount Lifecycle

    private func connectDevice(_ device: USBDevice) async {
        // Ensure any previous bridge is fully stopped
        await teardown()

        // Wait for USB to fully settle — the phone does multiple
        // detach/reattach cycles when switching to MTP mode
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        // Retry with increasing delay
        let retryDelays: [UInt64] = [0, 3, 5] // seconds before each attempt

        for (attempt, delaySec) in retryDelays.enumerated() {
            guard isConnecting else { return } // cancelled

            if delaySec > 0 {
                try? await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
            }

            let bp = BridgeProcess()
            self.bridge = bp

            do {
                let port = try await bp.start()
                let displayName = bp.deviceName ?? device.displayName

                let _ = try await mountManager.mount(port: port, displayName: displayName)

                await MainActor.run {
                    NSLog("macOS-mtp: Device mounted as volume")
                    isConnecting = false
                    updateIcon(state: .mounted)
                    rebuildMenu()
                }
                return // success
            } catch let bridgeErr as BridgeError where bridgeErr == .timeout {
                NSLog("macOS-mtp: Bridge timeout — prompting user")
                BridgeProcess.postFileTransferNotification()
                bp.stop()
                self.bridge = nil
                await MainActor.run {
                    isConnecting = false
                    updateIcon(state: .error)
                    rebuildMenu()
                }
                return // don't retry timeouts
            } catch let err {
                bp.stop()
                self.bridge = nil
                if attempt < retryDelays.count - 1 {
                    NSLog("macOS-mtp: Attempt %d failed (%@), retrying...", attempt + 1, err.localizedDescription)
                } else {
                    NSLog("macOS-mtp: All attempts failed — %@", err.localizedDescription)
                    await MainActor.run {
                        isConnecting = false
                        updateIcon(state: .error)
                        rebuildMenu()
                    }
                }
            }
        }
    }

    private func teardown() async {
        if mountManager.isMounted {
            await mountManager.unmount()
        }
        bridge?.stop()
        bridge = nil
    }
}
