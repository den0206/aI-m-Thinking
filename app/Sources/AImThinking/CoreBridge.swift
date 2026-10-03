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
        case .unavailable: String(localized: "Core unavailable")
        case .starting: String(localized: "Starting")
        case .handshaking: String(localized: "Connecting")
        case .monitoring: String(localized: "Monitoring")
        case .stopped: String(localized: "Stopped")
        case .failed(let code):
            code == "CORE_RETRY_LIMIT" ? String(localized: "Monitor failed — restart to retry") : String(localized: "Error \(code)")
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
    private var handshakeTask: Task<Void, Never>?
    private var retryCount = 0
    private var monitoringSince: ContinuousClock.Instant?
    private let handshakeTimeout: Duration
    private let retryDelay: Duration
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

    init(rootProvider: any AgentRootProviding = DirectAgentRootProvider(), executableURL: URL? = nil,
         handshakeTimeout: Duration = .seconds(5), retryDelay: Duration = .seconds(1)) {
        self.rootProvider = rootProvider
        self.executableURL = executableURL
        self.handshakeTimeout = handshakeTimeout
        self.retryDelay = retryDelay
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
                    self.recover("CORE_EXIT")
                }
            }
        }

        do {
            try process.run()
            self.process = process
            input = stdinPipe.fileHandleForWriting
            onStatus?(.handshaking)
            handshakeTask = Task { @MainActor [weak self, handshakeTimeout] in
                try? await Task.sleep(for: handshakeTimeout)
                guard !Task.isCancelled, let self, self.generation == generation else { return }
                self.recover("CORE_TIMEOUT")
            }
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            log("monitor launch failed")
            recover("CORE_LAUNCH")
        }
    }

    func restart() {
        stop(force: true)
        retryCount = 0
        monitoringSince = nil

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
        handshakeTask?.cancel()
        handshakeTask = nil
        generation &+= 1
        log("monitor stop force=\(force)")
        intentionalStop = true
        send(["v": 1, "type": "shutdown"])

        if let process, force, process.isRunning {
            process.terminate()
            // Do not leave a hung helper behind when it ignores termination.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        self.process = nil
        input = nil
        onStatus?(.stopped)
    }

    private func recover(_ code: String) {
        if let monitoringSince, monitoringSince.duration(to: .now) >= .seconds(60) {
            retryCount = 0
        }
        monitoringSince = nil
        stop(force: true)
        log("monitor failure code=\(code) retry=\(retryCount)")
        guard retryCount < 3 else {
            onStatus?(.failed("CORE_RETRY_LIMIT"))
            return
        }
        retryCount += 1
        onStatus?(.failed(code))
        let delay = retryDelay * retryCount
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)

        guard outputBuffer.count <= 64 * 1024 else {
            outputBuffer.removeAll(keepingCapacity: false)
            recover("IPC_BUFFER")
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

            let currentGeneration = generation
            handle(message)
            if generation != currentGeneration { return }
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
            recover("IPC1001")
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
            handshakeTask?.cancel()
            handshakeTask = nil
            monitoringSince = .now
            onStatus?(.monitoring)
        case "error":
            if message.recoverable == false {
                recover(message.code ?? "CORE")
                return
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
            if !intentionalStop { recover("IPC_WRITE") }
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
