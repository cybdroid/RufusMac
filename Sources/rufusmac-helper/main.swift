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
        data.append(0x0A)
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
    var exitFilePath: String?

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--job":
            if i + 1 < args.count { jobPath = args[i + 1]; i += 1 }
        case "--events":
            if i + 1 < args.count { eventsPath = args[i + 1]; i += 1 }
        case "--cancel-flag":
            if i + 1 < args.count { cancelFlagPath = args[i + 1]; i += 1 }
        case "--exit-file":
            if i + 1 < args.count { exitFilePath = args[i + 1]; i += 1 }
        case "--version":
            print("rufusmac-helper 1.2.0")
            return 0
        default:
            break
        }
        i += 1
    }

    func finish(_ code: Int32) -> Int32 {
        if let ef = exitFilePath {
            try? "\(code)".write(toFile: ef, atomically: true, encoding: .utf8)
        }
        return code
    }

    guard let jobFile = jobPath else {
        fputs("Usage: rufusmac-helper --job <job.json> [--events <events.jsonl>] [--cancel-flag <cancel.flag>] [--exit-file <exit.txt>]\n", stderr)
        return finish(64)
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
        return finish(0)
    } catch FlashEngineError.cancelled {
        writer.emit(FlashProgressEvent(kind: .cancelled, stage: "Abgebrochen", message: "Vorgang wurde abgebrochen."))
        return finish(2)
    } catch let err as FlashEngineError {
        let msg = err.localizedDescription
        let code: Int32
        if case .fullDiskAccessRequired = err {
            code = 13 // EACCES sentinel
        } else {
            code = 1
        }
        writer.emit(FlashProgressEvent(kind: .failed, stage: "Fehler", message: msg))
        fputs("\(msg)\n", stderr)
        return finish(code)
    } catch {
        let msg = error.localizedDescription
        writer.emit(FlashProgressEvent(kind: .failed, stage: "Fehler", message: msg))
        fputs("\(msg)\n", stderr)
        return finish(1)
    }
}

exit(runHelper())
