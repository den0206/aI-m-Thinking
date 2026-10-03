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

    private let rootProvider: any AgentRootProviding
    private let executableURL: URL?
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var intentionalStop = false
    private var generation = 0
    private var restartTask: Task<Void, Never>?
    private var diagnosticLines: [String] = []
    private var diagnosticBuffer = Data()
    private var lastActivity: [UInt32: String] = [:]

    var diagnosticLog: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return "aI'm Thinking \(version)\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nRecent diagnostics (up to 4000 entries; session content and paths excluded)\n"
            + "Current sessions:\n" + lastActivity.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n") + "\nEvents:\n"
            + diagnosticLines.joined(separator: "\n")
    }

    private func log(_ line: String) {
        diagnosticLines.append("\(Date().ISO8601Format()) \(line)")
        if diagnosticLines.count > 4000 {
            diagnosticLines.removeFirst(diagnosticLines.count - 4000)
        }
    }

    private func consumeDiagnostics(_ data: Data) {
        diagnosticBuffer.append(data)
        while let newline = diagnosticBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: diagnosticBuffer[..<newline], as: UTF8.self)
            diagnosticBuffer.removeSubrange(...newline)
            if line.hasPrefix("IM_DIAGNOSTIC ") { log(line) }
        }
        if diagnosticBuffer.count > 64 * 1024 { diagnosticBuffer.removeAll() }
    }

    init(rootProvider: any AgentRootProviding = DirectAgentRootProvider(), executableURL: URL? = nil) {
        self.rootProvider = rootProvider
        self.executableURL = executableURL
    }

    func start() {
        guard process == nil else { return }
        generation &+= 1
        let generation = generation
        log("monitor start")
        lastActivity.removeAll()
        diagnosticBuffer.removeAll()
        outputBuffer.removeAll()
        guard let executable = executableURL ?? Self.coreExecutableURL() else {
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

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.consumeDiagnostics(data)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }

            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.consume(data)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            let exitCode = terminated.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.log("monitor exit code=\(exitCode)")
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
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            log("monitor launch failed")
            onStatus?(.failed("CORE_LAUNCH"))
        }
    }

    func restart() {
        stop(force: true)

        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    func setSessionPaused(_ session: UInt32, paused: Bool) {
        send(["v": 1, "type": "set_session_paused", "session": session, "paused": paused])
    }

    func rescan() {
        send(["v": 1, "type": "rescan"])
    }

    func stop(force: Bool = false) {
        restartTask?.cancel()
        restartTask = nil
        generation &+= 1
        log("monitor stop force=\(force)")
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
                log("IPC decode failed")
                continue
            }

            handle(message)
        }
    }

    private func handle(_ message: CoreMessage) {
        let summary = "type=\(message.type) session=\(message.session.map(String.init) ?? "-") agent=\(message.agent ?? "-") phase=\(message.phase ?? "-") active=\((message.intensity ?? 0) >= 0.06) status=\(message.status ?? "-") code=\(message.code ?? "-")"
        if message.type == "activity", let session = message.session {
            if lastActivity[session] != summary { log(summary) }
            lastActivity[session] = summary
        } else {
            log(summary)
            if message.type == "session_closed", let session = message.session {
                lastActivity.removeValue(forKey: session)
            }
        }
        guard message.version == 1 else {
            onStatus?(.failed("IPC1001"))
            return
        }

        switch message.type {
        case "hello":
            let roots = rootProvider.roots()
            send([
                "v": 1,
                "type": "configure",
                "agents": ["claude": true, "codex": true],
                "roots": [
                    "claude": roots.claude.map(\.jsonObject),
                    "codex": roots.codex.map(\.jsonObject)
                ]
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
        #if DEBUG
        // Release builds only run the signed, bundled core.
        if let override = ProcessInfo.processInfo.environment["IM_THINKING_CORE_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        #endif

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/im-thinking-core")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }
}
