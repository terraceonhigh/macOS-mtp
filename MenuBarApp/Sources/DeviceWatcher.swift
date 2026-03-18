import Foundation
import IOKit

/// Represents a detected USB device.
struct USBDevice {
    let vendorID: UInt16
    let productID: UInt16
    let vendorName: String
    let locationID: UInt32
    let displayName: String
}

/// Watches for USB attach/detach events matching known Android vendor IDs.
class DeviceWatcher {
    private var notifyPort: IONotificationPortRef?
    private var addedIter: io_iterator_t = 0
    private var removedIter: io_iterator_t = 0
    private var onAttach: ((USBDevice) -> Void)?
    private var onDetach: ((USBDevice) -> Void)?
    private var vendorIDs: Set<UInt16> = []
    private var vendorNames: [UInt16: String] = [:]

    init() {
        loadVendorIDs()
    }

    deinit {
        stop()
    }

    private func loadVendorIDs() {
        // Hardcoded known Android vendor IDs
        let vendors: [(UInt16, String)] = [
            (0x18D1, "Google / HTC"),
            (0x04E8, "Samsung"),
            (0x1004, "LG"),
            (0x22B8, "Motorola"),
            (0x0FCE, "Sony"),
            (0x2A70, "OnePlus"),
            (0x2717, "Xiaomi"),
            (0x22D9, "OPPO"),
            (0x12D1, "Huawei"),
            (0x0B05, "Asus"),
            (0x1685, "Lenovo"),
            (0x19D2, "ZTE"),
            (0x0421, "Nokia"),
            (0x1FC9, "Realme / BBK"),
            (0x2888, "Nothing"),
        ]
        for (vid, name) in vendors {
            vendorIDs.insert(vid)
            vendorNames[vid] = name
        }
        NSLog("macOS-mtp: Loaded %d vendor IDs", vendorIDs.count)
    }

    /// Begin watching for USB device attach/detach events.
    func start(onAttach: @escaping (USBDevice) -> Void,
               onDetach: @escaping (USBDevice) -> Void) {
        self.onAttach = onAttach
        self.onDetach = onDetach

        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = notifyPort else {
            NSLog("macOS-mtp: Failed to create IONotificationPort")
            return
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        // Match ALL USB host devices, filter by vendor ID in callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Attach notifications
        let matchAttach = IOServiceMatching("IOUSBHostDevice")
        let krAdd = IOServiceAddMatchingNotification(
            notifyPort,
            kIOFirstMatchNotification,
            matchAttach,
            { refcon, iterator in
                guard let refcon = refcon else { return }
                let watcher = Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue()
                watcher.handleIterator(iterator, attached: true)
            },
            selfPtr,
            &addedIter
        )

        if krAdd == KERN_SUCCESS {
            NSLog("macOS-mtp: Registered for USB attach notifications")
            // Drain initial iterator to arm the notification and catch already-connected devices
            handleIterator(addedIter, attached: true)
        } else {
            NSLog("macOS-mtp: Failed to register attach notification: %d", krAdd)
        }

        // Detach notifications
        let matchDetach = IOServiceMatching("IOUSBHostDevice")
        let krRemove = IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            matchDetach,
            { refcon, iterator in
                guard let refcon = refcon else { return }
                let watcher = Unmanaged<DeviceWatcher>.fromOpaque(refcon).takeUnretainedValue()
                watcher.handleIterator(iterator, attached: false)
            },
            selfPtr,
            &removedIter
        )

        if krRemove == KERN_SUCCESS {
            NSLog("macOS-mtp: Registered for USB detach notifications")
            // Drain initial iterator to arm the notification
            handleIterator(removedIter, attached: false)
        } else {
            NSLog("macOS-mtp: Failed to register detach notification: %d", krRemove)
        }
    }

    func stop() {
        if addedIter != 0 {
            IOObjectRelease(addedIter)
            addedIter = 0
        }
        if removedIter != 0 {
            IOObjectRelease(removedIter)
            removedIter = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func handleIterator(_ iterator: io_iterator_t, attached: Bool) {
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }

            let vid = getIntProperty(service, key: "idVendor").map { UInt16($0) } ?? 0

            // Filter: only care about known Android vendors
            guard vendorIDs.contains(vid) else { continue }

            let device = extractDeviceInfo(from: service)
            NSLog("macOS-mtp: USB %@ — %@ (vendor: 0x%04X, product: 0x%04X)",
                  attached ? "attached" : "detached",
                  device.displayName, device.vendorID, device.productID)

            if attached {
                onAttach?(device)
            } else {
                onDetach?(device)
            }
        }
    }

    private func extractDeviceInfo(from service: io_service_t) -> USBDevice {
        let vendorID = UInt16(getIntProperty(service, key: "idVendor") ?? 0)
        let productID = UInt16(getIntProperty(service, key: "idProduct") ?? 0)
        let locationID = UInt32(getIntProperty(service, key: "locationID") ?? 0)
        let vendorName = vendorNames[vendorID] ?? "Unknown"

        let productName = getStringProperty(service, key: "USB Product Name")
            ?? getStringProperty(service, key: "Product Name")
            ?? vendorName

        return USBDevice(
            vendorID: vendorID,
            productID: productID,
            vendorName: vendorName,
            locationID: locationID,
            displayName: productName
        )
    }

    private func getIntProperty(_ service: io_service_t, key: String) -> Int? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return value.intValue
    }

    private func getStringProperty(_ service: io_service_t, key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else {
            return nil
        }
        return value.isEmpty ? nil : value
    }
}
