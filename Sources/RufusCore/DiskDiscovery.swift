import Foundation
import DiskArbitration

public enum DiskDiscoveryError: LocalizedError {
    case commandFailed(String)
    case plistParseFailed
    case unsafeTargetDisk(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return "diskutil fehlgeschlagen: \(msg)"
        case .plistParseFailed: return "Konnte Laufwerksliste nicht lesen."
        case .unsafeTargetDisk(let id): return "Sicherheitsabbruch: /dev/\(id) ist ein geschütztes System- oder internes Laufwerk und darf nicht gelöscht werden!"
        }
    }
}

public final class DiskDiscovery {

    /// Runs a command synchronously and returns stdout Data.
    public static func runProcess(_ executablePath: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8) ?? "Exit \(process.terminationStatus)"
            throw DiskDiscoveryError.commandFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outData
    }

    /// Extracts the whole disk identifier (e.g. "disk0s3" -> "disk0", "disk1s4s1" -> "disk1").
    public static func wholeDiskIdentifier(from identifier: String) -> String {
        let clean = identifier.replacingOccurrences(of: "/dev/r", with: "")
            .replacingOccurrences(of: "/dev/", with: "")
        guard clean.hasPrefix("disk") else { return clean }
        let rest = clean.dropFirst(4)
        let digits = rest.prefix { $0.isNumber }
        return "disk\(digits)"
    }

    /// Returns the set of whole-disk identifiers (e.g. "disk0", "disk1", "disk2") that MUST NEVER be erased.
    /// Traces APFS containers back to their backing physical stores — crucial when macOS boots from an external SSD!
    public static func protectedWholeDisks() -> Set<String> {
        var protected = Set<String>()

        // 1. Inspect critical macOS system paths directly
        for path in ["/", "/System/Volumes/Data", "/Users"] {
            if let data = try? runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", path]),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                if let devId = dict["DeviceIdentifier"] as? String {
                    protected.insert(wholeDiskIdentifier(from: devId))
                }
                if let parent = dict["ParentWholeDisk"] as? String {
                    protected.insert(wholeDiskIdentifier(from: parent))
                }
            }
        }

        // 2. Parse `diskutil list -plist` to walk APFSPhysicalStores & critical mount points
        if let listData = try? runProcess("/usr/sbin/diskutil", arguments: ["list", "-plist"]),
           let plist = try? PropertyListSerialization.propertyList(from: listData, format: nil) as? [String: Any],
           let allDisksAndParts = plist["AllDisksAndPartitions"] as? [[String: Any]] {

            // Build map: synthesized container wholeDisk -> backing physical wholeDisks
            var containerToPhysical: [String: [String]] = [:]
            for entry in allDisksAndParts {
                guard let devId = entry["DeviceIdentifier"] as? String else { continue }
                let whole = wholeDiskIdentifier(from: devId)

                if let osInternal = entry["OSInternal"] as? Bool, osInternal {
                    protected.insert(whole)
                }

                if let stores = entry["APFSPhysicalStores"] as? [[String: Any]] {
                    var backing: [String] = []
                    for store in stores {
                        if let storeDev = store["DeviceIdentifier"] as? String {
                            backing.append(wholeDiskIdentifier(from: storeDev))
                        }
                    }
                    containerToPhysical[whole] = backing
                }

                // Check APFS volumes for system mounts
                if let volumes = entry["APFSVolumes"] as? [[String: Any]] {
                    for vol in volumes {
                        if let mp = vol["MountPoint"] as? String, isSystemMountPoint(mp) {
                            protected.insert(whole)
                        }
                        if let osInt = vol["OSInternal"] as? Bool, osInt {
                            protected.insert(whole)
                        }
                    }
                }

                // Check regular partitions for system mounts
                if let partitions = entry["Partitions"] as? [[String: Any]] {
                    for part in partitions {
                        if let mp = part["MountPoint"] as? String, isSystemMountPoint(mp) {
                            protected.insert(whole)
                        }
                    }
                }
            }

            // Propagate protection from synthesized containers to their physical backing disks
            for (container, physicals) in containerToPhysical {
                if protected.contains(container) {
                    for phys in physicals {
                        protected.insert(phys)
                    }
                }
            }
        }

        return protected
    }

    private static func isSystemMountPoint(_ mp: String) -> Bool {
        if mp == "/" || mp == "/System/Volumes/Data" || mp == "/System/Volumes/Preboot"
            || mp == "/System/Volumes/VM" || mp == "/System/Volumes/Update"
            || mp.hasPrefix("/System/") || mp == "/Users" {
            return true
        }
        return false
    }

    /// Discovers safe, flashable USB / external removable drives on macOS.
    public static func discoverDrives(includeFixedExternalUSB: Bool = false) throws -> [USBDrive] {
        let protected = protectedWholeDisks()

        let listData = try runProcess("/usr/sbin/diskutil", arguments: ["list", "-plist"])
        guard let plist = try PropertyListSerialization.propertyList(from: listData, format: nil) as? [String: Any],
              let wholeDisks = plist["WholeDisks"] as? [String],
              let allEntries = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            throw DiskDiscoveryError.plistParseFailed
        }

        // Index mounted volume names per whole disk
        var volumesByWhole: [String: [String]] = [:]
        var schemeByWhole: [String: String] = [:]
        for entry in allEntries {
            guard let devId = entry["DeviceIdentifier"] as? String else { continue }
            let whole = wholeDiskIdentifier(from: devId)
            if let content = entry["Content"] as? String {
                schemeByWhole[whole] = content
            }
            var names: [String] = []
            if let volName = entry["VolumeName"] as? String, !volName.isEmpty {
                names.append(volName)
            }
            if let parts = entry["Partitions"] as? [[String: Any]] {
                for p in parts {
                    if let vn = p["VolumeName"] as? String, !vn.isEmpty {
                        names.append(vn)
                    }
                }
            }
            volumesByWhole[whole] = names
        }

        var drives: [USBDrive] = []
        for diskId in wholeDisks {
            // Hard block protected system/OS disks!
            if protected.contains(diskId) { continue }

            guard let infoData = try? runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", "/dev/\(diskId)"]),
                  let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
                continue
            }

            // Exclude virtual disks, disk images, synthesized APFS containers
            let virtualOrPhysical = (info["VirtualOrPhysical"] as? String) ?? ""
            let busProtocol = (info["BusProtocol"] as? String) ?? ""
            if virtualOrPhysical.lowercased() == "virtual" || busProtocol.lowercased().contains("disk image") {
                continue
            }
            if info["APFSContainerReference"] != nil && (info["WholeDisk"] as? Bool == true) && virtualOrPhysical.isEmpty {
                continue
            }

            let isInternal = (info["Internal"] as? Bool) ?? true
            if isInternal { continue }

            let isRemovable = (info["RemovableMedia"] as? Bool) ?? (info["Removable"] as? Bool) ?? false
            let isEjectable = (info["Ejectable"] as? Bool) ?? false
            let sizeBytes = (info["IOKitSize"] as? Int64) ?? (info["Size"] as? Int64) ?? (info["TotalSize"] as? Int64) ?? 0
            if sizeBytes <= 0 { continue }

            // Safety: Exclude PCI-Express / NVMe external enclosures unless explicitly USB/SD/FireWire
            let isUSBOrCard = busProtocol.localizedCaseInsensitiveContains("USB")
                || busProtocol.localizedCaseInsensitiveContains("Secure Digital")
                || busProtocol.localizedCaseInsensitiveContains("SD")

            if !isRemovable && !isEjectable {
                // Only allow fixed external drives if user opted in AND it's USB (never PCIe boot SSDs)
                guard includeFixedExternalUSB && isUSBOrCard else { continue }
            }

            let mediaName = (info["MediaName"] as? String)
                ?? (info["IORegistryEntryName"] as? String)
                ?? "USB Drive"
            let solidState = info["SolidState"] as? Bool
            let scheme = (info["Content"] as? String) ?? schemeByWhole[diskId] ?? "None"

            var mountedNames = volumesByWhole[diskId] ?? []
            if mountedNames.isEmpty, let vn = info["VolumeName"] as? String, !vn.isEmpty {
                mountedNames.append(vn)
            }

            drives.append(USBDrive(
                deviceIdentifier: diskId,
                deviceNode: "/dev/\(diskId)",
                mediaName: mediaName,
                sizeBytes: sizeBytes,
                busProtocol: busProtocol.isEmpty ? "External" : busProtocol,
                isRemovable: isRemovable || isEjectable,
                isExternal: !isInternal,
                isSolidState: solidState,
                currentScheme: scheme,
                mountedVolumes: mountedNames
            ))
        }

        return drives.sorted { $0.deviceIdentifier.localizedStandardCompare($1.deviceIdentifier) == .orderedAscending }
    }

    /// Defense-in-depth verification run by the privileged helper BEFORE erasing any disk.
    public static func validateSafeTarget(deviceIdentifier: String, allowDiskImage: Bool = false) throws {
        let whole = wholeDiskIdentifier(from: deviceIdentifier)
        guard whole == deviceIdentifier, whole.hasPrefix("disk") else {
            throw DiskDiscoveryError.unsafeTargetDisk(deviceIdentifier)
        }

        let protected = protectedWholeDisks()
        if protected.contains(whole) {
            throw DiskDiscoveryError.unsafeTargetDisk(whole)
        }

        let infoData = try runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", "/dev/\(whole)"])
        guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
            throw DiskDiscoveryError.unsafeTargetDisk(whole)
        }

        let busProtocol = (info["BusProtocol"] as? String) ?? ""
        let virtualOrPhysical = (info["VirtualOrPhysical"] as? String) ?? ""
        let isDiskImage = virtualOrPhysical.lowercased() == "virtual" || busProtocol.lowercased().contains("disk image")

        if isDiskImage {
            if !allowDiskImage {
                throw DiskDiscoveryError.unsafeTargetDisk(whole)
            }
            return
        }

        let isInternal = (info["Internal"] as? Bool) ?? true
        if isInternal {
            throw DiskDiscoveryError.unsafeTargetDisk(whole)
        }

        // Also block PCI-Express disks as an extra safeguard against external NVMe boot drives
        if busProtocol.localizedCaseInsensitiveContains("PCI") {
            throw DiskDiscoveryError.unsafeTargetDisk(whole)
        }
    }
}

// MARK: - Live USB Hot-Plug Monitor (DiskArbitration)

public final class DiskHotPlugMonitor {
    private var session: DASession?
    private let queue = DispatchQueue(label: "dev.rufusmac.diskarbitration")
    private var onChange: (() -> Void)?
    private var debounceWorkItem: DispatchWorkItem?

    public init() {}

    public func start(onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange

        guard let daSession = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = daSession

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let appearedCallback: DADiskAppearedCallback = { _, ctx in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<DiskHotPlugMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.scheduleNotify()
        }

        let disappearedCallback: DADiskDisappearedCallback = { _, ctx in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<DiskHotPlugMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.scheduleNotify()
        }

        DARegisterDiskAppearedCallback(daSession, nil, appearedCallback, context)
        DARegisterDiskDisappearedCallback(daSession, nil, disappearedCallback, context)
        DASessionSetDispatchQueue(daSession, queue)
    }

    private func scheduleNotify() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    public func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        if let daSession = session {
            DASessionSetDispatchQueue(daSession, nil)
            session = nil
        }
        onChange = nil
    }

    deinit {
        stop()
    }
}
