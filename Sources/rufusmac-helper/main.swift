import Foundation
import RufusCore

private final class EventWriter {
    private let fileHandle: FileHandle?
    private let encoder = JSONEncoder()
    private let lock = NSLock()

    init(path: String?) {
        if let path = path {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o666])
            }
            self.fileHandle = FileHandle(forWritingAtPath: path)
            _ = try? self.fileHandle?.seekToEnd()
        } else {
            self.fileHandle = nil
        }
    }

    func emit(_ event: FlashProgressEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A) // newline
        if let fh = fileHandle {
            fh.write(data)
            try? fh.synchronize()
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    deinit {
        try? fileHandle?.close()
    }
}

func runHelper() -> Int32 {
    let args = CommandLine.arguments
    var jobPath: String?
    var eventsPath: String?
    var cancelFlagPath: String?

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--job":
            if i + 1 < args.count { jobPath = args[i + 1]; i += 1 }
        case "--events":
            if i + 1 < args.count { eventsPath = args[i + 1]; i += 1 }
        case "--cancel-flag":
            if i + 1 < args.count { cancelFlagPath = args[i + 1]; i += 1 }
        case "--version":
            print("rufusmac-helper 1.0.0")
            return 0
        default:
            break
        }
        i += 1
    }

    guard let jobFile = jobPath else {
        fputs("Usage: rufusmac-helper --job <job.json> [--events <events.jsonl>] [--cancel-flag <cancel.flag>]\n", stderr)
        return 64
    }

    let writer = EventWriter(path: eventsPath)

    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: jobFile))
        let config = try JSONDecoder().decode(FlashJobConfig.self, from: data)

        let engine = FlashEngine(
            emit: { event in
                writer.emit(event)
            },
            isCancelled: {
                guard let flag = cancelFlagPath else { return false }
                return FileManager.default.fileExists(atPath: flag)
            }
        )

        try engine.execute(config: config)
        return 0
    } catch FlashEngineError.cancelled {
        writer.emit(FlashProgressEvent(kind: .cancelled, stage: "Abgebrochen", message: "Vorgang wurde abgebrochen."))
        return 2
    } catch {
        let msg = error.localizedDescription
        writer.emit(FlashProgressEvent(kind: .failed, stage: "Fehler", message: msg))
        fputs("\(msg)\n", stderr)
        return 1
    }
}

exit(runHelper())
