import Foundation

// MARK: - USB Drive Model

public struct USBDrive: Identifiable, Hashable, Codable, Sendable {
    public var id: String { deviceIdentifier }
    public let deviceIdentifier: String      // e.g. "disk9"
    public let deviceNode: String            // e.g. "/dev/disk9"
    public let mediaName: String             // e.g. "PHILIPS"
    public let sizeBytes: Int64
    public let busProtocol: String           // e.g. "USB"
    public let isRemovable: Bool
    public let isExternal: Bool
    public let isSolidState: Bool?
    public let currentScheme: String         // e.g. "GUID_partition_scheme" or "None"
    public let mountedVolumes: [String]      // e.g. ["32 GB"]

    public init(
        deviceIdentifier: String,
        deviceNode: String,
        mediaName: String,
        sizeBytes: Int64,
        busProtocol: String,
        isRemovable: Bool,
        isExternal: Bool,
        isSolidState: Bool?,
        currentScheme: String,
        mountedVolumes: [String]
    ) {
        self.deviceIdentifier = deviceIdentifier
        self.deviceNode = deviceNode
        self.mediaName = mediaName
        self.sizeBytes = sizeBytes
        self.busProtocol = busProtocol
        self.isRemovable = isRemovable
        self.isExternal = isExternal
        self.isSolidState = isSolidState
        self.currentScheme = currentScheme
        self.mountedVolumes = mountedVolumes
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .decimal)
    }

    public var displayTitle: String {
        let name = mediaName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = name.isEmpty ? "USB-Laufwerk" : name
        return "\(base) [\(formattedSize)] (/dev/\(deviceIdentifier))"
    }

    public var shortSchemeLabel: String {
        switch currentScheme {
        case "GUID_partition_scheme": return "GPT"
        case "FDisk_partition_scheme": return "MBR"
        case "Apple_partition_scheme": return "APM"
        default: return currentScheme.isEmpty || currentScheme == "None" ? "Raw / UDF" : currentScheme
        }
    }
}

// MARK: - Boot Selection & Write Mode

public enum BootSelectionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case isoOrImage = "iso"
    case nonBootable = "non_bootable"

    public var id: String { rawValue }
}

public enum WriteMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case isoFileCopy = "iso_copy"
    case ddRawImage = "dd_raw"

    public var id: String { rawValue }
}

// MARK: - Partition Scheme & Target System

public enum PartitionScheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case gpt = "GPT"
    case mbr = "MBR"

    public var id: String { rawValue }

    public var targetSystemDE: String {
        switch self {
        case .gpt: return "UEFI (ohne CSM)"
        case .mbr: return "BIOS oder UEFI-CSM"
        }
    }

    public var targetSystemEN: String {
        switch self {
        case .gpt: return "UEFI (non CSM)"
        case .mbr: return "BIOS or UEFI-CSM"
        }
    }

    public var descriptionDE: String {
        switch self {
        case .gpt: return "Empfohlen für moderne PCs, Windows 11 & Secure Boot"
        case .mbr: return "Für ältere BIOS-PCs (schreibt NT6 BOOTMGR-Bootsektor)"
        }
    }

    public var descriptionEN: String {
        switch self {
        case .gpt: return "Recommended for modern PCs, Windows 11 & Secure Boot"
        case .mbr: return "For legacy BIOS PCs (writes NT6 BOOTMGR boot sector)"
        }
    }
}

// MARK: - File System Selection

public enum FileSystemType: String, CaseIterable, Identifiable, Codable, Sendable {
    case fat32 = "FAT32"
    case dualFat32ExFAT = "DUAL_FAT32_EXFAT"
    case exfat = "ExFAT"
    case apfs = "APFS"
    case hfsPlus = "JHFS+"

    public var id: String { rawValue }

    public static var bootableCases: [FileSystemType] {
        [.fat32, .dualFat32ExFAT, .exfat]
    }

    public static var formatOnlyCases: [FileSystemType] {
        [.fat32, .exfat, .apfs, .hfsPlus]
    }

    public var titleDE: String {
        switch self {
        case .fat32: return "FAT32 (Universal — Auto WIM-Split)"
        case .dualFat32ExFAT: return "ExFAT + FAT32 Boot (Dual-Partition)"
        case .exfat: return "ExFAT (Einzelpartition)"
        case .apfs: return "APFS (macOS)"
        case .hfsPlus: return "Mac OS Extended (HFS+)"
        }
    }

    public var titleEN: String {
        switch self {
        case .fat32: return "FAT32 (Universal — Auto WIM Split)"
        case .dualFat32ExFAT: return "ExFAT + FAT32 Boot (Dual-Partition)"
        case .exfat: return "ExFAT (Single Partition)"
        case .apfs: return "APFS (macOS)"
        case .hfsPlus: return "Mac OS Extended (HFS+)"
        }
    }

    public var subtitleDE: String {
        switch self {
        case .fat32:
            return "Maximale UEFI & BIOS Kompatibilität (inkl. Secure Boot). Teilt install.wim > 4 GB automatisch."
        case .dualFat32ExFAT:
            return "FAT32-Bootpartition + ExFAT-Datenpartition. Kopiert install.wim > 4 GB ohne Splitting."
        case .exfat:
            return "Einzelne ExFAT-Partition für moderne UEFI-Boards mit ExFAT-Treiber oder Datensticks."
        case .apfs:
            return "Modernes Apple Dateisystem (nur macOS)."
        case .hfsPlus:
            return "Klassisches macOS Dateisystem."
        }
    }

    public var subtitleEN: String {
        switch self {
        case .fat32:
            return "Maximum UEFI & BIOS compatibility (with Secure Boot). Auto-splits install.wim > 4 GB."
        case .dualFat32ExFAT:
            return "FAT32 boot partition + ExFAT data partition. Keeps > 4 GB install.wim intact without splitting."
        case .exfat:
            return "Single ExFAT partition for modern UEFI firmware with native ExFAT or data storage."
        case .apfs:
            return "Modern Apple File System (macOS only)."
        case .hfsPlus:
            return "Classic macOS Journaled file system."
        }
    }
}

// MARK: - Cluster Size

public enum ClusterSize: Int, CaseIterable, Identifiable, Codable, Sendable {
    case automatic = 0
    case kb4 = 4096
    case kb8 = 8192
    case kb16 = 16384
    case kb32 = 32768
    case kb64 = 65536

    public var id: Int { rawValue }

    public func displayName(isGerman: Bool) -> String {
        switch self {
        case .automatic: return isGerman ? "Standard (Automatisch)" : "Default (Automatic)"
        case .kb4: return "4096 Bytes (4 KB)"
        case .kb8: return "8192 Bytes (8 KB)"
        case .kb16: return "16 KB"
        case .kb32: return "32 KB"
        case .kb64: return "64 KB"
        }
    }
}

// MARK: - ISO Analysis

public enum DetectedImageKind: String, Codable, Sendable {
    case windowsISO = "windows_iso"
    case linuxHybridISO = "linux_hybrid_iso"
    case genericISO = "generic_iso"
    case rawDiskImage = "raw_disk_image"
}

public struct ISOAnalysis: Codable, Sendable, Equatable {
    public let filePath: String
    public let fileName: String
    public let fileSizeBytes: Int64
    public let kind: DetectedImageKind
    public let volumeName: String
    public let isWindows11Likely: Bool
    public let windowsArchitecture: String?   // "x64", "ARM64", "x86"
    public let hasUEFIBootloader: Bool
    public let hasLegacyBIOSBootloader: Bool
    public let hasHybridMBR: Bool
    public let installImageRelativePath: String? // e.g. "sources/install.wim" or "sources/install.esd"
    public let installImageSizeBytes: Int64
    public let isInstallImageSolidESD: Bool
    public let largestFileRelativePath: String?
    public let largestFileSizeBytes: Int64

    public static let fat32MaxFileSize: Int64 = 4_294_967_295 // 4 GiB - 1

    public var exceedsFAT32Limit: Bool {
        largestFileSizeBytes >= Self.fat32MaxFileSize
    }

    public var installWimNeedsSplit: Bool {
        guard let rel = installImageRelativePath else { return false }
        return installImageSizeBytes >= Self.fat32MaxFileSize && rel.lowercased().hasSuffix(".wim")
    }

    public var installEsdExceedsFAT32: Bool {
        guard let rel = installImageRelativePath else { return false }
        return installImageSizeBytes >= Self.fat32MaxFileSize && rel.lowercased().hasSuffix(".esd")
    }

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .decimal)
    }

    public var formattedInstallImageSize: String {
        ByteCountFormatter.string(fromByteCount: installImageSizeBytes, countStyle: .decimal)
    }

    public init(
        filePath: String,
        fileName: String,
        fileSizeBytes: Int64,
        kind: DetectedImageKind,
        volumeName: String,
        isWindows11Likely: Bool,
        windowsArchitecture: String?,
        hasUEFIBootloader: Bool,
        hasLegacyBIOSBootloader: Bool,
        hasHybridMBR: Bool,
        installImageRelativePath: String?,
        installImageSizeBytes: Int64,
        isInstallImageSolidESD: Bool,
        largestFileRelativePath: String?,
        largestFileSizeBytes: Int64
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.fileSizeBytes = fileSizeBytes
        self.kind = kind
        self.volumeName = volumeName
        self.isWindows11Likely = isWindows11Likely
        self.windowsArchitecture = windowsArchitecture
        self.hasUEFIBootloader = hasUEFIBootloader
        self.hasLegacyBIOSBootloader = hasLegacyBIOSBootloader
        self.hasHybridMBR = hasHybridMBR
        self.installImageRelativePath = installImageRelativePath
        self.installImageSizeBytes = installImageSizeBytes
        self.isInstallImageSolidESD = isInstallImageSolidESD
        self.largestFileRelativePath = largestFileRelativePath
        self.largestFileSizeBytes = largestFileSizeBytes
    }
}

public struct ImageChecksums: Sendable, Equatable {
    public let md5: String
    public let sha1: String
    public let sha256: String

    public init(md5: String, sha1: String, sha256: String) {
        self.md5 = md5
        self.sha1 = sha1
        self.sha256 = sha256
    }
}

// MARK: - Windows Unattended Customization (Rufus-style)

public struct WindowsCustomizationOptions: Codable, Sendable, Equatable {
    public var bypassHardwareChecks: Bool      // TPM 2.0, Secure Boot, 4 GB RAM, CPU
    public var bypassMicrosoftAccount: Bool    // Create local account & skip OOBE online requirement
    public var localAccountUsername: String    // Default "User"
    public var disablePrivacyQuestions: Bool   // ProtectYourPC = 3, HideEULA, HideWireless

    public init(
        bypassHardwareChecks: Bool = false,
        bypassMicrosoftAccount: Bool = false,
        localAccountUsername: String = "User",
        disablePrivacyQuestions: Bool = false
    ) {
        self.bypassHardwareChecks = bypassHardwareChecks
        self.bypassMicrosoftAccount = bypassMicrosoftAccount
        self.localAccountUsername = localAccountUsername
        self.disablePrivacyQuestions = disablePrivacyQuestions
    }

    public var isAnyEnabled: Bool {
        bypassHardwareChecks || bypassMicrosoftAccount || disablePrivacyQuestions
    }
}

// MARK: - Flash Job Configuration

public struct FlashJobConfig: Codable, Sendable {
    public let targetDeviceIdentifier: String   // e.g. "disk9"
    public let bootMode: BootSelectionMode
    public let writeMode: WriteMode
    public let isoPath: String?
    public let isoKind: DetectedImageKind?
    public let partitionScheme: PartitionScheme
    public let fileSystem: FileSystemType
    public let volumeLabel: String
    public let clusterSize: ClusterSize
    public let quickFormat: Bool
    public let wipePartitionTable: Bool
    public let autoEjectAfterFlash: Bool
    public let windowsOptions: WindowsCustomizationOptions
    public let helpersDirectory: String?
    public let allowDiskImageTarget: Bool       // Strictly false in UI; true only for automated virtual disk tests

    public init(
        targetDeviceIdentifier: String,
        bootMode: BootSelectionMode,
        writeMode: WriteMode,
        isoPath: String?,
        isoKind: DetectedImageKind?,
        partitionScheme: PartitionScheme,
        fileSystem: FileSystemType,
        volumeLabel: String,
        clusterSize: ClusterSize,
        quickFormat: Bool,
        wipePartitionTable: Bool,
        autoEjectAfterFlash: Bool,
        windowsOptions: WindowsCustomizationOptions,
        helpersDirectory: String? = nil,
        allowDiskImageTarget: Bool = false
    ) {
        self.targetDeviceIdentifier = targetDeviceIdentifier
        self.bootMode = bootMode
        self.writeMode = writeMode
        self.isoPath = isoPath
        self.isoKind = isoKind
        self.partitionScheme = partitionScheme
        self.fileSystem = fileSystem
        self.volumeLabel = volumeLabel
        self.clusterSize = clusterSize
        self.quickFormat = quickFormat
        self.wipePartitionTable = wipePartitionTable
        self.autoEjectAfterFlash = autoEjectAfterFlash
        self.windowsOptions = windowsOptions
        self.helpersDirectory = helpersDirectory
        self.allowDiskImageTarget = allowDiskImageTarget
    }
}

// MARK: - Progress Events (JSONL between helper and GUI)

public enum FlashEventKind: String, Codable, Sendable {
    case stage
    case progress
    case log
    case completed
    case cancelled
    case failed
}

public struct FlashProgressEvent: Codable, Sendable {
    public let kind: FlashEventKind
    public let stage: String?
    public let fraction: Double?
    public let speedMBps: Double?
    public let message: String
    public let timestamp: Double

    public init(
        kind: FlashEventKind,
        stage: String? = nil,
        fraction: Double? = nil,
        speedMBps: Double? = nil,
        message: String,
        timestamp: Double = Date().timeIntervalSince1970
    ) {
        self.kind = kind
        self.stage = stage
        self.fraction = fraction
        self.speedMBps = speedMBps
        self.message = message
        self.timestamp = timestamp
    }
}

// MARK: - Volume Label Sanitizer

public enum VolumeLabelSanitizer {
    /// Sanitizes volume label for FAT32 (max 11 ASCII uppercase chars, no illegal FAT characters)
    /// or ExFAT/APFS/HFS+ (max 15-31 safe chars).
    public static func sanitize(_ raw: String, for fileSystem: FileSystemType) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch fileSystem {
        case .fat32:
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_- ")
            let upper = trimmed.uppercased()
            let filteredScalars = upper.unicodeScalars.filter { allowed.contains($0) }
            let cleaned = String(String.UnicodeScalarView(filteredScalars))
                .trimmingCharacters(in: .whitespaces)
            let truncated = String(cleaned.prefix(11)).trimmingCharacters(in: .whitespaces)
            return truncated.isEmpty ? "RUFUSMAC" : truncated
        case .dualFat32ExFAT, .exfat:
            let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
            let filteredScalars = trimmed.unicodeScalars.filter { !forbidden.contains($0) && $0.value >= 32 && $0.value < 127 }
            let cleaned = String(String.UnicodeScalarView(filteredScalars))
                .trimmingCharacters(in: .whitespaces)
            let truncated = String(cleaned.prefix(15)).trimmingCharacters(in: .whitespaces)
            return truncated.isEmpty ? "WINDOWS_USB" : truncated
        case .apfs, .hfsPlus:
            let forbidden = CharacterSet(charactersIn: "/:")
            let filteredScalars = trimmed.unicodeScalars.filter { !forbidden.contains($0) }
            let cleaned = String(String.UnicodeScalarView(filteredScalars))
                .trimmingCharacters(in: .whitespaces)
            let truncated = String(cleaned.prefix(31)).trimmingCharacters(in: .whitespaces)
            return truncated.isEmpty ? "RufusMac" : truncated
        }
    }
}
