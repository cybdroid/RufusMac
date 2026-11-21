import Foundation
import Darwin

public enum FlashEngineError: LocalizedError {
    case cancelled
    case missingISO
    case helperMissing(String)
    case commandFailed(command: String, details: String)
    case fileTooLargeForFAT32(String)
    case insufficientDiskSpace(requiredMB: Int64, availableMB: Int64)
    case ioError(String)
    case mountPointNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Vorgang vom Benutzer abgebrochen."
        case .missingISO:
            return "Keine ISO- oder Image-Datei ausgewählt."
        case .helperMissing(let name):
            return "Hilfsprogramm '\(name)' nicht gefunden. Bitte App vollständig erstellen."
        case .commandFailed(let cmd, let details):
            return "Befehl '\(cmd)' fehlgeschlagen: \(details)"
        case .fileTooLargeForFAT32(let path):
            return "Datei '\(path)' überschreitet das 4-GB-Limit von FAT32. Verwende 'ExFAT + FAT32 Boot (Dual-Partition)' oder den DD-Image-Modus."
        case .insufficientDiskSpace(let req, let avail):
            return "Nicht genügend Speicherplatz auf dem Ziel-Laufwerk: benötigt ~\(req) MB, verfügbar \(avail) MB."
        case .ioError(let msg):
            return "E/A-Fehler: \(msg)"
        case .mountPointNotFound(let dev):
            return "Konnte Einhängepunkt für \(dev) nicht ermitteln."
        }
    }
}

public final class FlashEngine {
    public typealias EventHandler = (FlashProgressEvent) -> Void
    public typealias CancelChecker = () -> Bool

    private let emit: EventHandler
    private let isCancelled: CancelChecker

    public init(emit: @escaping EventHandler, isCancelled: @escaping CancelChecker) {
        self.emit = emit
        self.isCancelled = isCancelled
    }

    private func log(_ msg: String) {
        emit(FlashProgressEvent(kind: .log, message: msg))
    }

    private func stage(_ title: String, fraction: Double, message: String? = nil) {
        emit(FlashProgressEvent(kind: .stage, stage: title, fraction: fraction, message: message ?? title))
    }

    private func progress(_ title: String, fraction: Double, speedMBps: Double? = nil, message: String) {
        emit(FlashProgressEvent(
            kind: .progress,
            stage: title,
            fraction: min(1.0, max(0.0, fraction)),
            speedMBps: speedMBps,
            message: message
        ))
    }

    private func checkCancelled() throws {
        if isCancelled() {
            throw FlashEngineError.cancelled
        }
    }

    // MARK: - Main Entry Point

    public func execute(config: FlashJobConfig) throws {
        let diskId = DiskDiscovery.wholeDiskIdentifier(from: config.targetDeviceIdentifier)
        let blockDev = "/dev/\(diskId)"
        let rawDev = "/dev/r\(diskId)"

        stage("Sicherheitsprüfung…", fraction: 0.01)
        try DiskDiscovery.validateSafeTarget(deviceIdentifier: diskId, allowDiskImage: config.allowDiskImageTarget)
        log("Ziel-Laufwerk verifiziert: \(blockDev) (\(config.partitionScheme.rawValue) / \(config.fileSystem.rawValue))")

        try checkCancelled()

        // Get disk total size in bytes
        let diskSizeBytes = try queryDiskSizeBytes(deviceNode: blockDev)
        log("Laufwerksgröße: \(ByteCountFormatter.string(fromByteCount: diskSizeBytes, countStyle: .decimal))")

        // Route by mode
        switch config.bootMode {
        case .nonBootable:
            try executeNonBootableFormat(config: config, blockDev: blockDev, rawDev: rawDev, diskSizeBytes: diskSizeBytes)

        case .isoOrImage:
            guard let isoPath = config.isoPath, !isoPath.isEmpty else {
                throw FlashEngineError.missingISO
            }
            guard FileManager.default.fileExists(atPath: isoPath) else {
                throw ISOInspectorError.fileNotFound(isoPath)
            }

            if config.writeMode == .ddRawImage {
                try executeDDRawWrite(isoPath: isoPath, config: config, blockDev: blockDev, rawDev: rawDev, diskSizeBytes: diskSizeBytes)
            } else {
                try executeISOFileCopy(isoPath: isoPath, config: config, blockDev: blockDev, rawDev: rawDev, diskSizeBytes: diskSizeBytes)
            }
        }

        // Flush kernel buffers
        stage("Synchronisiere Dateisystem-Cache…", fraction: 0.98)
        Darwin.sync()
        Thread.sleep(forTimeInterval: 0.4)

        if config.autoEjectAfterFlash {
            stage("Werfe Laufwerk sicher aus…", fraction: 0.99)
            _ = try? runCommand("/usr/sbin/diskutil", arguments: ["eject", blockDev])
            log("Laufwerk \(blockDev) sicher ausgeworfen.")
        }

        emit(FlashProgressEvent(kind: .completed, stage: "Fertig", fraction: 1.0, message: "Bootfähiges Medium erfolgreich erstellt!"))
    }

    // MARK: - Mode 1: Non-Bootable Format

    private func executeNonBootableFormat(
        config: FlashJobConfig,
        blockDev: String,
        rawDev: String,
        diskSizeBytes: Int64
    ) throws {
        stage("Hänge Partitionen aus…", fraction: 0.10)
        try unmountDisk(blockDev)

        if config.wipePartitionTable {
            stage("Lösche alte Partitionstabelle…", fraction: 0.20)
            try wipeDiskHeaders(rawDev: rawDev, diskSizeBytes: diskSizeBytes)
        }

        try checkCancelled()

        let label = VolumeLabelSanitizer.sanitize(config.volumeLabel, for: config.fileSystem)
        let schemeArg = (config.fileSystem == .apfs) ? "GPT" : config.partitionScheme.rawValue

        stage("Erstelle \(schemeArg)-Partitionstabelle & \(config.fileSystem.rawValue)…", fraction: 0.45)

        switch config.fileSystem {
        case .fat32:
            try runCommand("/usr/sbin/diskutil", arguments: ["partitionDisk", blockDev, schemeArg, "MS-DOS", label, "100%"])
            try unmountDisk(blockDev)
            let slice1 = "\(blockDev)s1"
            try formatFAT32(sliceDevice: slice1, label: label, clusterSize: config.clusterSize)
            try mountSlice(slice1)

        case .exfat, .dualFat32ExFAT:
            try runCommand("/usr/sbin/diskutil", arguments: ["partitionDisk", blockDev, schemeArg, "ExFAT", label, "100%"])
            if config.clusterSize != .automatic {
                try unmountDisk(blockDev)
                let slice1 = "\(blockDev)s1"
                try formatExFAT(sliceDevice: slice1, label: label, clusterSize: config.clusterSize)
                try mountSlice(slice1)
            }

        case .apfs:
            try runCommand("/usr/sbin/diskutil", arguments: ["eraseDisk", "APFS", label, "GPT", blockDev])

        case .hfsPlus:
            try runCommand("/usr/sbin/diskutil", arguments: ["eraseDisk", "JHFS+", label, schemeArg, blockDev])
        }

        log("Formatierung abgeschlossen (\(schemeArg) / \(config.fileSystem.rawValue), Label: \(label)).")
        progress("Formatierung abgeschlossen", fraction: 0.95, message: "Formatierung erfolgreich.")
    }

    // MARK: - Mode 2: DD Raw Image Write

    private func executeDDRawWrite(
        isoPath: String,
        config: FlashJobConfig,
        blockDev: String,
        rawDev: String,
        diskSizeBytes: Int64
    ) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: isoPath)
        let imageSize = (attrs[.size] as? Int64) ?? 0
        if imageSize > diskSizeBytes {
            throw FlashEngineError.insufficientDiskSpace(
                requiredMB: imageSize / (1024 * 1024),
                availableMB: diskSizeBytes / (1024 * 1024)
            )
        }

        stage("Hänge Ziel-Laufwerk aus…", fraction: 0.03)
        try unmountDisk(blockDev)
        try checkCancelled()

        stage("Schreibe Raw-Image (DD-Modus)…", fraction: 0.05)
        log("DD-Schreibvorgang: \(isoPath) (\(ByteCountFormatter.string(fromByteCount: imageSize, countStyle: .decimal))) -> \(rawDev)")

        let srcFD = open(isoPath, O_RDONLY)
        guard srcFD >= 0 else {
            throw FlashEngineError.ioError("Kann Quelldatei nicht öffnen: \(String(cString: strerror(errno)))")
        }
        defer { close(srcFD) }

        let dstFD = open(rawDev, O_WRONLY)
        guard dstFD >= 0 else {
            throw FlashEngineError.ioError("Kann Zielgerät \(rawDev) nicht öffnen: \(String(cString: strerror(errno)))")
        }
        defer { close(dstFD) }

        let bufferSize = 4 * 1024 * 1024 // 4 MB aligned
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer { buffer.deallocate() }

        var writtenTotal: Int64 = 0
        let startTime = Date()
        var lastEmit = Date.distantPast

        while true {
            try checkCancelled()

            let bytesRead = read(srcFD, buffer, bufferSize)
            if bytesRead < 0 {
                throw FlashEngineError.ioError("Lesefehler: \(String(cString: strerror(errno)))")
            }
            if bytesRead == 0 {
                break
            }

            // Raw devices on macOS require 512-byte sector alignment
            var bytesToWrite = bytesRead
            let remainder = bytesToWrite % 512
            if remainder != 0 {
                let pad = 512 - remainder
                memset(buffer.advanced(by: bytesToWrite), 0, pad)
                bytesToWrite += pad
            }

            var offset = 0
            while offset < bytesToWrite {
                let n = write(dstFD, buffer.advanced(by: offset), bytesToWrite - offset)
                if n < 0 {
                    throw FlashEngineError.ioError("Schreibfehler auf \(rawDev): \(String(cString: strerror(errno)))")
                }
                offset += n
            }

            writtenTotal += Int64(bytesRead)
            let now = Date()
            if now.timeIntervalSince(lastEmit) >= 0.15 || writtenTotal >= imageSize {
                let elapsed = max(0.01, now.timeIntervalSince(startTime))
                let speed = Double(writtenTotal) / (1024.0 * 1024.0) / elapsed
                let frac = imageSize > 0 ? (0.05 + 0.90 * min(1.0, Double(writtenTotal) / Double(imageSize))) : 0.5
                let pct = Int(min(100, (Double(writtenTotal) / Double(max(1, imageSize))) * 100))
                progress(
                    "Schreibe Raw-Image (\(pct)%)…",
                    fraction: frac,
                    speedMBps: speed,
                    message: String(format: "%d%% geschrieben (%.1f MB/s)", pct, speed)
                )
                lastEmit = now
            }
        }

        _ = fsync(dstFD)
        log("DD-Image vollständig auf \(rawDev) geschrieben.")
    }

    // MARK: - Mode 3: Bootable ISO File Copy (Windows & Linux)

    private func executeISOFileCopy(
        isoPath: String,
        config: FlashJobConfig,
        blockDev: String,
        rawDev: String,
        diskSizeBytes: Int64
    ) throws {
        stage("Hänge ISO-Abbild ein…", fraction: 0.03)
        let mountedISO = try ISOInspector.attachReadOnly(isoPath: isoPath)
        defer {
            ISOInspector.detach(deviceNode: mountedISO.deviceNode, tempMountDir: mountedISO.tempMountDir)
            log("ISO-Abbild ausgehängt.")
        }
        log("ISO eingehängt unter: \(mountedISO.mountPoint)")

        try checkCancelled()

        // Enumerate all files in the mounted ISO
        let isoEntries = try enumerateFiles(in: mountedISO.mountPoint)
        let totalISOBytes = isoEntries.reduce(Int64(0)) { $0 + $1.size }
        log("ISO enthält \(isoEntries.count) Dateien (\(ByteCountFormatter.string(fromByteCount: totalISOBytes, countStyle: .decimal))).")

        if totalISOBytes + 64 * 1024 * 1024 > diskSizeBytes {
            throw FlashEngineError.insufficientDiskSpace(
                requiredMB: (totalISOBytes / (1024 * 1024)) + 64,
                availableMB: diskSizeBytes / (1024 * 1024)
            )
        }

        // Identify oversized files (>= 4 GiB - 1)
        let fat32Limit = ISOAnalysis.fat32MaxFileSize
        let largeFiles = isoEntries.filter { $0.size >= fat32Limit }
        let installWimEntry = isoEntries.first { $0.relativePath.lowercased() == "sources/install.wim" }
        let needsWimSplit = (config.fileSystem == .fat32)
            && (installWimEntry != nil)
            && ((installWimEntry?.size ?? 0) >= fat32Limit)

        if config.fileSystem == .fat32 {
            for lf in largeFiles {
                if lf.relativePath.lowercased() != "sources/install.wim" {
                    throw FlashEngineError.fileTooLargeForFAT32(lf.relativePath)
                }
            }
            if needsWimSplit {
                _ = try resolveHelper(named: "wimlib-imagex", helpersDir: config.helpersDirectory)
                log("Große install.wim erkannt (\(ByteCountFormatter.string(fromByteCount: installWimEntry!.size, countStyle: .decimal))) -> wimlib-imagex Auto-Split aktiviert.")
            }
        }

        // Verify ms-sys is available if MBR is chosen
        if config.partitionScheme == .mbr {
            _ = try resolveHelper(named: "ms-sys", helpersDir: config.helpersDirectory)
        }

        // Step 1: Unmount & Wipe
        stage("Hänge Ziel-Laufwerk aus…", fraction: 0.06)
        try unmountDisk(blockDev)

        if config.wipePartitionTable {
            stage("Lösche alte Partitionstabelle & UDF-Reste…", fraction: 0.09)
            try wipeDiskHeaders(rawDev: rawDev, diskSizeBytes: diskSizeBytes)
        }
        try checkCancelled()

        // Step 2: Partition & Copy according to FileSystemType
        if config.fileSystem == .dualFat32ExFAT {
            try executeDualPartitionCopy(
                isoMount: mountedISO.mountPoint,
                isoEntries: isoEntries,
                config: config,
                blockDev: blockDev,
                diskSizeBytes: diskSizeBytes
            )
        } else {
            try executeSinglePartitionCopy(
                isoMount: mountedISO.mountPoint,
                isoEntries: isoEntries,
                installWimEntry: needsWimSplit ? installWimEntry : nil,
                config: config,
                blockDev: blockDev
            )
        }
    }

    // MARK: - Single Partition ISO Copy (FAT32 + optional WIM Split, or ExFAT)

    private func executeSinglePartitionCopy(
        isoMount: String,
        isoEntries: [ISOFileEntry],
        installWimEntry: ISOFileEntry?,
        config: FlashJobConfig,
        blockDev: String
    ) throws {
        let label = VolumeLabelSanitizer.sanitize(config.volumeLabel, for: config.fileSystem)
        let scheme = config.partitionScheme.rawValue
        let slice1 = "\(blockDev)s1"

        stage("Erstelle \(scheme)-Partitionstabelle (\(config.fileSystem.rawValue))…", fraction: 0.12)
        if config.fileSystem == .fat32 {
            try runCommand("/usr/sbin/diskutil", arguments: ["partitionDisk", blockDev, scheme, "MS-DOS", label, "100%"])
            try unmountDisk(blockDev)
            stage("Formatiere FAT32 (\(label))…", fraction: 0.16)
            try formatFAT32(sliceDevice: slice1, label: label, clusterSize: config.clusterSize)
            try mountSlice(slice1)
        } else {
            try runCommand("/usr/sbin/diskutil", arguments: ["partitionDisk", blockDev, scheme, "ExFAT", label, "100%"])
            if config.clusterSize != .automatic {
                try unmountDisk(blockDev)
                stage("Formatiere ExFAT (\(label))…", fraction: 0.16)
                try formatExFAT(sliceDevice: slice1, label: label, clusterSize: config.clusterSize)
                try mountSlice(slice1)
            }
        }

        let targetMount = try waitForMountPoint(sliceDevice: slice1)
        log("Zielpartition eingehängt unter: \(targetMount)")
        disableSpotlightOnVolume(targetMount)

        // Copy ISO files (skip install.wim if splitting)
        let excludedRel = installWimEntry?.relativePath.lowercased()
        let filesToCopy = isoEntries.filter { $0.relativePath.lowercased() != excludedRel }
        let copyEndFraction = (installWimEntry != nil) ? 0.55 : 0.90

        stage("Kopiere Installationsdateien…", fraction: 0.18)
        try copyEntries(
            filesToCopy,
            fromRoot: isoMount,
            toRoot: targetMount,
            progressStart: 0.18,
            progressEnd: copyEndFraction,
            stageTitle: "Kopiere Dateien…"
        )

        // Split install.wim if needed
        if let wim = installWimEntry {
            try checkCancelled()
            let srcWim = (isoMount as NSString).appendingPathComponent(wim.relativePath)
            let dstSourcesDir = (targetMount as NSString).appendingPathComponent("sources")
            try FileManager.default.createDirectory(atPath: dstSourcesDir, withIntermediateDirectories: true)
            let dstSwm = (dstSourcesDir as NSString).appendingPathComponent("install.swm")

            stage("Teile install.wim für FAT32 (wimlib-imagex)…", fraction: 0.56)
            log("Starte wimlib-imagex split (3800 MB Teile): \(srcWim) -> \(dstSwm)")
            try runWimSplit(
                helpersDir: config.helpersDirectory,
                sourceWim: srcWim,
                destSwm: dstSwm,
                partSizeMB: 3800,
                progressStart: 0.56,
                progressEnd: 0.91
            )
            log("install.wim erfolgreich in .swm-Dateien aufgeteilt.")
        }

        // Optional Windows autounattend.xml
        try writeAutoUnattendIfNeeded(config: config, targetMounts: [targetMount])

        Darwin.sync()

        // Legacy BIOS MBR + NT6 VBR Boot Sector
        if config.partitionScheme == .mbr {
            stage("Schreibe Windows NT6 MBR & VBR Bootsektor…", fraction: 0.93)
            try writeLegacyBIOSBootSectors(
                blockDev: blockDev,
                bootSlice: slice1,
                bootFS: config.fileSystem == .exfat ? .exfat : .fat32,
                helpersDir: config.helpersDirectory
            )
            if !config.autoEjectAfterFlash {
                try? mountSlice(slice1)
            }
        }
    }

    // MARK: - Dual Partition ISO Copy (FAT32 Boot + ExFAT Data, No WIM Split!)

    private func executeDualPartitionCopy(
        isoMount: String,
        isoEntries: [ISOFileEntry],
        config: FlashJobConfig,
        blockDev: String,
        diskSizeBytes: Int64
    ) throws {
        let dataLabel = VolumeLabelSanitizer.sanitize(config.volumeLabel, for: .exfat)
        let bootLabel = "WIN_BOOT"
        let scheme = config.partitionScheme.rawValue
        let fat32Limit = ISOAnalysis.fat32MaxFileSize

        // Partition 1 (FAT32 Boot) gets everything except sources/install.wim, sources/install.esd, and any >=4GB file
        let isDataOnlyFile: (ISOFileEntry) -> Bool = { entry in
            let lower = entry.relativePath.lowercased()
            return lower == "sources/install.wim" || lower == "sources/install.esd" || entry.size >= fat32Limit
        }

        let bootFiles = isoEntries.filter { !isDataOnlyFile($0) }
        let dataFiles = isoEntries.filter { isDataOnlyFile($0) }

        let bootFilesBytes = bootFiles.reduce(Int64(0)) { $0 + $1.size }
        let dataFilesBytes = dataFiles.reduce(Int64(0)) { $0 + $1.size }

        // Size Partition 1 cleanly: bootFiles + 256 MB headroom, min 128 MB (for valid FAT32)
        let bootPartMB = max(Int64(128), (bootFilesBytes / (1024 * 1024)) + 256)
        let neededDataMB = (dataFilesBytes / (1024 * 1024)) + 128
        let diskMB = diskSizeBytes / (1024 * 1024)

        if bootPartMB + neededDataMB > diskMB {
            throw FlashEngineError.insufficientDiskSpace(requiredMB: bootPartMB + neededDataMB, availableMB: diskMB)
        }

        let slice1 = "\(blockDev)s1"
        let slice2 = "\(blockDev)s2"

        stage("Erstelle Dual-Partition (\(scheme): \(bootPartMB) MB FAT32 Boot + ExFAT Daten)…", fraction: 0.12)
        log("Dual-Partition-Layout: \(slice1) = FAT32 (\(bootPartMB) MB, Boot), \(slice2) = ExFAT (Rest, Daten)")

        try runCommand("/usr/sbin/diskutil", arguments: [
            "partitionDisk", blockDev, scheme,
            "MS-DOS", bootLabel, "\(bootPartMB)M",
            "ExFAT", dataLabel, "R"
        ])

        try unmountDisk(blockDev)

        stage("Formatiere Boot-Partition (FAT32) & Daten-Partition (ExFAT)…", fraction: 0.16)
        try formatFAT32(sliceDevice: slice1, label: bootLabel, clusterSize: .automatic)
        if config.clusterSize != .automatic {
            try formatExFAT(sliceDevice: slice2, label: dataLabel, clusterSize: config.clusterSize)
        }

        try mountSlice(slice1)
        try mountSlice(slice2)

        let bootMount = try waitForMountPoint(sliceDevice: slice1)
        let dataMount = try waitForMountPoint(sliceDevice: slice2)
        log("Boot-Partition: \(bootMount) | Daten-Partition: \(dataMount)")

        disableSpotlightOnVolume(bootMount)
        disableSpotlightOnVolume(dataMount)

        // Copy boot files to Partition 1 (FAT32)
        stage("Kopiere Boot-Dateien auf FAT32-Partition…", fraction: 0.18)
        let bootRatio = max(0.15, min(0.55, Double(bootFilesBytes) / Double(max(1, bootFilesBytes + dataFilesBytes))))
        let bootEndFrac = 0.18 + 0.72 * bootRatio

        try copyEntries(
            bootFiles,
            fromRoot: isoMount,
            toRoot: bootMount,
            progressStart: 0.18,
            progressEnd: bootEndFrac,
            stageTitle: "Kopiere Boot-Dateien (FAT32)…"
        )

        // Copy large install.wim/esd (plus setup.exe & autorun.inf for WinPE discovery) to Partition 2 (ExFAT)
        var partition2Entries = dataFiles
        for extra in bootFiles {
            let lower = extra.relativePath.lowercased()
            if lower == "setup.exe" || lower == "autorun.inf" || lower == "sources/ei.cfg" || lower == "sources/pid.txt" {
                partition2Entries.append(extra)
            }
        }

        stage("Kopiere Windows-Installationsimage auf ExFAT-Partition…", fraction: bootEndFrac)
        try copyEntries(
            partition2Entries,
            fromRoot: isoMount,
            toRoot: dataMount,
            progressStart: bootEndFrac,
            progressEnd: 0.91,
            stageTitle: "Kopiere install.wim (ExFAT)…"
        )

        // Write autounattend.xml to both partitions so Windows Setup finds it immediately
        try writeAutoUnattendIfNeeded(config: config, targetMounts: [bootMount, dataMount])

        Darwin.sync()

        // Legacy BIOS MBR + FAT32 NT6 VBR on Partition 1
        if config.partitionScheme == .mbr {
            stage("Schreibe Windows NT6 MBR & FAT32 VBR auf Boot-Partition…", fraction: 0.93)
            try writeLegacyBIOSBootSectors(
                blockDev: blockDev,
                bootSlice: slice1,
                bootFS: .fat32,
                helpersDir: config.helpersDirectory
            )
            if !config.autoEjectAfterFlash {
                try? mountSlice(slice1)
                try? mountSlice(slice2)
            }
        }
    }

    // MARK: - Legacy BIOS Boot Sectors (ms-sys + Active Flag 0x80)

    private func writeLegacyBIOSBootSectors(
        blockDev: String,
        bootSlice: String,
        bootFS: FileSystemType,
        helpersDir: String?
    ) throws {
        let msSysPath = try resolveHelper(named: "ms-sys", helpersDir: helpersDir)
        try unmountDisk(blockDev)

        // Generate random non-zero Windows Disk Signature (required by Windows BOOTMGR/BCD on Legacy BIOS)
        let sigValue = UInt32.random(in: 0x10000001...0xFFFFFFFE)
        let sigHex = String(format: "%08X", sigValue)

        log("Schreibe Windows NT6/10/11 MBR + Disk-Signatur 0x\(sigHex) auf \(blockDev)…")
        try runCommand(msSysPath, arguments: ["-7", "-S", sigHex, "-f", blockDev])

        if bootFS == .exfat {
            log("Schreibe Windows NT6 ExFAT BOOTMGR-VBR auf \(bootSlice)…")
            try runCommand(msSysPath, arguments: ["-x", "-p", "-f", bootSlice])
        } else {
            log("Schreibe Windows NT6 FAT32 BOOTMGR-VBR auf \(bootSlice)…")
            try runCommand(msSysPath, arguments: ["-8", "-p", "-f", bootSlice])
        }

        // Mark Partition 1 Active/Bootable (0x80 at MBR offset 0x1BE = 446)
        log("Setze Aktiv/Boot-Flag (0x80) für Partition 1 im MBR…")
        try setMBRPartition1Active(blockDev: blockDev)
        Darwin.sync()
        log("Legacy BIOS MBR + VBR Bootsektoren erfolgreich geschrieben und verifiziert.")
    }

    /// Reads sector 0 (512 bytes) of blockDev, sets byte 446 (partition 1 boot indicator) to 0x80,
    /// clears boot indicator on partitions 2..4, and writes sector 0 back cleanly.
    private func setMBRPartition1Active(blockDev: String) throws {
        let fd = open(blockDev, O_RDWR)
        guard fd >= 0 else {
            throw FlashEngineError.ioError("Kann \(blockDev) zum Setzen des Active-Flags nicht öffnen: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        var sector = [UInt8](repeating: 0, count: 512)
        let readN = pread(fd, &sector, 512, 0)
        guard readN == 512 else {
            throw FlashEngineError.ioError("Konnte MBR-Sektor 0 nicht lesen.")
        }
        guard sector[510] == 0x55 && sector[511] == 0xAA else {
            throw FlashEngineError.ioError("Ungültige MBR-Signatur beim Setzen des Active-Flags.")
        }

        sector[446] = 0x80       // Partition 1 active
        sector[446 + 16] = 0x00  // Partition 2 inactive
        sector[446 + 32] = 0x00  // Partition 3 inactive
        sector[446 + 48] = 0x00  // Partition 4 inactive

        let writeN = pwrite(fd, &sector, 512, 0)
        guard writeN == 512 else {
            throw FlashEngineError.ioError("Konnte MBR-Active-Flag nicht schreiben: \(String(cString: strerror(errno)))")
        }
        _ = fsync(fd)
    }

    // MARK: - wimlib-imagex Split with Live Progress

    private func runWimSplit(
        helpersDir: String?,
        sourceWim: String,
        destSwm: String,
        partSizeMB: Int,
        progressStart: Double,
        progressEnd: Double
    ) throws {
        let wimlibPath = try resolveHelper(named: "wimlib-imagex", helpersDir: helpersDir)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: wimlibPath)
        proc.arguments = ["split", sourceWim, destSwm, "\(partSizeMB)"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        let startTime = Date()
        var accumulatedError = ""
        let errorLock = NSLock()

        // Capture stderr
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                errorLock.lock()
                accumulatedError += str
                errorLock.unlock()
            }
        }

        // Parse live percentage from stdout (`Splitting WIM: 1520 MiB of 5432 MiB (27%) written`)
        let regex = try? NSRegularExpression(pattern: #"\((\d+)%\)"#)
        let mibRegex = try? NSRegularExpression(pattern: #"(\d+)\s*MiB\s+of\s+(\d+)\s*MiB"#)

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8), let self = self else { return }
            let segments = str.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            for seg in segments {
                let trimmed = seg.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let ns = trimmed as NSString
                if let match = regex?.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
                   let pct = Double(ns.substring(with: match.range(at: 1))) {
                    var speed: Double?
                    if let mMatch = mibRegex?.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
                       let curMiB = Double(ns.substring(with: mMatch.range(at: 1))) {
                        let elapsed = max(0.2, Date().timeIntervalSince(startTime))
                        speed = curMiB / elapsed
                    }
                    let frac = progressStart + (progressEnd - progressStart) * (pct / 100.0)
                    self.progress(
                        "Teile install.wim (\(Int(pct))%)…",
                        fraction: frac,
                        speedMBps: speed,
                        message: trimmed
                    )
                }
            }
        }

        // Wait while monitoring cancellation every 150ms
        while proc.isRunning {
            if isCancelled() {
                proc.terminate()
                Thread.sleep(forTimeInterval: 0.3)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                throw FlashEngineError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.15)
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        if proc.terminationStatus != 0 {
            errorLock.lock()
            let errMsg = accumulatedError.trimmingCharacters(in: .whitespacesAndNewlines)
            errorLock.unlock()
            throw FlashEngineError.commandFailed(command: "wimlib-imagex split", details: errMsg.isEmpty ? "Exit \(proc.terminationStatus)" : errMsg)
        }
    }

    // MARK: - Streaming File Copy with Progress & Cancel Support

    private struct ISOFileEntry {
        let relativePath: String
        let size: Int64
    }

    private func enumerateFiles(in rootPath: String) throws -> [ISOFileEntry] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        let basePath = rootURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]

        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            throw FlashEngineError.ioError("Kann Verzeichnis \(rootPath) nicht durchsuchen.")
        }

        var result: [ISOFileEntry] = []
        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  vals.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            let rel = full.hasPrefix(basePath + "/") ? String(full.dropFirst(basePath.count + 1)) : url.lastPathComponent
            result.append(ISOFileEntry(relativePath: rel, size: Int64(vals.fileSize ?? 0)))
        }
        return result
    }

    private func copyEntries(
        _ entries: [ISOFileEntry],
        fromRoot srcRoot: String,
        toRoot dstRoot: String,
        progressStart: Double,
        progressEnd: Double,
        stageTitle: String
    ) throws {
        let fm = FileManager.default
        let totalBytes = max(Int64(1), entries.reduce(Int64(0)) { $0 + $1.size })
        var copiedBytes: Int64 = 0
        let startTime = Date()
        var lastEmit = Date.distantPast
        let chunkSize = 2 * 1024 * 1024 // 2 MB buffer
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 4096)
        defer { buf.deallocate() }

        var createdDirs = Set<String>()

        for entry in entries {
            try checkCancelled()

            let srcPath = (srcRoot as NSString).appendingPathComponent(entry.relativePath)
            let dstPath = (dstRoot as NSString).appendingPathComponent(entry.relativePath)
            let dstDir = (dstPath as NSString).deletingLastPathComponent

            if !createdDirs.contains(dstDir) {
                try fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
                createdDirs.insert(dstDir)
            }

            let inFD = open(srcPath, O_RDONLY)
            guard inFD >= 0 else {
                throw FlashEngineError.ioError("Kann \(entry.relativePath) nicht lesen: \(String(cString: strerror(errno)))")
            }
            defer { close(inFD) }

            let outFD = open(dstPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard outFD >= 0 else {
                throw FlashEngineError.ioError("Kann \(entry.relativePath) nicht schreiben: \(String(cString: strerror(errno)))")
            }
            defer { close(outFD) }

            while true {
                try checkCancelled()
                let nRead = read(inFD, buf, chunkSize)
                if nRead < 0 {
                    throw FlashEngineError.ioError("Lesefehler bei \(entry.relativePath): \(String(cString: strerror(errno)))")
                }
                if nRead == 0 { break }

                var written = 0
                while written < nRead {
                    let nWrite = write(outFD, buf.advanced(by: written), nRead - written)
                    if nWrite < 0 {
                        throw FlashEngineError.ioError("Schreibfehler bei \(entry.relativePath): \(String(cString: strerror(errno)))")
                    }
                    written += nWrite
                }

                copiedBytes += Int64(nRead)
                let now = Date()
                if now.timeIntervalSince(lastEmit) >= 0.15 {
                    let elapsed = max(0.01, now.timeIntervalSince(startTime))
                    let speed = Double(copiedBytes) / (1024.0 * 1024.0) / elapsed
                    let ratio = min(1.0, Double(copiedBytes) / Double(totalBytes))
                    let frac = progressStart + (progressEnd - progressStart) * ratio
                    progress(
                        "\(stageTitle) (\(Int(ratio * 100))%)",
                        fraction: frac,
                        speedMBps: speed,
                        message: entry.relativePath
                    )
                    lastEmit = now
                }
            }
        }

        let elapsed = max(0.01, Date().timeIntervalSince(startTime))
        let avgSpeed = Double(copiedBytes) / (1024.0 * 1024.0) / elapsed
        progress(stageTitle, fraction: progressEnd, speedMBps: avgSpeed, message: String(format: "%d Dateien kopiert (%.1f MB/s)", entries.count, avgSpeed))
    }

    // MARK: - Windows autounattend.xml

    private func writeAutoUnattendIfNeeded(config: FlashJobConfig, targetMounts: [String]) throws {
        guard config.isoKind == .windowsISO || config.windowsOptions.isAnyEnabled else { return }
        guard let xml = AutoUnattendGenerator.generate(options: config.windowsOptions) else { return }

        for mount in targetMounts {
            let dest = (mount as NSString).appendingPathComponent("autounattend.xml")
            try xml.write(toFile: dest, atomically: true, encoding: .utf8)
            log("Windows-Anpassung geschrieben: \(dest)")
        }
    }

    // MARK: - Low-Level Disk Helpers

    private func wipeDiskHeaders(rawDev: String, diskSizeBytes: Int64) throws {
        let fd = open(rawDev, O_WRONLY)
        guard fd >= 0 else {
            throw FlashEngineError.ioError("Kann \(rawDev) zum Löschen nicht öffnen: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }

        let zeroChunkSize = 1024 * 1024 // 1 MB
        let zeros = UnsafeMutableRawPointer.allocate(byteCount: zeroChunkSize, alignment: 4096)
        defer { zeros.deallocate() }
        memset(zeros, 0, zeroChunkSize)

        // Wipe first 4 MB (clears MBR, GPT header, and Balena Etcher UDF headers)
        let headMB = min(4, max(1, Int(diskSizeBytes / Int64(zeroChunkSize))))
        for i in 0..<headMB {
            _ = pwrite(fd, zeros, zeroChunkSize, off_t(i * zeroChunkSize))
        }

        // Wipe last 1 MB (clears backup GPT table at end of disk)
        if diskSizeBytes > Int64(zeroChunkSize * 2) {
            let tailOffset = ((diskSizeBytes - Int64(zeroChunkSize)) / 512) * 512
            _ = pwrite(fd, zeros, zeroChunkSize, off_t(tailOffset))
        }
        _ = fsync(fd)
        log("Anfangs- und Endsektoren (MBR/GPT/UDF-Reste) erfolgreich gelöscht.")
    }

    private func formatFAT32(sliceDevice: String, label: String, clusterSize: ClusterSize) throws {
        var args = ["-F", "32", "-v", label]
        if clusterSize != .automatic {
            args.append(contentsOf: ["-b", "\(clusterSize.rawValue)"])
        }
        args.append(sliceDevice)
        try runCommand("/sbin/newfs_msdos", arguments: args)
    }

    private func formatExFAT(sliceDevice: String, label: String, clusterSize: ClusterSize) throws {
        var args = ["-v", label]
        if clusterSize != .automatic {
            args.append(contentsOf: ["-b", "\(clusterSize.rawValue)"])
        }
        args.append(sliceDevice)
        try runCommand("/sbin/newfs_exfat", arguments: args)
    }

    private func unmountDisk(_ blockDev: String) throws {
        for attempt in 1...3 {
            do {
                try runCommand("/usr/sbin/diskutil", arguments: ["unmountDisk", "force", blockDev])
                return
            } catch {
                if attempt == 3 { throw error }
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
    }

    private func mountSlice(_ sliceDevice: String) throws {
        for attempt in 1...4 {
            do {
                try runCommand("/usr/sbin/diskutil", arguments: ["mount", sliceDevice])
                return
            } catch {
                if attempt == 4 { throw error }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private func waitForMountPoint(sliceDevice: String) throws -> String {
        for _ in 1...15 {
            if let data = try? DiskDiscovery.runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", sliceDevice]),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let mp = dict["MountPoint"] as? String, !mp.isEmpty {
                return mp
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw FlashEngineError.mountPointNotFound(sliceDevice)
    }

    private func queryDiskSizeBytes(deviceNode: String) throws -> Int64 {
        let data = try DiskDiscovery.runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", deviceNode])
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let size = (dict["IOKitSize"] as? Int64) ?? (dict["Size"] as? Int64) ?? (dict["TotalSize"] as? Int64) else {
            throw FlashEngineError.ioError("Konnte Laufwerksgröße von \(deviceNode) nicht ermitteln.")
        }
        return size
    }

    private func disableSpotlightOnVolume(_ mountPoint: String) {
        let marker = (mountPoint as NSString).appendingPathComponent(".metadata_never_index")
        FileManager.default.createFile(atPath: marker, contents: Data())
    }

    public func resolveHelper(named name: String, helpersDir: String?) throws -> String {
        var candidates: [String] = []
        if let dir = helpersDir {
            candidates.append((dir as NSString).appendingPathComponent(name))
        }
        if let execPath = Bundle.main.executablePath {
            let execDir = (execPath as NSString).deletingLastPathComponent
            candidates.append((execDir as NSString).appendingPathComponent(name))
            candidates.append(((execDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Helpers/\(name)"))
        }
        let bundleHelpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path
        candidates.append(bundleHelpers)
        candidates.append("/usr/local/bin/\(name)")
        candidates.append("/opt/homebrew/bin/\(name)")

        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw FlashEngineError.helperMissing(name)
    }

    @discardableResult
    private func runCommand(_ executable: String, arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            let msg = errStr.isEmpty ? outStr : errStr
            throw FlashEngineError.commandFailed(
                command: "\(URL(fileURLWithPath: executable).lastPathComponent) \(arguments.joined(separator: " "))",
                details: msg.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return outStr
    }
}
