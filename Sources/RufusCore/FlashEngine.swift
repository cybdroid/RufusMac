import Foundation
import Darwin

public enum FlashEngineError: LocalizedError {
    case cancelled
    case missingISO
    case helperMissing(String)
    case commandFailed(command: String, details: String)
    case fileTooLargeForFAT32(String)
    case insufficientDiskSpace(requiredMB: Int64, availableMB: Int64)
    case fullDiskAccessRequired(String)
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
        case .fullDiskAccessRequired(let reason):
            return "macOS blockiert den Roh-Zugriff auf das Laufwerk (\(reason)). Bitte erlaube 'RufusMac' unter Systemeinstellungen → Datenschutz & Sicherheit → Festplattenvollzugriff (oder nutze GPT / UEFI, das ohne Festplattenvollzugriff funktioniert)."
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

    /// Returns true ONLY if the job must open raw `/dev/diskN` or `/dev/rdiskN` block devices directly
    /// (DD raw image write, custom cluster size via newfs_*, or Legacy BIOS MBR boot sectors via ms-sys).
    /// Standard GPT (UEFI) FAT32 Auto-WIM-Split, Dual-Partition ExFAT, and Format-Only run 100% via Apple's
    /// `diskutil` (`diskmanagementd`) WITHOUT root privileges or Full Disk Access!
    public static func requiresRootForWholeJob(_ config: FlashJobConfig) -> Bool {
        if config.onlyWriteMBRBootSectors { return true }
        if config.bootMode == .isoOrImage && config.writeMode == .ddRawImage { return true }
        if config.clusterSize != .automatic && config.fileSystem != .apfs && config.fileSystem != .hfsPlus { return true }
        return false
    }

    /// Returns true if a bootable MBR job needs the quick Phase-2 privileged MBR/VBR boot-sector stamp after file copy.
    public static func needsMBRBootSectorPhase2(_ config: FlashJobConfig) -> Bool {
        config.bootMode == .isoOrImage
            && config.writeMode == .isoFileCopy
            && config.partitionScheme == .mbr
            && !config.skipMBRBootSectorWrite
            && !config.onlyWriteMBRBootSectors
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

        stage("Sicherheitsprüfung…", fraction: config.onlyWriteMBRBootSectors ? 0.92 : 0.01)
        try DiskDiscovery.validateSafeTarget(deviceIdentifier: diskId, allowDiskImage: config.allowDiskImageTarget)

        // Phase-2 only mode: stamp Windows NT6 MBR + VBR + Active 0x80 on an already-flashed MBR USB drive
        if config.onlyWriteMBRBootSectors {
            let slices = try discoverDataPartitionSlices(for: blockDev, expectedMinimum: 1)
            let bootSlice = slices[0]
            let bootFS: FileSystemType = (config.fileSystem == .exfat) ? .exfat : .fat32
            stage("Schreibe Windows NT6 MBR & VBR Bootsektor…", fraction: 0.93)
            try writeLegacyBIOSBootSectors(
                blockDev: blockDev,
                bootSlice: bootSlice,
                bootFS: bootFS,
                helpersDir: config.helpersDirectory
            )
            Darwin.sync()
            if config.autoEjectAfterFlash {
                stage("Werfe Laufwerk sicher aus…", fraction: 0.99)
                _ = try? runCommand("/usr/sbin/diskutil", arguments: ["eject", blockDev])
            } else {
                for s in slices {
                    try? mountSliceStandard(s)
                }
            }
            emit(FlashProgressEvent(kind: .completed, stage: "Fertig", fraction: 1.0, message: "Bootfähiges MBR/BIOS-Medium erfolgreich erstellt!"))
            return
        }

        log("Ziel-Laufwerk verifiziert: \(blockDev) (\(config.partitionScheme.rawValue) / \(config.fileSystem.rawValue))")
        try checkCancelled()

        let diskSizeBytes = try queryDiskSizeBytes(deviceNode: blockDev)
        log("Laufwerksgröße: \(ByteCountFormatter.string(fromByteCount: diskSizeBytes, countStyle: .decimal))")

        switch config.bootMode {
        case .nonBootable:
            try executeNonBootableFormat(config: config, blockDev: blockDev)

        case .isoOrImage:
            if config.writeMode == .ddRawImage {
                try executeDDRawWrite(config: config, blockDev: blockDev, rawDev: rawDev, diskSizeBytes: diskSizeBytes)
            } else {
                try executeISOFileCopy(config: config, blockDev: blockDev, diskSizeBytes: diskSizeBytes)
            }
        }

        stage("Synchronisiere Dateisystem-Cache…", fraction: config.skipMBRBootSectorWrite ? 0.92 : 0.98)
        Darwin.sync()
        Thread.sleep(forTimeInterval: 0.4)

        if !config.skipMBRBootSectorWrite {
            if config.autoEjectAfterFlash {
                stage("Werfe Laufwerk sicher aus…", fraction: 0.99)
                _ = try? runCommand("/usr/sbin/diskutil", arguments: ["eject", blockDev])
                log("Laufwerk \(blockDev) sicher ausgeworfen.")
            }
            emit(FlashProgressEvent(kind: .completed, stage: "Fertig", fraction: 1.0, message: "Bootfähiges Medium erfolgreich erstellt!"))
        }
    }

    // MARK: - Mode 1: Non-Bootable Format

    private func executeNonBootableFormat(config: FlashJobConfig, blockDev: String) throws {
        stage("Hänge Partitionen aus…", fraction: 0.12)
        try unmountDisk(blockDev)
        try checkCancelled()

        let label = VolumeLabelSanitizer.sanitize(config.volumeLabel, for: config.fileSystem)
        let schemeArg = (config.fileSystem == .apfs) ? "GPT" : config.partitionScheme.rawValue

        stage("Erstelle \(schemeArg)-Partitionstabelle & \(config.fileSystem.rawValue)…", fraction: 0.45)

        switch config.fileSystem {
        case .fat32:
            try partitionDiskWithRetry(arguments: ["partitionDisk", blockDev, schemeArg, "FAT32", label, "100%"], blockDev: blockDev)
            if config.clusterSize != .automatic {
                let slices = try discoverDataPartitionSlices(for: blockDev, expectedMinimum: 1)
                try unmountDisk(blockDev)
                try formatFAT32(sliceDevice: slices[0], label: label, clusterSize: config.clusterSize)
                if !config.autoEjectAfterFlash { try? mountSliceStandard(slices[0]) }
            }

        case .exfat, .dualFat32ExFAT:
            try partitionDiskWithRetry(arguments: ["partitionDisk", blockDev, schemeArg, "ExFAT", label, "100%"], blockDev: blockDev)
            if config.clusterSize != .automatic {
                let slices = try discoverDataPartitionSlices(for: blockDev, expectedMinimum: 1)
                try unmountDisk(blockDev)
                try formatExFAT(sliceDevice: slices[0], label: label, clusterSize: config.clusterSize)
                if !config.autoEjectAfterFlash { try? mountSliceStandard(slices[0]) }
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
        config: FlashJobConfig,
        blockDev: String,
        rawDev: String,
        diskSizeBytes: Int64
    ) throws {
        let sourcePath: String
        let imageSize: Int64

        if let fifoPath = config.rawFifoPath, !fifoPath.isEmpty {
            sourcePath = fifoPath
            imageSize = config.rawInputSizeBytes ?? 0
        } else if let isoPath = config.isoPath, !isoPath.isEmpty {
            guard FileManager.default.fileExists(atPath: isoPath) else {
                throw ISOInspectorError.fileNotFound(isoPath)
            }
            sourcePath = isoPath
            let attrs = try FileManager.default.attributesOfItem(atPath: isoPath)
            imageSize = (attrs[.size] as? Int64) ?? 0
        } else {
            throw FlashEngineError.missingISO
        }

        if imageSize > 0 && imageSize > diskSizeBytes {
            throw FlashEngineError.insufficientDiskSpace(
                requiredMB: imageSize / (1024 * 1024),
                availableMB: diskSizeBytes / (1024 * 1024)
            )
        }

        stage("Hänge Ziel-Laufwerk aus…", fraction: 0.03)
        try unmountDisk(blockDev)
        try checkCancelled()

        stage("Schreibe Raw-Image (DD-Modus)…", fraction: 0.05)
        log("DD-Schreibvorgang (\(ByteCountFormatter.string(fromByteCount: imageSize, countStyle: .decimal))) -> \(rawDev)")

        let dstFD = open(rawDev, O_WRONLY)
        guard dstFD >= 0 else {
            let errCode = errno
            let msg = String(cString: strerror(errCode))
            if errCode == EPERM || errCode == EACCES {
                throw FlashEngineError.fullDiskAccessRequired("DD-Schreibzugriff auf \(rawDev): \(msg)")
            }
            throw FlashEngineError.ioError("Kann Zielgerät \(rawDev) nicht öffnen: \(msg)")
        }
        defer { close(dstFD) }

        let srcFD = open(sourcePath, O_RDONLY)
        guard srcFD >= 0 else {
            throw FlashEngineError.ioError("Kann Bildquelle nicht öffnen: \(String(cString: strerror(errno)))")
        }
        defer { close(srcFD) }

        let bufferSize = 4 * 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer { buffer.deallocate() }

        var writtenTotal: Int64 = 0
        let startTime = Date()
        var lastEmit = Date.distantPast
        var reachedEOF = false

        while !reachedEOF {
            try checkCancelled()

            var filled = 0
            while filled < bufferSize {
                let n = read(srcFD, buffer.advanced(by: filled), bufferSize - filled)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FlashEngineError.ioError("Lesefehler: \(String(cString: strerror(errno)))")
                }
                if n == 0 {
                    reachedEOF = true
                    break
                }
                filled += n
            }

            if filled == 0 { break }

            var bytesToWrite = filled
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

            writtenTotal += Int64(filled)
            let now = Date()
            if now.timeIntervalSince(lastEmit) >= 0.15 || (imageSize > 0 && writtenTotal >= imageSize) {
                let elapsed = max(0.01, now.timeIntervalSince(startTime))
                let speed = Double(writtenTotal) / (1024.0 * 1024.0) / elapsed
                let frac = imageSize > 0 ? (0.05 + 0.90 * min(1.0, Double(writtenTotal) / Double(imageSize))) : 0.5
                let pct = imageSize > 0 ? Int(min(100, (Double(writtenTotal) / Double(imageSize)) * 100)) : 0
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
        config: FlashJobConfig,
        blockDev: String,
        diskSizeBytes: Int64
    ) throws {
        let isoMountPath: String
        var locallyMountedISO: MountedImageInfo? = nil

        if let preMounted = config.preMountedISOPath, !preMounted.isEmpty, FileManager.default.fileExists(atPath: preMounted) {
            isoMountPath = preMounted
            stage("Lese eingehängtes ISO-Abbild…", fraction: 0.03)
            log("Verwende vorab eingehängtes ISO: \(isoMountPath)")
        } else {
            guard let isoPath = config.isoPath, !isoPath.isEmpty else {
                throw FlashEngineError.missingISO
            }
            guard FileManager.default.fileExists(atPath: isoPath) else {
                throw ISOInspectorError.fileNotFound(isoPath)
            }
            stage("Hänge ISO-Abbild ein…", fraction: 0.03)
            let mounted = try ISOInspector.attachReadOnly(isoPath: isoPath)
            locallyMountedISO = mounted
            isoMountPath = mounted.mountPoint
            log("ISO eingehängt unter: \(isoMountPath)")
        }

        defer {
            if let mounted = locallyMountedISO {
                ISOInspector.detach(mounted)
                log("ISO-Abbild ausgehängt.")
            }
        }

        try checkCancelled()

        let isoEntries = try enumerateFiles(in: isoMountPath)
        guard !isoEntries.isEmpty else {
            throw FlashEngineError.ioError("Das eingehängte ISO-Verzeichnis scheint leer oder nicht lesbar zu sein (\(isoMountPath)).")
        }

        let totalISOBytes = isoEntries.reduce(Int64(0)) { $0 + $1.size }
        log("ISO enthält \(isoEntries.count) Dateien (\(ByteCountFormatter.string(fromByteCount: totalISOBytes, countStyle: .decimal))).")

        if totalISOBytes + 64 * 1024 * 1024 > diskSizeBytes {
            throw FlashEngineError.insufficientDiskSpace(
                requiredMB: (totalISOBytes / (1024 * 1024)) + 64,
                availableMB: diskSizeBytes / (1024 * 1024)
            )
        }

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

        if config.partitionScheme == .mbr && !config.skipMBRBootSectorWrite {
            _ = try resolveHelper(named: "ms-sys", helpersDir: config.helpersDirectory)
        }

        stage("Hänge Ziel-Laufwerk aus…", fraction: 0.06)
        try unmountDisk(blockDev)
        try checkCancelled()

        if config.fileSystem == .dualFat32ExFAT {
            try executeDualPartitionCopy(
                isoMount: isoMountPath,
                isoEntries: isoEntries,
                config: config,
                blockDev: blockDev,
                diskSizeBytes: diskSizeBytes
            )
        } else {
            try executeSinglePartitionCopy(
                isoMount: isoMountPath,
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

        stage("Erstelle \(scheme)-Partitionstabelle & formatiere \(config.fileSystem.rawValue)…", fraction: 0.12)
        if config.fileSystem == .fat32 {
            try partitionDiskWithRetry(arguments: ["partitionDisk", blockDev, scheme, "FAT32", label, "100%"], blockDev: blockDev)
        } else {
            try partitionDiskWithRetry(arguments: ["partitionDisk", blockDev, scheme, "ExFAT", label, "100%"], blockDev: blockDev)
        }

        // Dynamically discover the REAL data partition slice (skips macOS's 200 MB EFI partition on >=1GB GPT disks!)
        let dataSlices = try discoverDataPartitionSlices(for: blockDev, expectedMinimum: 1)
        let dataSlice = dataSlices[0]
        log("Ziel-Datenpartition erkannt: \(dataSlice)")

        if config.clusterSize != .automatic {
            try unmountDisk(blockDev)
            stage("Formatiere \(config.fileSystem.rawValue) mit Clustergröße \(config.clusterSize.rawValue) Bytes…", fraction: 0.16)
            if config.fileSystem == .fat32 {
                try formatFAT32(sliceDevice: dataSlice, label: label, clusterSize: config.clusterSize)
            } else {
                try formatExFAT(sliceDevice: dataSlice, label: label, clusterSize: config.clusterSize)
            }
        }

        // Reuse the mountpoint diskutil partitionDisk already created, or mount cleanly if needed!
        let targetMount = try ensureSliceMounted(dataSlice)
        log("Zielpartition bereit unter: \(targetMount)")
        disableSpotlightOnVolume(targetMount)

        let excludedRel = installWimEntry?.relativePath.lowercased()
        let filesToCopy = isoEntries.filter { $0.relativePath.lowercased() != excludedRel }
        let copyEndFraction = (installWimEntry != nil) ? 0.50 : 0.92

        stage("Kopiere Installationsdateien…", fraction: 0.18)
        try copyEntries(
            filesToCopy,
            fromRoot: isoMount,
            toRoot: targetMount,
            progressStart: 0.18,
            progressEnd: copyEndFraction,
            stageTitle: "Kopiere Dateien…"
        )

        if let wim = installWimEntry {
            try checkCancelled()
            let srcWim = (isoMount as NSString).appendingPathComponent(wim.relativePath)
            let dstSourcesDir = (targetMount as NSString).appendingPathComponent("sources")
            try FileManager.default.createDirectory(atPath: dstSourcesDir, withIntermediateDirectories: true)
            let dstSwm = (dstSourcesDir as NSString).appendingPathComponent("install.swm")

            stage("Teile install.wim für FAT32 (wimlib-imagex)…", fraction: 0.51)
            log("Starte wimlib-imagex split (3800 MB Teile): \(srcWim) -> \(dstSwm)")
            try runWimSplit(
                helpersDir: config.helpersDirectory,
                sourceWim: srcWim,
                sourceSizeBytes: wim.size,
                destSwm: dstSwm,
                partSizeMB: 3800,
                progressStart: 0.51,
                progressEnd: 0.93
            )
            log("install.wim erfolgreich in .swm-Dateien aufgeteilt.")
        }

        try writeAutoUnattendIfNeeded(config: config, targetMounts: [targetMount])
        Darwin.sync()

        // Only unmount if MBR boot sectors need to be written next!
        if config.partitionScheme == .mbr {
            try unmountDisk(blockDev)
            if !config.skipMBRBootSectorWrite {
                stage("Schreibe Windows NT6 MBR & VBR Bootsektor…", fraction: 0.95)
                try writeLegacyBIOSBootSectors(
                    blockDev: blockDev,
                    bootSlice: dataSlice,
                    bootFS: config.fileSystem == .exfat ? .exfat : .fat32,
                    helpersDir: config.helpersDirectory
                )
                if !config.autoEjectAfterFlash {
                    try? mountSliceStandard(dataSlice)
                }
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

        let isDataOnlyFile: (ISOFileEntry) -> Bool = { entry in
            let lower = entry.relativePath.lowercased()
            return lower == "sources/install.wim" || lower == "sources/install.esd" || entry.size >= fat32Limit
        }

        let bootFiles = isoEntries.filter { !isDataOnlyFile($0) }
        let dataFiles = isoEntries.filter { isDataOnlyFile($0) }

        let bootFilesBytes = bootFiles.reduce(Int64(0)) { $0 + $1.size }
        let dataFilesBytes = dataFiles.reduce(Int64(0)) { $0 + $1.size }

        let bootPartMB = max(Int64(128), (bootFilesBytes / (1024 * 1024)) + 256)
        let neededDataMB = (dataFilesBytes / (1024 * 1024)) + 128
        let diskMB = diskSizeBytes / (1024 * 1024)

        if bootPartMB + neededDataMB > diskMB {
            throw FlashEngineError.insufficientDiskSpace(requiredMB: bootPartMB + neededDataMB, availableMB: diskMB)
        }

        stage("Erstelle Dual-Partition (\(scheme): \(bootPartMB) MB FAT32 Boot + ExFAT Daten)…", fraction: 0.12)
        try partitionDiskWithRetry(arguments: [
            "partitionDisk", blockDev, scheme,
            "FAT32", bootLabel, "\(bootPartMB)M",
            "ExFAT", dataLabel, "R"
        ], blockDev: blockDev)

        // Dynamically discover the REAL 2 data slices (e.g. disk6s2 + disk6s3 on >=1GB GPT, or disk6s1 + disk6s2 on MBR)
        let dataSlices = try discoverDataPartitionSlices(for: blockDev, expectedMinimum: 2)
        let bootSlice = dataSlices[0]
        let dataSlice = dataSlices[1]
        log("Dual-Partition erkannt: Boot=\(bootSlice) (FAT32), Daten=\(dataSlice) (ExFAT)")

        if config.clusterSize != .automatic {
            try unmountDisk(blockDev)
            stage("Formatiere ExFAT mit Clustergröße \(config.clusterSize.rawValue) Bytes…", fraction: 0.16)
            try formatExFAT(sliceDevice: dataSlice, label: dataLabel, clusterSize: config.clusterSize)
        }

        let bootMount = try ensureSliceMounted(bootSlice)
        let dataMount = try ensureSliceMounted(dataSlice)
        log("Boot-Partition: \(bootMount) | Daten-Partition: \(dataMount)")
        disableSpotlightOnVolume(bootMount)
        disableSpotlightOnVolume(dataMount)

        stage("Kopiere Boot-Dateien auf FAT32-Partition…", fraction: 0.18)
        let bootRatio = max(0.15, min(0.55, Double(bootFilesBytes) / Double(max(1, bootFilesBytes + dataFilesBytes))))
        let bootEndFrac = 0.18 + 0.74 * bootRatio

        try copyEntries(
            bootFiles,
            fromRoot: isoMount,
            toRoot: bootMount,
            progressStart: 0.18,
            progressEnd: bootEndFrac,
            stageTitle: "Kopiere Boot-Dateien (FAT32)…"
        )

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
            progressEnd: 0.93,
            stageTitle: "Kopiere install.wim (ExFAT)…"
        )

        try writeAutoUnattendIfNeeded(config: config, targetMounts: [bootMount, dataMount])
        Darwin.sync()

        if config.partitionScheme == .mbr {
            try unmountDisk(blockDev)
            if !config.skipMBRBootSectorWrite {
                stage("Schreibe Windows NT6 MBR & FAT32 VBR auf Boot-Partition…", fraction: 0.95)
                try writeLegacyBIOSBootSectors(
                    blockDev: blockDev,
                    bootSlice: bootSlice,
                    bootFS: .fat32,
                    helpersDir: config.helpersDirectory
                )
                if !config.autoEjectAfterFlash {
                    try? mountSliceStandard(bootSlice)
                    try? mountSliceStandard(dataSlice)
                }
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

        let probeFD = open(blockDev, O_RDWR)
        if probeFD < 0 {
            let errCode = errno
            let msg = String(cString: strerror(errCode))
            if errCode == EPERM || errCode == EACCES {
                throw FlashEngineError.fullDiskAccessRequired("MBR-Bootsektor auf \(blockDev): \(msg)")
            }
            throw FlashEngineError.ioError("Kann \(blockDev) nicht für Bootsektor-Schreiben öffnen: \(msg)")
        }
        close(probeFD)

        let sigValue = UInt32.random(in: 0x10000001...0xFFFFFFFE)
        let sigHex = String(format: "%08X", sigValue)

        log("Schreibe Windows NT6/10/11 MBR + Disk-Signatur 0x\(sigHex) auf \(blockDev)…")
        try runMsSysWithRetry(msSysPath, arguments: ["-7", "-S", sigHex, "-f", blockDev], blockDev: blockDev)

        if bootFS == .exfat {
            log("Schreibe Windows NT6 ExFAT BOOTMGR-VBR auf \(bootSlice)…")
            try runMsSysWithRetry(msSysPath, arguments: ["-x", "-p", "-f", bootSlice], blockDev: blockDev)
        } else {
            log("Schreibe Windows NT6 FAT32 BOOTMGR-VBR auf \(bootSlice)…")
            try runMsSysWithRetry(msSysPath, arguments: ["-8", "-p", "-f", bootSlice], blockDev: blockDev)
        }

        log("Setze Aktiv/Boot-Flag (0x80) für Partition 1 im MBR…")
        try setMBRPartition1Active(blockDev: blockDev)
        Darwin.sync()
        log("Legacy BIOS MBR + VBR Bootsektoren erfolgreich geschrieben und verifiziert.")
    }

    private func runMsSysWithRetry(_ msSysPath: String, arguments: [String], blockDev: String) throws {
        for attempt in 1...3 {
            do {
                try runCommand(msSysPath, arguments: arguments)
                return
            } catch {
                if attempt == 3 { throw error }
                _ = try? runCommand("/usr/sbin/diskutil", arguments: ["unmountDisk", "force", blockDev])
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
    }

    private func setMBRPartition1Active(blockDev: String) throws {
        let fd = open(blockDev, O_RDWR)
        guard fd >= 0 else {
            let errCode = errno
            let msg = String(cString: strerror(errCode))
            if errCode == EPERM || errCode == EACCES {
                throw FlashEngineError.fullDiskAccessRequired("MBR-Active-Flag auf \(blockDev): \(msg)")
            }
            throw FlashEngineError.ioError("Kann \(blockDev) zum Setzen des Active-Flags nicht öffnen: \(msg)")
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

        sector[446] = 0x80
        sector[446 + 16] = 0x00
        sector[446 + 32] = 0x00
        sector[446 + 48] = 0x00

        let writeN = pwrite(fd, &sector, 512, 0)
        guard writeN == 512 else {
            throw FlashEngineError.ioError("Konnte MBR-Active-Flag nicht schreiben: \(String(cString: strerror(errno)))")
        }
        _ = fsync(fd)
    }

    // MARK: - wimlib-imagex Split with Live Output + File-Size Progress Monitoring

    private func runWimSplit(
        helpersDir: String?,
        sourceWim: String,
        sourceSizeBytes: Int64,
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

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                errorLock.lock()
                accumulatedError += str
                errorLock.unlock()
            }
        }

        let regex = try? NSRegularExpression(pattern: #"\((\d+)%\)"#)
        let mibRegex = try? NSRegularExpression(pattern: #"(\d+)\s*MiB\s+of\s+(\d+)\s*MiB"#)
        var lastStdoutProgress = Date.distantPast
        let stdoutLock = NSLock()

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
                    stdoutLock.lock()
                    lastStdoutProgress = Date()
                    stdoutLock.unlock()
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

        // Monitor cancellation every 150ms AND track written .swm file sizes on disk so progress bar
        // updates smoothly even when wimlib buffers stdout on a non-TTY pipe!
        let dstDir = (destSwm as NSString).deletingLastPathComponent
        var lastPollEmit = Date.distantPast

        while proc.isRunning {
            if isCancelled() {
                proc.terminate()
                Thread.sleep(forTimeInterval: 0.3)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                throw FlashEngineError.cancelled
            }

            let now = Date()
            stdoutLock.lock()
            let silentStdout = now.timeIntervalSince(lastStdoutProgress) > 1.0
            stdoutLock.unlock()

            if silentStdout && now.timeIntervalSince(lastPollEmit) >= 0.45 && sourceSizeBytes > 0 {
                let writtenSwmBytes = totalSwmBytes(in: dstDir)
                if writtenSwmBytes > 0 {
                    let ratio = min(0.99, Double(writtenSwmBytes) / Double(sourceSizeBytes))
                    let elapsed = max(0.2, now.timeIntervalSince(startTime))
                    let speed = Double(writtenSwmBytes) / (1024.0 * 1024.0) / elapsed
                    let frac = progressStart + (progressEnd - progressStart) * ratio
                    let pct = Int(ratio * 100)
                    let writtenStr = ByteCountFormatter.string(fromByteCount: writtenSwmBytes, countStyle: .decimal)
                    let totalStr = ByteCountFormatter.string(fromByteCount: sourceSizeBytes, countStyle: .decimal)
                    progress(
                        "Teile install.wim (\(pct)%)…",
                        fraction: frac,
                        speedMBps: speed,
                        message: "Schreibe install.swm: \(writtenStr) / \(totalStr)"
                    )
                    lastPollEmit = now
                }
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

    private func totalSwmBytes(in dirPath: String) -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return 0 }
        var total: Int64 = 0
        for item in items where item.lowercased().hasSuffix(".swm") {
            let full = (dirPath as NSString).appendingPathComponent(item)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
               let sz = attrs[.size] as? Int64 {
                total += sz
            }
        }
        return total
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
            let name = url.lastPathComponent
            if name == ".DS_Store" || name.hasPrefix("._") { continue }
            let full = url.standardizedFileURL.path
            let rel = full.hasPrefix(basePath + "/") ? String(full.dropFirst(basePath.count + 1)) : name
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
        let chunkSize = 2 * 1024 * 1024
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
                let errCode = errno
                let msg = String(cString: strerror(errCode))
                if errCode == EPERM || errCode == EACCES {
                    throw FlashEngineError.fullDiskAccessRequired("Schreibzugriff auf Wechseldatenträger (\(dstPath)): \(msg)")
                }
                throw FlashEngineError.ioError("Kann \(entry.relativePath) nicht schreiben: \(msg)")
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
        guard let plan = AutoUnattendGenerator.generatePlan(options: config.windowsOptions) else { return }

        let fm = FileManager.default
        for mount in targetMounts {
            let dest = (mount as NSString).appendingPathComponent(plan.relativePath)
            let parentDir = (dest as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            try plan.xmlContent.write(toFile: dest, atomically: true, encoding: .utf8)
            log("Windows-Anpassung geschrieben: \(dest)")

            // Also apply Rufus's appraiserres.dll placeholder bypass when TPM/SecureBoot bypass is enabled
            if plan.shouldPatchAppraiserRes {
                let appraiserSrc = (mount as NSString).appendingPathComponent("sources/appraiserres.dll")
                let appraiserBak = (mount as NSString).appendingPathComponent("sources/appraiserres.bak")
                if fm.fileExists(atPath: appraiserSrc) {
                    try? fm.removeItem(atPath: appraiserBak)
                    try? fm.moveItem(atPath: appraiserSrc, toPath: appraiserBak)
                    fm.createFile(atPath: appraiserSrc, contents: Data())
                    log("Windows-11-Hardwareprüfung entschärft: sources/appraiserres.dll -> .bak (Platzhalter erstellt)")
                }
            }
        }
    }

    // MARK: - Dynamic Partition Discovery & Mounting

    /// Queries `diskutil list -plist <blockDev>` and returns the ordered non-EFI data partition devices
    /// (e.g. `["/dev/disk6s2"]` on >=1GB GPT disks where `disk6s1` is macOS's auto-created 200 MB EFI partition,
    /// or `["/dev/disk6s1"]` on MBR disks / small disks).
    public func discoverDataPartitionSlices(for blockDev: String, expectedMinimum: Int) throws -> [String] {
        for attempt in 1...6 {
            if let data = try? DiskDiscovery.runProcess("/usr/sbin/diskutil", arguments: ["list", "-plist", blockDev]),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let entries = plist["AllDisksAndPartitions"] as? [[String: Any]] {
                var slices: [String] = []
                for entry in entries {
                    guard let parts = entry["Partitions"] as? [[String: Any]] else { continue }
                    for part in parts {
                        guard let devId = part["DeviceIdentifier"] as? String else { continue }
                        let content = (part["Content"] as? String) ?? ""
                        let lowerContent = content.lowercased()
                        // Skip system/EFI/MSR/Apple_Boot partitions!
                        if lowerContent == "efi"
                            || lowerContent.contains("microsoft reserved")
                            || lowerContent == "apple_boot"
                            || lowerContent == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {
                            continue
                        }
                        slices.append("/dev/\(devId)")
                    }
                }
                if slices.count >= expectedMinimum {
                    return slices
                }
            }
            if attempt < 6 {
                Thread.sleep(forTimeInterval: 0.35)
            }
        }
        throw FlashEngineError.mountPointNotFound(blockDev)
    }

    /// Ensures `sliceDevice` is mounted and returns its mount point.
    /// Reuses an existing mountpoint immediately (diskutil partitionDisk already mounts data slices cleanly!).
    private func ensureSliceMounted(_ sliceDevice: String) throws -> String {
        // 1. Check if already mounted (e.g., auto-mounted by diskutil partitionDisk)
        for _ in 1...5 {
            if let mp = currentMountPoint(for: sliceDevice) {
                return mp
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        // 2. Otherwise mount cleanly via diskutil mount
        try mountSliceStandard(sliceDevice)
        return try waitForMountPoint(sliceDevice: sliceDevice)
    }

    private func currentMountPoint(for sliceDevice: String) -> String? {
        guard let data = try? DiskDiscovery.runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", sliceDevice]),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let mp = dict["MountPoint"] as? String, !mp.isEmpty else {
            return nil
        }
        return mp
    }

    private func disableSpotlightOnVolume(_ mountPoint: String) {
        let marker = (mountPoint as NSString).appendingPathComponent(".metadata_never_index")
        FileManager.default.createFile(atPath: marker, contents: Data())
    }

    private func partitionDiskWithRetry(arguments: [String], blockDev: String) throws {
        for attempt in 1...3 {
            do {
                try runCommand("/usr/sbin/diskutil", arguments: arguments)
                return
            } catch {
                if attempt == 3 { throw error }
                log("Partitionierungsversuch \(attempt) fehlgeschlagen, versuche erneut nach Aushängen…")
                _ = try? runCommand("/usr/sbin/diskutil", arguments: ["unmountDisk", "force", blockDev])
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    private func formatFAT32(sliceDevice: String, label: String, clusterSize: ClusterSize) throws {
        var args = ["-F", "32", "-v", label]
        if clusterSize != .automatic {
            args.append(contentsOf: ["-b", "\(clusterSize.rawValue)"])
        }
        args.append(sliceDevice)
        do {
            try runCommand("/sbin/newfs_msdos", arguments: args)
        } catch let FlashEngineError.commandFailed(_, details) where details.localizedCaseInsensitiveContains("Operation not permitted") {
            throw FlashEngineError.fullDiskAccessRequired("Benutzerdefinierte Clustergröße (newfs_msdos): \(details)")
        }
    }

    private func formatExFAT(sliceDevice: String, label: String, clusterSize: ClusterSize) throws {
        var args = ["-v", label]
        if clusterSize != .automatic {
            args.append(contentsOf: ["-b", "\(clusterSize.rawValue)"])
        }
        args.append(sliceDevice)
        do {
            try runCommand("/sbin/newfs_exfat", arguments: args)
        } catch let FlashEngineError.commandFailed(_, details) where details.localizedCaseInsensitiveContains("Operation not permitted") {
            throw FlashEngineError.fullDiskAccessRequired("Benutzerdefinierte Clustergröße (newfs_exfat): \(details)")
        }
    }

    private func unmountDisk(_ blockDev: String) throws {
        for attempt in 1...4 {
            do {
                try runCommand("/usr/sbin/diskutil", arguments: ["unmountDisk", "force", blockDev])
                return
            } catch {
                if attempt == 4 { throw error }
                Thread.sleep(forTimeInterval: 0.7)
            }
        }
    }

    private func mountSliceStandard(_ sliceDevice: String) throws {
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
            if let mp = currentMountPoint(for: sliceDevice) {
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
