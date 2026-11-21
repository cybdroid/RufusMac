import Foundation
import Darwin

public enum PrivilegeRunnerError: LocalizedError {
    case helperBinaryNotFound
    case authorizationCancelled
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .helperBinaryNotFound:
            return "Interner Helper 'rufusmac-helper' wurde im App-Bundle nicht gefunden."
        case .authorizationCancelled:
            return "Administrator-Authentifizierung wurde abgebrochen."
        case .executionFailed(let msg):
            return msg
        }
    }
}

/// Runs `rufusmac-helper` with macOS Administrator privileges while:
/// 1. Pre-mounting ISOs in the non-root GUI user's session (avoiding macOS TCC denials on ~/Downloads & ~/Desktop).
/// 2. Streaming raw DD images over a private `/tmp` FIFO from the GUI user to the root helper (zero TCC errors, zero extra disk space).
/// 3. Streaming live JSONL progress events and supporting instant cancellation without a second password prompt.
public final class PrivilegeRunner {
    private var workDir: URL?
    private var cancelFlagURL: URL?
    private var eventsURL: URL?
    private var rawFifoURL: URL?
    private var preMountedISO: MountedImageInfo?
    private var process: Process?
    private var pollTimer: DispatchSourceTimer?
    private var readOffset: UInt64 = 0
    private var partialLineBuffer = Data()
    private var lastHelperFailureMessage: String?
    private var sleepActivity: NSObjectProtocol?
    private var isStoppingFifo = false
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

    public func start(
        config: FlashJobConfig,
        onEvent: @escaping (FlashProgressEvent) -> Void,
        onFinish: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let helperPath = Self.locateHelperBinary() else {
            onFinish(.failure(PrivilegeRunnerError.helperBinaryNotFound))
            return
        }

        // Prevent macOS App Nap / idle sleep during long USB writes
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "RufusMac is writing a bootable USB drive"
        )

        // Do ISO mounting / job setup on background queue so UI never stalls
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.runPipeline(helperPath: helperPath, config: config, onEvent: onEvent, onFinish: onFinish)
        }
    }

    private func runPipeline(
        helperPath: String,
        config: FlashJobConfig,
        onEvent: @escaping (FlashProgressEvent) -> Void,
        onFinish: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            let dir = URL(fileURLWithPath: "/private/tmp")
                .appendingPathComponent("rufusmac-job-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

            let jobURL = dir.appendingPathComponent("job.json")
            let eventsFileURL = dir.appendingPathComponent("events.jsonl")
            let cancelURL = dir.appendingPathComponent("cancel.flag")

            self.workDir = dir
            self.eventsURL = eventsFileURL
            self.cancelFlagURL = cancelURL
            self.readOffset = 0
            self.partialLineBuffer = Data()
            self.lastHelperFailureMessage = nil
            self.isStoppingFifo = false

            var preMountedPath: String? = nil
            var fifoPath: String? = nil
            var rawSize: Int64? = nil

            if config.bootMode == .isoOrImage, let isoPath = config.isoPath, !isoPath.isEmpty {
                if config.writeMode == .isoFileCopy {
                    // Mount ISO in the GUI user's process & session (100% TCC-safe for ~/Downloads, ~/Desktop, etc.!)
                    onEvent(FlashProgressEvent(kind: .stage, stage: "Hänge ISO-Abbild ein…", fraction: 0.02, message: "Hänge ISO-Abbild im Benutzerkontext ein…"))
                    let mounted = try ISOInspector.attachReadOnly(isoPath: isoPath, preferReuseExisting: true)
                    self.preMountedISO = mounted
                    preMountedPath = mounted.mountPoint
                    onEvent(FlashProgressEvent(kind: .log, message: "ISO bereitgestellt unter: \(mounted.mountPoint) (Volume: \(mounted.volumeName))"))
                } else {
                    // DD Raw Image Mode: stream via /tmp FIFO from GUI user -> root helper (100% TCC-safe!)
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
                    onEvent(FlashProgressEvent(kind: .log, message: "DD-Datenstrom bereit (\(ByteCountFormatter.string(fromByteCount: rawSize ?? 0, countStyle: .decimal)))."))
                }
            }

            let enrichedConfig = FlashJobConfig(
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
                helpersDirectory: config.helpersDirectory ?? (helperPath as NSString).deletingLastPathComponent,
                allowDiskImageTarget: config.allowDiskImageTarget
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let jsonData = try encoder.encode(enrichedConfig)
            try jsonData.write(to: jobURL)

            FileManager.default.createFile(atPath: eventsFileURL.path, contents: Data(), attributes: [.posixPermissions: 0o666])
            chmod(eventsFileURL.path, 0o666)

            onEvent(FlashProgressEvent(kind: .stage, stage: "Warte auf Administrator-Freigabe…", fraction: 0.03, message: "Bitte Administrator-Passwort oder Touch ID bestätigen…"))

            startPollingEvents(onEvent: onEvent)

            let shellCmd = [
                shellQuote(helperPath),
                "--job", shellQuote(jobURL.path),
                "--events", shellQuote(eventsFileURL.path),
                "--cancel-flag", shellQuote(cancelURL.path)
            ].joined(separator: " ")

            let appleScript = "do shell script \"\(appleScriptEscape(shellCmd))\" with administrator privileges"

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", appleScript]
            let errPipe = Pipe()
            let outPipe = Pipe()
            proc.standardError = errPipe
            proc.standardOutput = outPipe
            self.process = proc

            try proc.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            let wasCancelled = FileManager.default.fileExists(atPath: cancelURL.path)

            self.stateQueue.sync {
                self.stopPollingEvents()
                self.drainNewEvents(onEvent: onEvent)
            }

            let status = proc.terminationStatus
            let rawErr = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let structuredHelperErr = self.lastHelperFailureMessage

            self.cleanup()

            if status == 0 {
                onFinish(.success(()))
            } else if rawErr.contains("-128")
                        || rawErr.localizedCaseInsensitiveContains("User canceled")
                        || rawErr.localizedCaseInsensitiveContains("Benutzer hat abgebrochen") {
                onFinish(.failure(PrivilegeRunnerError.authorizationCancelled))
            } else if wasCancelled {
                onFinish(.failure(FlashEngineError.cancelled))
            } else {
                let cleanMsg = structuredHelperErr ?? Self.cleanAppleScriptError(rawErr, exitCode: status)
                onFinish(.failure(PrivilegeRunnerError.executionFailed(cleanMsg)))
            }
        } catch {
            self.stateQueue.sync { self.stopPollingEvents() }
            self.cleanup()
            onFinish(.failure(error))
        }
    }

    public func cancel() {
        isStoppingFifo = true
        if let cancelURL = cancelFlagURL {
            FileManager.default.createFile(atPath: cancelURL.path, contents: Data("1".utf8))
        }
        unblockFifoIfWaiting()
    }

    private func startRawFifoFeeder(sourcePath: String, fifoPath: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Ignore SIGPIPE on broken pipe when helper finishes or cancels
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
        // Opening the read end non-blocking briefly releases a writer blocked in open(O_WRONLY)
        let fd = open(fifo, O_RDONLY | O_NONBLOCK)
        if fd >= 0 {
            close(fd)
        }
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
        } catch {
            // Ignore transient read errors
        }
    }

    private func cleanup() {
        isStoppingFifo = true
        unblockFifoIfWaiting()

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
        process = nil

        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    private static func cleanAppleScriptError(_ raw: String, exitCode: Int32) -> String {
        guard !raw.isEmpty else {
            return "Vorgang mit Fehlercode \(exitCode) beendet."
        }
        // Strip ugly "0:343: execution error: " prefix and trailing " (1)"
        var s = raw.replacingOccurrences(
            of: #"^\d+:\d+:\s*execution error:\s*"#,
            with: "",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\s*\(\d+\)\s*$"#,
            with: "",
            options: .regularExpression
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
