import Foundation
import SwiftUI
import AppKit
import RufusCore

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let text: String

    enum Level: Sendable {
        case info
        case stage
        case success
        case warning
        case error
    }
}

enum FlashRunState: Equatable {
    case idle
    case running
    case completed(String)
    case cancelled
    case failed(String)
}

@MainActor
final class AppViewModel: ObservableObject {
    // Language (German default, switchable to English)
    @Published var isGerman: Bool = true

    // Drives
    @Published var drives: [USBDrive] = []
    @Published var selectedDriveID: String?
    @Published var includeFixedExternalUSB: Bool = false {
        didSet { refreshDrives() }
    }
    @Published var isRefreshingDrives: Bool = false

    // Boot & Image
    @Published var bootMode: BootSelectionMode = .isoOrImage {
        didSet { handleBootModeChange() }
    }
    @Published var writeMode: WriteMode = .isoFileCopy
    @Published var isoAnalysis: ISOAnalysis?
    @Published var isInspectingISO: Bool = false
    @Published var isoInspectError: String?

    // Partition & Filesystem
    @Published var partitionScheme: PartitionScheme = .gpt
    @Published var fileSystem: FileSystemType = .fat32 {
        didSet {
            if fileSystem == .apfs {
                partitionScheme = .gpt
            }
        }
    }
    @Published var volumeLabel: String = "WIN11_USB"
    @Published var clusterSize: ClusterSize = .automatic
    @Published var quickFormat: Bool = true
    @Published var wipePartitionTable: Bool = true
    @Published var autoEjectAfterFlash: Bool = false

    // Windows 11 Customizations
    @Published var windowsOptions = WindowsCustomizationOptions()

    // Execution State
    @Published var runState: FlashRunState = .idle
    @Published var needsFullDiskAccessPrompt: Bool = false
    @Published var progressFraction: Double = 0.0
    @Published var currentStage: String = ""
    @Published var currentDetail: String = ""
    @Published var speedMBps: Double?
    @Published var elapsedSeconds: Int = 0
    @Published var logs: [LogEntry] = []

    // UI Sheets & Alerts
    @Published var showLogDrawer: Bool = false
    @Published var showConfirmAlert: Bool = false
    @Published var showChecksumSheet: Bool = false
    @Published var showAdvancedOptions: Bool = false
    @Published var isComputingChecksums: Bool = false
    @Published var checksumProgress: Double = 0.0
    @Published var computedChecksums: ImageChecksums?
    @Published var checksumError: String?

    private let hotPlugMonitor = DiskHotPlugMonitor()
    private let privilegeRunner = PrivilegeRunner()
    private var elapsedTimer: Timer?

    init() {
        appendLog(.info, isGerman ? "RufusMac gestartet (Intel x86_64 Engine bereit)." : "RufusMac started (Intel x86_64 engine ready).")
        refreshDrives()
        hotPlugMonitor.start { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self, self.runState != .running else { return }
                self.refreshDrives()
            }
        }
    }

    deinit {
        hotPlugMonitor.stop()
    }

    // MARK: - Computed Properties

    var selectedDrive: USBDrive? {
        drives.first { $0.id == selectedDriveID }
    }

    var availableFileSystems: [FileSystemType] {
        switch bootMode {
        case .isoOrImage:
            return FileSystemType.bootableCases
        case .nonBootable:
            return FileSystemType.formatOnlyCases
        }
    }

    var sanitizedVolumeLabelPreview: String {
        VolumeLabelSanitizer.sanitize(volumeLabel, for: fileSystem)
    }

    var isRunning: Bool {
        runState == .running
    }

    var isDDModeActive: Bool {
        bootMode == .isoOrImage && writeMode == .ddRawImage
    }

    var showWindowsOptionsCard: Bool {
        bootMode == .isoOrImage && writeMode == .isoFileCopy && isoAnalysis?.kind == .windowsISO
    }

    var canStart: Bool {
        guard !isRunning && !isInspectingISO else { return false }
        guard selectedDrive != nil else { return false }
        if bootMode == .isoOrImage {
            guard isoAnalysis != nil else { return false }
            // Block impossible FAT32 with >4GB ESD or non-WIM file
            if writeMode == .isoFileCopy && fileSystem == .fat32, let analysis = isoAnalysis {
                if analysis.installEsdExceedsFAT32 { return false }
                if analysis.exceedsFAT32Limit && !analysis.installWimNeedsSplit { return false }
            }
        }
        return true
    }

    var startBlockReason: String? {
        if selectedDrive == nil {
            return isGerman ? "Bitte USB-Laufwerk anschließen und auswählen" : "Please plug in and select a USB drive"
        }
        if bootMode == .isoOrImage && isoAnalysis == nil {
            return isGerman ? "Bitte eine ISO- oder Image-Datei auswählen" : "Please select an ISO or image file"
        }
        if bootMode == .isoOrImage && writeMode == .isoFileCopy && fileSystem == .fat32, let analysis = isoAnalysis {
            if analysis.installEsdExceedsFAT32 {
                return isGerman ? "install.esd > 4 GB: Bitte 'Dual-Partition' wählen" : "install.esd > 4 GB: Please choose Dual-Partition"
            }
            if analysis.exceedsFAT32Limit && !analysis.installWimNeedsSplit {
                return isGerman ? "Datei > 4 GB: Bitte ExFAT oder DD-Modus wählen" : "File > 4 GB: Please choose ExFAT or DD mode"
            }
        }
        return nil
    }

    // MARK: - Localization Helper

    func t(_ de: String, _ en: String) -> String {
        isGerman ? de : en
    }

    // MARK: - Drive Discovery

    func refreshDrives() {
        isRefreshingDrives = true
        let includeFixed = includeFixedExternalUSB
        Task.detached(priority: .userInitiated) {
            let discovered = (try? DiskDiscovery.discoverDrives(includeFixedExternalUSB: includeFixed)) ?? []
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.drives = discovered
                if let current = self.selectedDriveID, discovered.contains(where: { $0.id == current }) {
                    // keep selection
                } else {
                    self.selectedDriveID = discovered.first?.id
                }
                self.isRefreshingDrives = false
            }
        }
    }

    // MARK: - ISO Selection & Inspection

    func openISOFilePicker() {
        let panel = NSOpenPanel()
        panel.title = t("ISO- oder Disk-Image auswählen", "Select ISO or Disk Image")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "iso")!, .init(filenameExtension: "img")!, .init(filenameExtension: "raw")!, .init(filenameExtension: "bin")!].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url {
            selectISO(url: url)
        }
    }

    func selectISO(url: URL) {
        let path = url.path
        bootMode = .isoOrImage
        isInspectingISO = true
        isoInspectError = nil
        computedChecksums = nil
        checksumError = nil

        appendLog(.info, t("Analysiere Abbild: \(url.lastPathComponent)…", "Analyzing image: \(url.lastPathComponent)…"))

        Task.detached(priority: .userInitiated) {
            do {
                let analysis = try ISOInspector.inspect(filePath: path)
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.isoAnalysis = analysis
                    self.isInspectingISO = false
                    self.applySmartDefaults(for: analysis)
                    self.appendLog(.success, self.formatAnalysisSummary(analysis))
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.isInspectingISO = false
                    self.isoInspectError = error.localizedDescription
                    self.appendLog(.error, error.localizedDescription)
                }
            }
        }
    }

    func clearISO() {
        isoAnalysis = nil
        isoInspectError = nil
        computedChecksums = nil
        checksumError = nil
    }

    private func handleBootModeChange() {
        if bootMode == .isoOrImage && !FileSystemType.bootableCases.contains(fileSystem) {
            fileSystem = .fat32
        }
    }

    private func applySmartDefaults(for analysis: ISOAnalysis) {
        // Choose a clean, human-readable default volume label (avoiding cryptic UDF codes like CCCOMA_X64FRE or tmp names)
        let fileBase = URL(fileURLWithPath: analysis.filePath).deletingPathExtension().lastPathComponent
        let volUpper = analysis.volumeName.uppercased()
        let isCrypticVolume = volUpper.isEmpty
            || volUpper.hasPrefix("DMG.")
            || volUpper.hasPrefix("RUFUSMAC-ISO")
            || volUpper.hasPrefix("CCCOMA_")
            || volUpper.hasPrefix("ESD-ISO")
            || volUpper.hasPrefix("J_CCSA")
            || volUpper.hasPrefix("SSS_")
        let rawLabel = isCrypticVolume ? fileBase : analysis.volumeName

        if analysis.kind == .windowsISO {
            writeMode = .isoFileCopy
            if analysis.installEsdExceedsFAT32 {
                fileSystem = .dualFat32ExFAT
            } else {
                fileSystem = .fat32
            }
            partitionScheme = .gpt
            volumeLabel = VolumeLabelSanitizer.sanitize(rawLabel, for: fileSystem)
            // Windows 10 does not have TPM 2.0 / Secure Boot requirements — keep hardware bypass off by default for Win10
            if !analysis.isWindows11Likely {
                windowsOptions.bypassHardwareChecks = false
            }
        } else if analysis.kind == .rawDiskImage {
            writeMode = .ddRawImage
            volumeLabel = VolumeLabelSanitizer.sanitize(rawLabel, for: fileSystem)
        } else if analysis.kind == .linuxHybridISO {
            writeMode = analysis.hasHybridMBR ? .ddRawImage : .isoFileCopy
            if !FileSystemType.bootableCases.contains(fileSystem) {
                fileSystem = .fat32
            }
            volumeLabel = VolumeLabelSanitizer.sanitize(rawLabel, for: fileSystem)
        } else {
            writeMode = .isoFileCopy
            volumeLabel = VolumeLabelSanitizer.sanitize(rawLabel, for: fileSystem)
        }
    }

    private func formatAnalysisSummary(_ a: ISOAnalysis) -> String {
        switch a.kind {
        case .windowsISO:
            let wimNote = a.installWimNeedsSplit
                ? " | install.wim (\(a.formattedInstallImageSize)) > 4 GB -> Auto WIM-Split"
                : (a.installImageRelativePath != nil ? " | \(a.installImageRelativePath!) (\(a.formattedInstallImageSize))" : "")
            return "Windows ISO erkannt (\(a.windowsArchitecture ?? "x64"), \(a.formattedSize))\(wimNote)"
        case .linuxHybridISO:
            return "Linux / Hybrid-ISO erkannt (\(a.formattedSize), Hybrid-MBR: \(a.hasHybridMBR ? "Ja" : "Nein"))"
        case .rawDiskImage:
            return "Raw Disk-Image erkannt (\(a.formattedSize)) -> DD-Modus empfohlen"
        case .genericISO:
            return "ISO-Abbild geladen (\(a.formattedSize))"
        }
    }

    // MARK: - Checksums

    func computeChecksums() {
        guard let path = isoAnalysis?.filePath, !isComputingChecksums else { return }
        isComputingChecksums = true
        checksumProgress = 0
        checksumError = nil
        computedChecksums = nil

        Task.detached(priority: .userInitiated) {
            do {
                let result = try ISOInspector.computeChecksums(filePath: path) { pct in
                    Task { @MainActor [weak self] in
                        self?.checksumProgress = pct
                    }
                }
                await MainActor.run { [weak self] in
                    self?.computedChecksums = result
                    self?.isComputingChecksums = false
                    self?.checksumProgress = 1.0
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.checksumError = error.localizedDescription
                    self?.isComputingChecksums = false
                }
            }
        }
    }

    // MARK: - Flash Execution

    func requestStart() {
        guard canStart else { return }
        showConfirmAlert = true
    }

    func confirmAndStartFlash() {
        guard let drive = selectedDrive else { return }

        runState = .running
        needsFullDiskAccessPrompt = false
        progressFraction = 0.01
        currentStage = t("Initialisiere Flash-Vorgang…", "Initializing flash…")
        currentDetail = ""
        speedMBps = nil
        elapsedSeconds = 0
        startElapsedTimer()

        let config = FlashJobConfig(
            targetDeviceIdentifier: drive.deviceIdentifier,
            bootMode: bootMode,
            writeMode: writeMode,
            isoPath: bootMode == .isoOrImage ? isoAnalysis?.filePath : nil,
            isoKind: bootMode == .isoOrImage ? isoAnalysis?.kind : nil,
            partitionScheme: partitionScheme,
            fileSystem: fileSystem,
            volumeLabel: volumeLabel,
            clusterSize: clusterSize,
            quickFormat: quickFormat,
            wipePartitionTable: wipePartitionTable,
            autoEjectAfterFlash: autoEjectAfterFlash,
            windowsOptions: showWindowsOptionsCard ? windowsOptions : WindowsCustomizationOptions(),
            helpersDirectory: PrivilegeRunner.locateHelpersDirectory(),
            allowDiskImageTarget: false
        )

        appendLog(.stage, t(
            "Starte Flash-Vorgang auf /dev/\(drive.deviceIdentifier) (\(drive.mediaName), \(drive.formattedSize))…",
            "Starting flash on /dev/\(drive.deviceIdentifier) (\(drive.mediaName), \(drive.formattedSize))…"
        ))

        privilegeRunner.start(
            config: config,
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleProgressEvent(event)
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.handleFlashFinished(result)
                }
            }
        )
    }

    func cancelFlash() {
        guard isRunning else { return }
        currentStage = t("Breche Vorgang ab…", "Cancelling operation…")
        appendLog(.warning, t("Abbruch angefordert…", "Cancellation requested…"))
        privilegeRunner.cancel()
    }

    private func handleProgressEvent(_ event: FlashProgressEvent) {
        if let stage = event.stage {
            currentStage = stage
        }
        if let frac = event.fraction {
            progressFraction = frac
        }
        if let spd = event.speedMBps {
            speedMBps = spd
        }

        switch event.kind {
        case .stage:
            currentDetail = event.message
            appendLog(.stage, event.message)
        case .progress:
            currentDetail = event.message
        case .log:
            appendLog(.info, event.message)
        case .completed:
            progressFraction = 1.0
            currentDetail = event.message
            appendLog(.success, event.message)
        case .cancelled:
            appendLog(.warning, event.message)
        case .failed:
            appendLog(.error, event.message)
        }
    }

    private func handleFlashFinished(_ result: Result<Void, Error>) {
        stopElapsedTimer()
        switch result {
        case .success:
            progressFraction = 1.0
            runState = .completed(t("Bootfähiger USB-Stick erfolgreich erstellt!", "Bootable USB drive created successfully!"))
            currentStage = t("Fertig", "Done")
            NSSound(named: .init("Glass"))?.play()
        case .failure(let error):
            if let prErr = error as? PrivilegeRunnerError, case .authorizationCancelled = prErr {
                runState = .cancelled
                currentStage = t("Authentifizierung abgebrochen", "Authorization cancelled")
                appendLog(.warning, prErr.localizedDescription)
            } else if let feErr = error as? FlashEngineError, case .cancelled = feErr {
                runState = .cancelled
                currentStage = t("Abgebrochen", "Cancelled")
            } else if let feErr = error as? FlashEngineError, case .fullDiskAccessRequired = feErr {
                needsFullDiskAccessPrompt = true
                runState = .failed(feErr.localizedDescription)
                currentStage = t("Festplattenvollzugriff benötigt", "Full Disk Access required")
                appendLog(.error, feErr.localizedDescription)
            } else {
                runState = .failed(error.localizedDescription)
                currentStage = t("Fehlgeschlagen", "Failed")
                appendLog(.error, error.localizedDescription)
            }
        }
        refreshDrives()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Timer & Logs

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    var formattedElapsed: String {
        let mins = elapsedSeconds / 60
        let secs = elapsedSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    func appendLog(_ level: LogEntry.Level, _ text: String) {
        logs.append(LogEntry(timestamp: Date(), level: level, text: text))
    }

    func copyLogsToPasteboard() {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let combined = logs.map { "[\(df.string(from: $0.timestamp))] \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
    }
}
