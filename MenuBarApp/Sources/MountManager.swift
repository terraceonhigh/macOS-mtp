import Foundation
import NetFS
import DiskArbitration

/// Manages mounting and unmounting WebDAV volumes.
class MountManager {
    private(set) var mountPath: URL?
    private var daSession: DASession?

    init() {
        daSession = DASessionCreate(kCFAllocatorDefault)
        if let session = daSession {
            DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    deinit {
        if let session = daSession {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    /// Mounts a WebDAV URL and returns the mount path.
    func mount(port: Int, displayName: String) async throws -> URL {
        let serverURL = URL(string: "http://127.0.0.1:\(port)/")! as CFURL
        let mountDir = URL(fileURLWithPath: "/Volumes") as CFURL

        NSLog("AndroidFS: Mounting WebDAV at port %d as %@", port, displayName)

        return try await withCheckedThrowingContinuation { continuation in
            var mountPoints: Unmanaged<CFArray>?

            let openOptions: NSMutableDictionary = [
                kNAUIOptionKey: kNAUIOptionNoUI,  // suppress all auth UI
            ]
            let mountOptions: NSMutableDictionary = [:]

            let rc = NetFSMountURLSync(
                serverURL,
                mountDir,
                "" as CFString, // empty user = guest
                "" as CFString, // empty password
                openOptions,
                mountOptions,
                &mountPoints
            )

            if rc != 0 {
                NSLog("AndroidFS: NetFSMountURLSync failed with error %d", rc)
                continuation.resume(throwing: MountError.mountFailed(rc))
                return
            }

            if let points = mountPoints?.takeRetainedValue() as? [String],
               let firstMount = points.first {
                let mountURL = URL(fileURLWithPath: firstMount)
                self.mountPath = mountURL
                NSLog("AndroidFS: Mounted at %@", firstMount)
                continuation.resume(returning: mountURL)
            } else {
                NSLog("AndroidFS: Mount succeeded but no mount point returned")
                // Try to find it in /Volumes
                let fallback = URL(fileURLWithPath: "/Volumes/127.0.0.1")
                self.mountPath = fallback
                continuation.resume(returning: fallback)
            }
        }
    }

    /// Unmounts the currently mounted volume.
    func unmount() async {
        guard let path = mountPath else { return }
        NSLog("AndroidFS: Unmounting %@", path.path)

        guard let session = daSession else {
            // Fallback: use Process to call umount
            fallbackUnmount(path)
            mountPath = nil
            return
        }

        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, path as CFURL) else {
            NSLog("AndroidFS: Could not create DADisk for %@, trying fallback", path.path)
            fallbackUnmount(path)
            mountPath = nil
            return
        }

        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { disk, dissenter, context in
            if let dissenter = dissenter {
                let status = DADissenterGetStatus(dissenter)
                NSLog("AndroidFS: Clean unmount failed (status %d), forcing", status)
                DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionForce), nil, nil)
            } else {
                NSLog("AndroidFS: Unmounted successfully")
            }
        }, nil)

        mountPath = nil
    }

    var isMounted: Bool {
        mountPath != nil
    }

    private func fallbackUnmount(_ path: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/umount")
        p.arguments = [path.path]
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            // Force unmount
            let fp = Process()
            fp.executableURL = URL(fileURLWithPath: "/sbin/umount")
            fp.arguments = ["-f", path.path]
            try? fp.run()
            fp.waitUntilExit()
        }
    }
}

enum MountError: LocalizedError {
    case mountFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .mountFailed(let code):
            return "WebDAV mount failed with error code \(code)"
        }
    }
}
