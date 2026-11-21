import Foundation

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

/// Runs `rufusmac-helper` with macOS Administrator privileges while streaming live JSONL progress events
/// and supporting instant non-privileged cancellation via a sentinel flag file.
public final class PrivilegeRunner {
    private var workDir: URL?
    private var cancelFlagURL: URL?
    private var eventsURL: URL?
    private var process: Process?
    private var pollTimer: DispatchSourceTimer?
    private var readOffset: UInt64 = 0
    private var partialLineBuffer = Data()
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

        do {
            let dir = URL(fileURLWithPath: "/tmp")
                .appendingPathComponent("rufusmac-job-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

            let jobURL = dir.appendingPathComponent("job.json")
            let eventsFileURL = dir.appendingPathComponent("events.jsonl")
            let cancelURL = dir.appendingPathComponent("cancel.flag")

            // Inject resolved helpers dir if not already set
            let enrichedConfig = FlashJobConfig(
                targetDeviceIdentifier: config.targetDeviceIdentifier,
                bootMode: config.bootMode,
                writeMode: config.writeMode,
                isoPath: config.isoPath,
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

            self.workDir = dir
            self.eventsURL = eventsFileURL
            self.cancelFlagURL = cancelURL
            self.readOffset = 0
            self.partialLineBuffer = Data()

            // Start tailing events.jsonl
            startPollingEvents(onEvent: onEvent)

            // Build safe shell command for osascript
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

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    try proc.run()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()

                    // Final drain of events.jsonl
                    self.stateQueue.sync {
                        self.stopPollingEvents()
                        self.drainNewEvents(onEvent: onEvent)
                    }

                    let status = proc.terminationStatus
                    let errStr = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                    self.cleanup()

                    if status == 0 {
                        onFinish(.success(()))
                    } else if errStr.contains("-128") || errStr.localizedCaseInsensitiveContains("User canceled") || errStr.localizedCaseInsensitiveContains("Benutzer hat abgebrochen") {
                        onFinish(.failure(PrivilegeRunnerError.authorizationCancelled))
                    } else if let cancelURL = self.cancelFlagURL, FileManager.default.fileExists(atPath: cancelURL.path) {
                        onFinish(.failure(FlashEngineError.cancelled))
                    } else {
                        onFinish(.failure(PrivilegeRunnerError.executionFailed(errStr.isEmpty ? "Vorgang mit Fehlercode \(status) beendet." : errStr)))
                    }
                } catch {
                    self.stateQueue.sync { self.stopPollingEvents() }
                    self.cleanup()
                    onFinish(.failure(error))
                }
            }
        } catch {
            cleanup()
            onFinish(.failure(error))
        }
    }

    public func cancel() {
        if let cancelURL = cancelFlagURL {
            FileManager.default.createFile(atPath: cancelURL.path, contents: Data("1".utf8))
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
                    onEvent(event)
                }
            }
        } catch {
            // Ignore transient read errors during rotation
        }
    }

    private func cleanup() {
        if let dir = workDir {
            try? FileManager.default.removeItem(at: dir)
        }
        workDir = nil
        eventsURL = nil
        cancelFlagURL = nil
        process = nil
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
