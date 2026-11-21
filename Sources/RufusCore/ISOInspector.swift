import Foundation
import CryptoKit

public enum ISOInspectorError: LocalizedError {
    case fileNotFound(String)
    case attachFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "Datei nicht gefunden: \(p)"
        case .attachFailed(let m): return "ISO konnte nicht eingehängt werden: \(m)"
        }
    }
}

public struct MountedImageInfo: Sendable {
    public let deviceNode: String
    public let mountPoint: String
    public let tempMountDir: String?
    public let volumeName: String
    public let shouldDetachOnCleanup: Bool
}

public final class ISOInspector {

    /// Checks `hdiutil info -plist` to see if `isoPath` is already mounted (e.g. user double-clicked it in Finder).
    /// Reusing an existing mount avoids `hdiutil: attach failed - Resource busy`.
    public static func findExistingMount(isoPath: String) -> MountedImageInfo? {
        let targetReal = URL(fileURLWithPath: isoPath).resolvingSymlinksInPath().standardizedFileURL.path
        guard let data = try? DiskDiscovery.runProcess("/usr/bin/hdiutil", arguments: ["info", "-plist"]) else {
            return nil
        }
        let xmlStart = data.range(of: Data("<?xml".utf8))
        let plistData = xmlStart.map { data.subdata(in: $0.lowerBound..<data.endIndex) } ?? data
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else {
            return nil
        }

        for img in images {
            guard let path = img["image-path"] as? String else { continue }
            let imgReal = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            guard imgReal == targetReal else { continue }
            guard let entities = img["system-entities"] as? [[String: Any]] else { continue }
            for entity in entities {
                if let mp = entity["mount-point"] as? String, !mp.isEmpty,
                   let dev = entity["dev-entry"] as? String, !dev.isEmpty,
                   FileManager.default.fileExists(atPath: mp) {
                    let volName = queryVolumeName(for: dev) ?? URL(fileURLWithPath: mp).lastPathComponent
                    return MountedImageInfo(
                        deviceNode: dev,
                        mountPoint: mp,
                        tempMountDir: nil,
                        volumeName: volName,
                        shouldDetachOnCleanup: false
                    )
                }
            }
        }
        return nil
    }

    /// Queries the real UDF / ISO9660 volume name from diskutil.
    public static func queryVolumeName(for deviceNode: String) -> String? {
        guard let data = try? DiskDiscovery.runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", deviceNode]),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = dict["VolumeName"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mounts an ISO read-only in a world-traversable `/tmp/rufusmac-iso-<UUID>` mountpoint (never collides with /Volumes,
    /// and cleanly readable by both GUI user and privileged helper). Reuses an existing mount if already attached.
    public static func attachReadOnly(isoPath: String, preferReuseExisting: Bool = true) throws -> MountedImageInfo {
        if preferReuseExisting, let existing = findExistingMount(isoPath: isoPath) {
            return existing
        }

        let mountDir = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("rufusmac-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mountDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach",
            "-readonly",
            "-nobrowse",
            "-noverify",
            "-noautoopen",
            "-mountpoint", mountDir.path,
            "-plist",
            isoPath
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: mountDir)
            let errStr = String(data: errData, encoding: .utf8) ?? "hdiutil exit \(process.terminationStatus)"
            throw ISOInspectorError.attachFailed(errStr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let xmlStart = outData.range(of: Data("<?xml".utf8))
        let plistData = xmlStart.map { outData.subdata(in: $0.lowerBound..<outData.endIndex) } ?? outData

        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            try? FileManager.default.removeItem(at: mountDir)
            throw ISOInspectorError.attachFailed("Ungültige hdiutil-Antwort.")
        }

        var chosenDev: String?
        var chosenMount: String?
        for entity in entities {
            if let mp = entity["mount-point"] as? String, !mp.isEmpty {
                chosenMount = mp
                if let dev = entity["dev-entry"] as? String {
                    chosenDev = dev
                }
                break
            }
        }
        if chosenDev == nil {
            chosenDev = entities.first?["dev-entry"] as? String
        }

        guard let dev = chosenDev, let mount = chosenMount else {
            if let dev = chosenDev {
                detach(deviceNode: dev, tempMountDir: mountDir.path)
            } else {
                try? FileManager.default.removeItem(at: mountDir)
            }
            throw ISOInspectorError.attachFailed("Kein lesbares Dateisystem im ISO gefunden.")
        }

        let realVolName = queryVolumeName(for: dev)
            ?? URL(fileURLWithPath: isoPath).deletingPathExtension().lastPathComponent

        return MountedImageInfo(
            deviceNode: dev,
            mountPoint: mount,
            tempMountDir: mountDir.path,
            volumeName: realVolName,
            shouldDetachOnCleanup: true
        )
    }

    public static func detach(_ mounted: MountedImageInfo) {
        guard mounted.shouldDetachOnCleanup else { return }
        detach(deviceNode: mounted.deviceNode, tempMountDir: mounted.tempMountDir)
    }

    public static func detach(deviceNode: String, tempMountDir: String? = nil) {
        let whole = "/dev/" + DiskDiscovery.wholeDiskIdentifier(from: deviceNode)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", "-force", whole]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()

        if let dir = tempMountDir {
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    /// Inspects an ISO or raw disk image file and returns rich OS/boot/WIM metadata.
    public static func inspect(filePath: String) throws -> ISOAnalysis {
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath) else {
            throw ISOInspectorError.fileNotFound(filePath)
        }

        let url = URL(fileURLWithPath: filePath)
        let attrs = try fm.attributesOfItem(atPath: filePath)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Check first 512 bytes for hybrid MBR signature (0x55 0xAA at offset 510)
        var hasHybridMBR = false
        if let fh = FileHandle(forReadingAtPath: filePath) {
            let mbr = fh.readData(ofLength: 512)
            try? fh.close()
            if mbr.count == 512 && mbr[510] == 0x55 && mbr[511] == 0xAA {
                let hasPart = (446..<510).contains { mbr[$0] != 0 }
                let hasCode = (0..<440).contains { mbr[$0] != 0 }
                hasHybridMBR = hasPart && hasCode
            }
        }

        let rawExtensions: Set<String> = ["img", "raw", "bin", "dd"]
        if rawExtensions.contains(ext) {
            let baseName = url.deletingPathExtension().lastPathComponent
            return ISOAnalysis(
                filePath: filePath,
                fileName: fileName,
                fileSizeBytes: fileSize,
                kind: .rawDiskImage,
                volumeName: baseName,
                isWindows11Likely: false,
                windowsArchitecture: nil,
                hasUEFIBootloader: false,
                hasLegacyBIOSBootloader: hasHybridMBR,
                hasHybridMBR: hasHybridMBR,
                installImageRelativePath: nil,
                installImageSizeBytes: 0,
                isInstallImageSolidESD: false,
                largestFileRelativePath: nil,
                largestFileSizeBytes: fileSize
            )
        }

        // Try mounting ISO to inspect contents
        do {
            let mounted = try attachReadOnly(isoPath: filePath)
            defer { detach(mounted) }

            return inspectMountedDirectory(
                mountPoint: mounted.mountPoint,
                filePath: filePath,
                fileName: fileName,
                fileSize: fileSize,
                hasHybridMBR: hasHybridMBR,
                volumeNameOverride: mounted.volumeName
            )
        } catch {
            let baseName = url.deletingPathExtension().lastPathComponent
            return ISOAnalysis(
                filePath: filePath,
                fileName: fileName,
                fileSizeBytes: fileSize,
                kind: hasHybridMBR ? .linuxHybridISO : .rawDiskImage,
                volumeName: baseName,
                isWindows11Likely: false,
                windowsArchitecture: nil,
                hasUEFIBootloader: false,
                hasLegacyBIOSBootloader: hasHybridMBR,
                hasHybridMBR: hasHybridMBR,
                installImageRelativePath: nil,
                installImageSizeBytes: 0,
                isInstallImageSolidESD: false,
                largestFileRelativePath: nil,
                largestFileSizeBytes: fileSize
            )
        }
    }

    /// Inspects an already-mounted ISO directory (also directly unit-testable!).
    public static func inspectMountedDirectory(
        mountPoint: String,
        filePath: String,
        fileName: String,
        fileSize: Int64,
        hasHybridMBR: Bool,
        volumeNameOverride: String? = nil
    ) -> ISOAnalysis {
        let fm = FileManager.default
        let mountURL = URL(fileURLWithPath: mountPoint)
        let volumeName = volumeNameOverride ?? mountURL.lastPathComponent

        var hasBootWim = false
        var hasBootmgr = false
        var hasSetupExe = false
        var hasAppraiserRes = false
        var hasUEFI = false
        var hasLegacyBIOS = false
        var winArch: String?
        var installImgRel: String?
        var installImgSize: Int64 = 0
        var isESD = false
        var largestRel: String?
        var largestSize: Int64 = 0
        var hasLinuxBootMarkers = false

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let enumerator = fm.enumerator(
            at: mountURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) {
            let basePath = mountURL.standardizedFileURL.path
            for case let itemURL as URL in enumerator {
                guard let vals = try? itemURL.resourceValues(forKeys: Set(keys)),
                      vals.isRegularFile == true else { continue }

                let fullPath = itemURL.standardizedFileURL.path
                let relPath = fullPath.hasPrefix(basePath + "/")
                    ? String(fullPath.dropFirst(basePath.count + 1))
                    : itemURL.lastPathComponent
                let lower = relPath.lowercased()
                let size = Int64(vals.fileSize ?? 0)

                if size > largestSize {
                    largestSize = size
                    largestRel = relPath
                }

                if lower == "bootmgr" {
                    hasBootmgr = true
                    hasLegacyBIOS = true
                } else if lower == "setup.exe" {
                    hasSetupExe = true
                } else if lower == "sources/boot.wim" {
                    hasBootWim = true
                } else if lower == "sources/install.wim" {
                    installImgRel = relPath
                    installImgSize = size
                    isESD = false
                } else if lower == "sources/install.esd" && installImgRel == nil {
                    installImgRel = relPath
                    installImgSize = size
                    isESD = true
                } else if lower == "sources/install.swm" && installImgRel == nil {
                    installImgRel = relPath
                    installImgSize = size
                    isESD = false
                } else if lower == "sources/appraiserres.dll" {
                    hasAppraiserRes = true
                } else if lower == "efi/boot/bootx64.efi" {
                    hasUEFI = true
                    winArch = "x64"
                } else if lower == "efi/boot/bootaa64.efi" {
                    hasUEFI = true
                    winArch = winArch ?? "ARM64"
                } else if lower == "efi/boot/bootia32.efi" {
                    hasUEFI = true
                    winArch = winArch ?? "x86"
                } else if lower.hasPrefix("isolinux/") || lower.hasPrefix("syslinux/") || lower.hasPrefix("casper/") || lower.hasPrefix("live/") || lower.hasPrefix("arch/") {
                    hasLinuxBootMarkers = true
                    if lower.contains("isolinux") || lower.contains("syslinux") {
                        hasLegacyBIOS = true
                    }
                }
            }
        }

        let isWindows = (hasBootWim && (installImgRel != nil || hasSetupExe || hasBootmgr))
            || (hasBootmgr && hasSetupExe)

        let lowerName = fileName.lowercased()
        let isExplicitWin10 = lowerName.contains("win10") || lowerName.contains("windows10") || lowerName.contains("windows_10") || lowerName.contains("windows 10")
        let isWin11Likely = isWindows && !isExplicitWin10 && (
            lowerName.contains("win11") ||
            lowerName.contains("windows11") ||
            lowerName.contains("windows_11") ||
            lowerName.contains("windows 11") ||
            lowerName.contains("24h2") ||
            lowerName.contains("23h2") ||
            lowerName.contains("25h2") ||
            hasAppraiserRes
        )

        let kind: DetectedImageKind
        if isWindows {
            kind = .windowsISO
        } else if hasHybridMBR || hasLinuxBootMarkers {
            kind = .linuxHybridISO
        } else {
            kind = .genericISO
        }

        return ISOAnalysis(
            filePath: filePath,
            fileName: fileName,
            fileSizeBytes: fileSize,
            kind: kind,
            volumeName: volumeName,
            isWindows11Likely: isWin11Likely,
            windowsArchitecture: isWindows ? (winArch ?? "x64") : nil,
            hasUEFIBootloader: hasUEFI,
            hasLegacyBIOSBootloader: hasLegacyBIOS || hasHybridMBR,
            hasHybridMBR: hasHybridMBR,
            installImageRelativePath: installImgRel,
            installImageSizeBytes: installImgSize,
            isInstallImageSolidESD: isESD,
            largestFileRelativePath: largestRel,
            largestFileSizeBytes: largestSize
        )
    }

    /// Computes MD5, SHA-1, and SHA-256 in a single streaming pass.
    public static func computeChecksums(
        filePath: String,
        progress: @escaping (Double) -> Void
    ) throws -> ImageChecksums {
        guard let fh = FileHandle(forReadingAtPath: filePath) else {
            throw ISOInspectorError.fileNotFound(filePath)
        }
        defer { try? fh.close() }

        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        let total = max(Int64(1), (attrs[.size] as? Int64) ?? 1)

        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()

        let chunkSize = 4 * 1024 * 1024
        var processed: Int64 = 0
        var lastReport = Date.distantPast

        while true {
            let chunk = autoreleasepool { fh.readData(ofLength: chunkSize) }
            if chunk.isEmpty { break }
            md5.update(data: chunk)
            sha1.update(data: chunk)
            sha256.update(data: chunk)
            processed += Int64(chunk.count)

            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.1 || processed >= total {
                progress(min(1.0, Double(processed) / Double(total)))
                lastReport = now
            }
        }

        func hex(_ bytes: some Sequence<UInt8>) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }

        return ImageChecksums(
            md5: hex(md5.finalize()),
            sha1: hex(sha1.finalize()),
            sha256: hex(sha256.finalize())
        )
    }
}
