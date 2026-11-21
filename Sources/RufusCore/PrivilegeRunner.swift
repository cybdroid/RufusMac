import Foundation
import Security
import Darwin

public enum PrivilegeRunnerError: LocalizedError {
    case helperBinaryNotFound
    case authorizationCancelled
    case authorizationFailed(OSStatus)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .helperBinaryNotFound:
            return "Interner Helper 'rufusmac-helper' wurde im App-Bundle nicht gefunden."
        case .authorizationCancelled:
            return "Administrator-Authentifizierung wurde abgebrochen."
        case .authorizationFailed(let status):
            return "Administrator-Authentifizierung fehlgeschlagen (Status \(status))."
        case .executionFailed(let msg):
            return msg
        }
    }
}

/// Orchestrates FlashEngine jobs cleanly on macOS:
/// - Standard GPT/UEFI Windows & Linux ISO flashing (FAT32 Auto-WIM-Split, Dual-Partition ExFAT) and Non-Bootable formatting
///   run 100% natively IN-PROCESS via Apple's `diskutil` (`diskmanagementd`) — ZERO password prompt, ZERO raw `/dev/rdiskN` open, ZERO TCC failures!
/// - MBR Legacy BIOS boot-sector stamping (`ms-sys`) runs as a quick Phase 2 via Security.framework's `AuthorizationExecuteWithPrivileges`
///   after Phase 1 finishes copying & splitting files unprivileged!
/// - DD Raw Image mode & custom cluster size invoke `rufusmac-helper` directly via `AuthorizationExecuteWithPrivileges` (NOT `osascript`)
///   with `/private/tmp` FIFO streaming so `~/Downloads` is never touched by root.
public final class PrivilegeRunner {
    private var workDir: URL?
    private var cancelFlagURL: URL?
    private var eventsURL: URL?
    private var rawFifoURL: URL?
    private var preMountedISO: MountedImageInfo?
    private var pollTimer: DispatchSourceTimer?
    private var readOffset: UInt64 = 0
    private var partialLineBuffer = Data()
    private var lastHelperFailureMessage: String?
    private var sleepActivity: NSObjectProtocol?
    private var isStoppingFifo = false
    private var inProcessCancelled = false
    private let cancelLock = NSLock()
    private let stateQueue = DispatchQueue(label: "dev.rufusmac.privilegerunner")

    public init() {}

    public static func locateHelperBinary() -> String? {
        var candidates: [String] = []
        let bundleHelpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rufusmac-helper").path
        candidates.append(bundleHelpers)
        if let execPath = Bundle.main.executablePath {
            let execDir = (execPath as NSString).deletingLastPathComponent
            candidates.append((execDir as NSString).appendingPathComponent("rufusmac-helper"))
            candidates.append(((execDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Helpers/rufusmac-helper"))
        }
        let fm = FileManager.default
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    public static func locateHelpersDirectory() -> String? {
        if let helperBin = locateHelperBinary() {
            return (helperBin as NSString).deletingLastPathComponent
        }
        return nil
    }

    private func isJobCancelled() -> Bool {
        cancelLock.lock()
        let c = inProcessCancelled
        cancelLock.unlock()
        return c
    }

    public func start(
        config: FlashJobConfig,
        onEvent: @escaping (FlashProgressEvent) -> Void,
        onFinish: @escaping (Result<Void, Error>) -> Void
    ) {
        cancelLock.lock()
        inProcessCancelled = false
        cancelLock.unlock()
        isStoppingFifo = false
        lastHelperFailureMessage = nil

        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "RufusMac is writing a bootable USB drive"
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.runPipeline(config: config, onEvent: onEvent, onFinish: onFinish)
        }
    }

    private func runPipeline(
        config: FlashJobConfig,
        onEvent: @escaping (FlashProgressEvent) -> Void,
        onFinish: @escaping (Result<Void, Error>) -> Void
    ) {
        defer { cleanup() }

        let resolvedHelpersDir = config.helpersDirectory ?? Self.locateHelpersDirectory()

        // PATH A: Runs completely IN-PROCESS without root/osascript/Full Disk Access!
        // Covers: GPT (UEFI) FAT32 Auto-WIM-Split, GPT Dual-Partition ExFAT, GPT ExFAT, Non-Bootable Format!
        if !FlashEngine.requiresRootForWholeJob(config) {
            let needsMBRPhase2 = FlashEngine.needsMBRBootSectorPhase2(config)

            let phase1Config = FlashJobConfig(
                targetDeviceIdentifier: config.targetDeviceIdentifier,
                bootMode: config.bootMode,
                writeMode: config.writeMode,
                isoPath: config.isoPath,
                preMountedISOPath: config.preMountedISOPath,
                rawFifoPath: nil,
                rawInputSizeBytes: nil,
                isoKind: config.isoKind,
                partitionScheme: config.partitionScheme,
                fileSystem: config.fileSystem,
                volumeLabel: config.volumeLabel,
                clusterSize: config.clusterSize,
                quickFormat: config.quickFormat,
                wipePartitionTable: config.wipePartitionTable,
                autoEjectAfterFlash: needsMBRPhase2 ? false : config.autoEjectAfterFlash,
                windowsOptions: config.windowsOptions,
                helpersDirectory: resolvedHelpersDir,
                allowDiskImageTarget: config.allowDiskImageTarget,
                skipMBRBootSectorWrite: needsMBRPhase2,
                onlyWriteMBRBootSectors: false
            )

            do {
                let engine = FlashEngine(
                    emit: onEvent,
                    isCancelled: { [weak self] in self?.isJobCancelled() ?? false }
                )
                try engine.execute(config: phase1Config)

                // If no MBR Phase 2 needed, we are 100% done!
                if !needsMBRPhase2 {
                    onFinish(.success(()))
                    return
                }

                // PATH A2: MBR Phase 2 — quick privileged NT6 MBR/VBR boot-sector stamp via Security.framework
                if isJobCancelled() {
                    onFinish(.failure(FlashEngineError.cancelled))
                    return
                }

                guard let helperPath = Self.locateHelperBinary() else {
                    onFinish(.failure(PrivilegeRunnerError.helperBinaryNotFound))
                    return
                }

                onEvent(FlashProgressEvent(
                    kind: .stage,
                    stage: "Administrator-Freigabe für MBR-Bootsektor…",
                    fraction: 0.92,
                    message: "Dateien vollständig geschrieben. Bestätige für Legacy-BIOS MBR/VBR-Bootsektor…"
                ))

                let phase2Config = FlashJobConfig(
                    targetDeviceIdentifier: config.targetDeviceIdentifier,
                    bootMode: config.bootMode,
                    writeMode: config.writeMode,
                    isoPath: nil,
                    isoKind: config.isoKind,
                    partitionScheme: .mbr,
                    fileSystem: config.fileSystem,
                    volumeLabel: config.volumeLabel,
                    clusterSize: .automatic,
                    quickFormat: true,
                    wipePartitionTable: false,
                    autoEjectAfterFlash: config.autoEjectAfterFlash,
                    windowsOptions: WindowsCustomizationOptions(),
                    helpersDirectory: resolvedHelpersDir,
                    allowDiskImageTarget: config.allowDiskImageTarget,
                    skipMBRBootSectorWrite: false,
                    onlyWriteMBRBootSectors: true
                )

                try runPrivilegedHelper(helperPath: helperPath, config: phase2Config, onEvent: onEvent)
                onFinish(.success(()))
            } catch {
                onFinish(.failure(error))
            }
            return
        }

        // PATH B: Whole job requires privileged helper (DD Raw Image Mode or Custom Cluster Size)
        guard let helperPath = Self.locateHelperBinary() else {
            onFinish(.failure(PrivilegeRunnerError.helperBinaryNotFound))
            return
        }

        do {
            let dir = URL(fileURLWithPath: "/private/tmp")
                .appendingPathComponent("rufusmac-job-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            self.workDir = dir

            var preMountedPath: String? = nil
            var fifoPath: String? = nil
            var rawSize: Int64? = nil

            if config.bootMode == .isoOrImage, let isoPath = config.isoPath, !isoPath.isEmpty {
                if config.writeMode == .isoFileCopy {
                    onEvent(FlashProgressEvent(kind: .stage, stage: "Hänge ISO-Abbild ein…", fraction: 0.02, message: "Hänge ISO-Abbild im Benutzerkontext ein…"))
                    let mounted = try ISOInspector.attachReadOnly(isoPath: isoPath, preferReuseExisting: true)
                    self.preMountedISO = mounted
                    preMountedPath = mounted.mountPoint
                } else {
                    let attrs = try FileManager.default.attributesOfItem(atPath: isoPath)
                    rawSize = (attrs[.size] as? Int64) ?? 0
                    let fifoURL = dir.appendingPathComponent("raw.fifo")
                    guard mkfifo(fifoURL.path, 0o666) == 0 else {
                        throw FlashEngineError.ioError("Konnte FIFO-Pipe nicht erstellen: \(String(cString: strerror(errno)))")
                    }
                    chmod(fifoURL.path, 0o666)
                    self.rawFifoURL = fifoURL
                    fifoPath = fifoURL.path
                    startRawFifoFeeder(sourcePath: isoPath, fifoPath: fifoURL.path)
                }
            }

            let enriched = FlashJobConfig(
                targetDeviceIdentifier: config.targetDeviceIdentifier,
                bootMode: config.bootMode,
                writeMode: config.writeMode,
                isoPath: config.isoPath,
                preMountedISOPath: preMountedPath,
                rawFifoPath: fifoPath,
                rawInputSizeBytes: rawSize,
                isoKind: config.isoKind,
                partitionScheme: config.partitionScheme,
                fileSystem: config.fileSystem,
                volumeLabel: config.volumeLabel,
                clusterSize: config.clusterSize,
                quickFormat: config.quickFormat,
                wipePartitionTable: config.wipePartitionTable,
                autoEjectAfterFlash: config.autoEjectAfterFlash,
                windowsOptions: config.windowsOptions,
                helpersDirectory: resolvedHelpersDir,
                allowDiskImageTarget: config.allowDiskImageTarget
            )

            try runPrivilegedHelper(helperPath: helperPath, config: enriched, existingWorkDir: dir, onEvent: onEvent)
            onFinish(.success(()))
        } catch {
            onFinish(.failure(error))
        }
    }

    // MARK: - Native Security.framework AuthorizationExecuteWithPrivileges (NO osascript!)

    private typealias AuthExecFn = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private func runPrivilegedHelper(
        helperPath: String,
        config: FlashJobConfig,
        existingWorkDir: URL? = nil,
        onEvent: @escaping (FlashProgressEvent) -> Void
    ) throws {
        let dir: URL
        if let existing = existingWorkDir {
            dir = existing
        } else {
            dir = URL(fileURLWithPath: "/private/tmp")
                .appendingPathComponent("rufusmac-job-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            self.workDir = dir
        }

        let jobURL = dir.appendingPathComponent("job.json")
        let eventsFileURL = dir.appendingPathComponent("events.jsonl")
        let cancelURL = dir.appendingPathComponent("cancel.flag")
        let exitFileURL = dir.appendingPathComponent("exit.txt")

        self.eventsURL = eventsFileURL
        self.cancelFlagURL = cancelURL
        self.readOffset = 0
        self.partialLineBuffer = Data()
        self.lastHelperFailureMessage = nil

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(config).write(to: jobURL)

        FileManager.default.createFile(atPath: eventsFileURL.path, contents: Data(), attributes: [.posixPermissions: 0o666])
        chmod(eventsFileURL.path, 0o666)
        FileManager.default.createFile(atPath: exitFileURL.path, contents: Data(), attributes: [.posixPermissions: 0o666])
        chmod(exitFileURL.path, 0o666)

        onEvent(FlashProgressEvent(
            kind: .stage,
            stage: "Warte auf Administrator-Freigabe…",
            fraction: config.onlyWriteMBRBootSectors ? 0.92 : 0.03,
            message: "Bitte Administrator-Passwort oder Touch ID für RufusMac bestätigen…"
        ))

        // Create AuthorizationRef
        var authRef: AuthorizationRef?
        let createStatus = AuthorizationCreate(nil, nil, [], &authRef)
        guard createStatus == errAuthorizationSuccess, let auth = authRef else {
            throw PrivilegeRunnerError.authorizationFailed(createStatus)
        }
        defer { AuthorizationFree(auth, []) }

        // Request right to execute privileged helper
        let rightName = kAuthorizationRightExecute
        let copyStatus: OSStatus = rightName.withCString { cName in
            var item = AuthorizationItem(name: cName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
                return AuthorizationCopyRights(auth, &rights, nil, flags, nil)
            }
        }

        if copyStatus == errAuthorizationCanceled {
            throw PrivilegeRunnerError.authorizationCancelled
        }
        guard copyStatus == errAuthorizationSuccess else {
            throw PrivilegeRunnerError.authorizationFailed(copyStatus)
        }

        // Load AuthorizationExecuteWithPrivileges dynamically (clean, zero Swift deprecation errors)
        guard let secHandle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(secHandle, "AuthorizationExecuteWithPrivileges") else {
            throw PrivilegeRunnerError.executionFailed("Security.framework AuthorizationExecuteWithPrivileges nicht verfügbar.")
        }
        let execFn = unsafeBitCast(sym, to: AuthExecFn.self)

        startPollingEvents(onEvent: onEvent)

        let cliArgs = [
            "--job", jobURL.path,
            "--events", eventsFileURL.path,
            "--cancel-flag", cancelURL.path,
            "--exit-file", exitFileURL.path
        ]
        var cArgs: [UnsafeMutablePointer<CChar>?] = cliArgs.map { strdup($0) }
        cArgs.append(nil)
        defer {
            for ptr in cArgs { if let p = ptr { free(p) } }
        }

        var commPipe: UnsafeMutablePointer<FILE>? = nil
        let execStatus = helperPath.withCString { cPath in
            cArgs.withUnsafeBufferPointer { buf in
                execFn(auth, cPath, [], buf.baseAddress!, &commPipe)
            }
        }

        if execStatus == errAuthorizationCanceled {
            stateQueue.sync { stopPollingEvents() }
            throw PrivilegeRunnerError.authorizationCancelled
        }
        guard execStatus == errAuthorizationSuccess else {
            stateQueue.sync { stopPollingEvents() }
            throw PrivilegeRunnerError.authorizationFailed(execStatus)
        }

        // Wait until helper closes stdout / exits by draining commPipe cleanly
        if let pipe = commPipe {
            var discard = [UInt8](repeating: 0, count: 4096)
            while fread(&discard, 1, discard.count, pipe) > 0 {
                // Keep draining until helper exits
            }
            fclose(pipe)
        }

        // Give helper a tiny moment to flush final exit code & events if pipe closed early
        for _ in 0..<20 {
            if let txt = try? String(contentsOf: exitFileURL, encoding: .utf8),
               !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        stateQueue.sync {
            stopPollingEvents()
            drainNewEvents(onEvent: onEvent)
        }

        let exitStr = (try? String(contentsOf: exitFileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let exitCode = Int32(exitStr) ?? (lastHelperFailureMessage == nil ? 0 : 1)

        if exitCode == 0 {
            return
        } else if exitCode == 2 || isJobCancelled() || FileManager.default.fileExists(atPath: cancelURL.path) {
            throw FlashEngineError.cancelled
        } else if exitCode == 13 {
            throw FlashEngineError.fullDiskAccessRequired(lastHelperFailureMessage ?? "Operation not permitted")
        } else {
            throw PrivilegeRunnerError.executionFailed(lastHelperFailureMessage ?? "Helper beendet mit Fehlercode \(exitCode).")
        }
    }

    public func cancel() {
        cancelLock.lock()
        inProcessCancelled = true
        cancelLock.unlock()

        isStoppingFifo = true
        if let cancelURL = cancelFlagURL {
            FileManager.default.createFile(atPath: cancelURL.path, contents: Data("1".utf8))
        }
        unblockFifoIfWaiting()
    }

    private func startRawFifoFeeder(sourcePath: String, fifoPath: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            signal(SIGPIPE, SIG_IGN)
            let inFD = open(sourcePath, O_RDONLY)
            guard inFD >= 0 else { return }
            defer { close(inFD) }

            let outFD = open(fifoPath, O_WRONLY)
            guard outFD >= 0 else { return }
            defer { close(outFD) }

            let chunkSize = 4 * 1024 * 1024
            let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 4096)
            defer { buf.deallocate() }

            while let self = self, !self.isStoppingFifo {
                let nRead = read(inFD, buf, chunkSize)
                if nRead <= 0 { break }

                var offset = 0
                while offset < nRead && !self.isStoppingFifo {
                    let nWrite = write(outFD, buf.advanced(by: offset), nRead - offset)
                    if nWrite <= 0 { return }
                    offset += nWrite
                }
            }
        }
    }

    private func unblockFifoIfWaiting() {
        guard let fifo = rawFifoURL?.path else { return }
        let fd = open(fifo, O_RDONLY | O_NONBLOCK)
        if fd >= 0 { close(fd) }
    }

    private func startPollingEvents(onEvent: @escaping (FlashProgressEvent) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.12)
        timer.setEventHandler { [weak self] in
            self?.drainNewEvents(onEvent: onEvent)
        }
        timer.resume()
        self.pollTimer = timer
    }

    private func stopPollingEvents() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func drainNewEvents(onEvent: @escaping (FlashProgressEvent) -> Void) {
        guard let url = eventsURL,
              let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }

        do {
            try fh.seek(toOffset: readOffset)
            let newData = fh.readDataToEndOfFile()
            guard !newData.isEmpty else { return }
            readOffset += UInt64(newData.count)
            partialLineBuffer.append(newData)

            let decoder = JSONDecoder()
            while let newlineIdx = partialLineBuffer.firstIndex(of: 0x0A) {
                let lineData = partialLineBuffer.subdata(in: 0..<newlineIdx)
                partialLineBuffer.removeSubrange(0...newlineIdx)
                if !lineData.isEmpty, let event = try? decoder.decode(FlashProgressEvent.self, from: lineData) {
                    if event.kind == .failed {
                        self.lastHelperFailureMessage = event.message
                    }
                    onEvent(event)
                }
            }
        } catch {}
    }

    private func cleanup() {
        isStoppingFifo = true
        unblockFifoIfWaiting()

        stateQueue.sync { stopPollingEvents() }

        if let mounted = preMountedISO {
            ISOInspector.detach(mounted)
            preMountedISO = nil
        }

        if let dir = workDir {
            try? FileManager.default.removeItem(at: dir)
        }
        workDir = nil
        eventsURL = nil
        cancelFlagURL = nil
        rawFifoURL = nil

        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}
