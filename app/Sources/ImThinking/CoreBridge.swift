import Foundation

enum CoreStatus: Equatable {
    case unavailable
    case starting
    case handshaking
    case monitoring
    case stopped
    case failed(String)

    var label: String {
        switch self {
        case .unavailable: "Core unavailable"
        case .starting: "Starting"
        case .handshaking: "Connecting"
        case .monitoring: "Monitoring"
        case .stopped: "Stopped"
        case .failed(let code): "Error \(code)"
        }
    }
}

@MainActor
final class CoreBridge {
    var onMessage: ((CoreMessage) -> Void)?
    var onStatus: ((CoreStatus) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var intentionalStop = false

    func start() {
        guard process == nil else { return }
        guard let executable = Self.coreExecutableURL() else {
            onStatus?(.unavailable)
            return
        }

        intentionalStop = false
        onStatus?(.starting)

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executable
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }

            Task { @MainActor [weak self] in
                self?.consume(data)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil
                self.input = nil
                self.outputBuffer.removeAll(keepingCapacity: false)
                if !self.intentionalStop {
                    self.onStatus?(.stopped)
                }
            }
        }

        do {
            try process.run()
            self.process = process
            input = stdinPipe.fileHandleForWriting
            onStatus?(.handshaking)
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            onStatus?(.failed("CORE_LAUNCH"))
        }
    }

    func restart() {
        stop(force: true)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.start()
        }
    }

    func rescan() {
        send(["v": 1, "type": "rescan"])
    }

    func stop(force: Bool = false) {
        intentionalStop = true
        send(["v": 1, "type": "shutdown"])

        guard let process else { return }
        if force, process.isRunning {
            process.terminate()
        }
        self.process = nil
        input = nil
        onStatus?(.stopped)
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)

        guard outputBuffer.count <= 64 * 1024 else {
            outputBuffer.removeAll(keepingCapacity: false)
            onStatus?(.failed("IPC_BUFFER"))
            return
        }

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)

            guard !line.isEmpty,
                  line.count <= 32 * 1024,
                  let message = try? JSONDecoder().decode(CoreMessage.self, from: Data(line))
            else {
                continue
            }

            handle(message)
        }
    }

    private func handle(_ message: CoreMessage) {
        guard message.version == 1 else {
            onStatus?(.failed("IPC1001"))
            return
        }

        switch message.type {
        case "hello":
            send([
                "v": 1,
                "type": "configure",
                "agents": ["claude": true, "codex": true],
                "extra_roots": []
            ])
        case "ready":
            onStatus?(.monitoring)
        case "error":
            if message.recoverable == false {
                onStatus?(.failed(message.code ?? "CORE"))
            }
        default:
            break
        }

        onMessage?(message)
    }

    private func send(_ object: [String: Any]) {
        guard let input,
              JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object)
        else {
            return
        }

        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            onStatus?(.failed("IPC_WRITE"))
        }
    }

    private static func coreExecutableURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["IM_THINKING_CORE_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/im-thinking-core")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }
}
