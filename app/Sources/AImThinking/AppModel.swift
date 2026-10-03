import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var coreStatus: CoreStatus = .stopped
    @Published private(set) var claudeState = "Waiting"
    @Published private(set) var codexState = "Waiting"
    @Published private(set) var pausedSessions: Set<UInt32> = []
    /// Agents whose transcripts the core could not understand, typically
    /// after a CLI update changed the format. Cleared when that agent shows
    /// activity again or monitoring restarts.
    @Published private(set) var unrecognizedAgents: Set<AgentService> = []
    /// nil means Random: a new pack is drawn whenever an agent starts a turn.
    @Published private(set) var soundPack: SoundPackID?
    /// The pack actually sounding, so Random can show what it drew.
    @Published private(set) var playingPack: SoundPackID
    @Published private(set) var volume: Double
    /// Typing speed multiplier; the slider's midpoint is the default.
    @Published private(set) var typingSpeed: Double
    static let typingSpeedRange = 0.3...2.1
    static let defaultTypingSpeed = 1.2
    @Published private(set) var muted: Bool
    static let defaultVolume = 0.55

    /// Slider labels read the default as 50% / ×1.0, scaled linearly on each side of it.
    static func volumeLabel(_ value: Double) -> String {
        "\(Int(value.pivoted(0...1, pivot: defaultVolume, to: 0...100, shownPivot: 50).rounded()))%"
    }

    static func typingSpeedLabel(_ value: Double) -> String {
        String(format: "×%.1f", value.pivoted(typingSpeedRange, pivot: defaultTypingSpeed, to: 0.2...2.0, shownPivot: 1.0))
    }
    @Published private(set) var startAtLogin: Bool
    @Published private(set) var loginItemMessage: String?
    @Published private(set) var observerStatuses: [AgentService: String] = [:]
    @Published private(set) var claudeFolderAuthorized = false
    @Published private(set) var codexFolderAuthorized = false
    /// Why the last folder a user chose for an agent was rejected.
    @Published private(set) var folderErrors: [AgentService: String] = [:]
    @Published private(set) var onboardingCompleted: Bool

    let distributionMode: DistributionMode
    let keyPress = KeyPressAnimator()

    private let bridge: CoreBridge
    private let rootProvider: any AgentRootProviding
    private let loginItemSetter: (Bool) throws -> Void
    private let audio: KeyboardAudioEngine
    private let scheduler: TypingScheduler
    private let defaults: UserDefaults
    private var activities: [UInt32: ActivityState] = [:]
    private var wakeTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, startMonitoring: Bool = true,
         distributionMode: DistributionMode = .current,
         loginItemSetter: @escaping (Bool) throws -> Void = LoginItemManager.setEnabled) {
        self.defaults = defaults
        self.loginItemSetter = loginItemSetter
        let storedPack = defaults.string(forKey: "soundPack").flatMap(SoundPackID.init(rawValue:))
        let storedVolume = defaults.object(forKey: "volume") as? Double
        let initialVolume = max(0.0, min(1.0, storedVolume ?? Self.defaultVolume))
        let storedSpeed = defaults.object(forKey: "typingSpeed") as? Double
        let initialSpeed = (storedSpeed ?? Self.defaultTypingSpeed).clamped(to: Self.typingSpeedRange)
        // A zero volume saved before mute followed the slider counts as muted.
        let initialMuted = defaults.bool(forKey: "muted") || initialVolume == 0
        let mode = distributionMode

        let rootProvider: any AgentRootProviding
        switch mode {
        case .direct:
            rootProvider = DirectAgentRootProvider(defaults: defaults)
        case .appStore:
            let provider = SandboxAgentRootProvider(defaults: defaults)
            rootProvider = provider
        }

        self.distributionMode = mode
        self.rootProvider = rootProvider
        bridge = CoreBridge(rootProvider: rootProvider)

        soundPack = storedPack
        volume = initialVolume
        typingSpeed = initialSpeed
        muted = initialMuted
        startAtLogin = LoginItemManager.isEnabled
        onboardingCompleted = defaults.bool(forKey: "onboardingCompleted")

        let audio = KeyboardAudioEngine(pack: storedPack ?? SoundPackID.allCases.randomElement()!)
        audio.volume = initialVolume
        audio.muted = initialMuted
        self.audio = audio
        playingPack = audio.pack
        scheduler = TypingScheduler(audio: audio)
        scheduler.speedScale = initialSpeed
        keyPress.speedScale = initialSpeed

        refreshAuthorizationState()

        bridge.onStatus = { [weak self] status in
            self?.coreStatus = status
            switch status {
            case .stopped, .failed, .unavailable:
                self?.resetActivity()
            default:
                break
            }
        }
        bridge.onMessage = { [weak self] message in
            self?.handle(message)
        }
        if startMonitoring {
            bridge.start()
        }

        if startMonitoring {
            wakeTask = Task { [weak self] in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(
                    named: NSWorkspace.didWakeNotification
                ) {
                    guard !Task.isCancelled else { return }
                    self?.bridge.rescan()
                }
            }
        }
    }

    deinit {
        wakeTask?.cancel()
    }

    /// Mute wins: nothing is heard, whatever is paused.
    var menuBarState: KeycapIcon.State? {
        if muted { return .muted }
        return pausedSessions.isEmpty ? nil : .paused
    }

    var requiresFolderAuthorization: Bool {
        distributionMode == .appStore
    }

    var monitorStatusLabel: String {
        guard coreStatus == .monitoring else { return coreStatus.label }
        if observerStatuses.values.contains("monitoring") { return "Monitoring" }
        if observerStatuses.values.contains("error") { return "Limited monitoring" }
        return observerStatuses.isEmpty ? "Checking folders" : "Check folders"
    }

    func observerProblem(for service: AgentService) -> String? {
        switch observerStatuses[service] {
        // An agent the user never set up has no folder; that is not a problem.
        case "directory_missing" where hasSavedFolder(for: service): "Folder missing"
        case "access_required" where hasSavedFolder(for: service): "Choose a folder"
        case "access_denied": "Folder access failed"
        case "error": "Using file polling"
        default: nil
        }
    }

    func authorizeFolder(for service: AgentService) {
        switch rootProvider.chooseRoot(for: service) {
        case .cancelled:
            return
        case .rejected(let message):
            folderErrors[service] = message
        case .granted:
            folderErrors[service] = nil
            refreshAuthorizationState()
            restartCore()
        }
    }

    func isFolderAuthorized(_ service: AgentService) -> Bool {
        switch service {
        case .claude: claudeFolderAuthorized
        case .codex: codexFolderAuthorized
        }
    }

    func hasSavedFolder(for service: AgentService) -> Bool {
        rootProvider.hasSavedRoot(service)
    }

    /// The App Store build can do nothing until at least one folder is allowed.
    var canFinishOnboarding: Bool {
        !requiresFolderAuthorization || claudeFolderAuthorized || codexFolderAuthorized
    }

    func completeOnboarding() {
        guard canFinishOnboarding, !onboardingCompleted else {
            return
        }
        onboardingCompleted = true
        defaults.set(true, forKey: "onboardingCompleted")
    }

    func revokeFolder(for service: AgentService) {
        rootProvider.revoke(service)
        folderErrors[service] = nil
        refreshAuthorizationState()
        restartCore()
    }

    func restartCore() {
        resetActivity()
        bridge.restart()
    }

    func stopCore() {
        resetActivity()
        bridge.stop()
    }

    func quit() {
        stopCore()
        NSApplication.shared.terminate(nil)
    }

    func copyDiagnosticLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bridge.diagnosticLog, forType: .string)
    }

    private func resetActivity() {
        pausedSessions.removeAll()
        activities.removeAll(keepingCapacity: false)
        scheduler.stop()
        audio.stop()
        keyPress.update(active: false, intensity: 0)
        claudeState = "Waiting"
        codexState = "Waiting"
        unrecognizedAgents.removeAll()
        observerStatuses.removeAll()
    }

    func selectSoundPack(_ pack: SoundPackID?) {
        soundPack = pack
        defaults.set(pack?.rawValue ?? "random", forKey: "soundPack")
        audio.setPack(pack ?? Self.randomPack(excluding: [audio.pack]))
        playingPack = audio.pack
        audio.preview { [weak self] in self?.scheduler.isRunning == true }
    }

    private static func randomPack(excluding used: [SoundPackID]) -> SoundPackID {
        SoundPackID.allCases.filter { !used.contains($0) }.randomElement()
            ?? SoundPackID.allCases.randomElement()!
    }

    func setTypingSpeed(_ newValue: Double) {
        typingSpeed = newValue.clamped(to: Self.typingSpeedRange)
        defaults.set(typingSpeed, forKey: "typingSpeed")
        scheduler.speedScale = typingSpeed
        keyPress.speedScale = typingSpeed
    }

    func setVolume(_ newValue: Double) {
        let value = max(0.0, min(1.0, newValue))
        volume = value
        defaults.set(value, forKey: "volume")
        audio.volume = value
        // The slider's bottom is mute; dragging up again unmutes.
        if (value == 0) != muted {
            setMuted(value == 0)
        }
    }

    func setMuted(_ newValue: Bool) {
        // Unmuting from a zeroed slider would stay silent; bring it back up.
        if !newValue, volume == 0 {
            volume = Self.defaultVolume
            defaults.set(volume, forKey: "volume")
            audio.volume = volume
        }
        muted = newValue
        defaults.set(newValue, forKey: "muted")
        audio.muted = newValue
        if newValue {
            scheduler.stop()
            audio.stop()
        }
        updateGlobalAudio()
    }

    func setStartAtLogin(_ enabled: Bool) {
        do {
            try loginItemSetter(enabled)
            loginItemMessage = LoginItemManager.approvalMessage
        } catch {
            loginItemMessage = "Could not change Start at Login: \(error.localizedDescription)"
        }
        startAtLogin = LoginItemManager.isEnabled
    }

    func refreshLoginStatus() {
        startAtLogin = LoginItemManager.isEnabled
        if let message = LoginItemManager.approvalMessage {
            loginItemMessage = message
        } else if startAtLogin {
            loginItemMessage = nil
        }
    }

    private func refreshAuthorizationState() {
        claudeFolderAuthorized = rootProvider.isAuthorized(.claude)
        codexFolderAuthorized = rootProvider.isAuthorized(.codex)
        if requiresFolderAuthorization {
            for service in AgentService.allCases {
                if !isFolderAuthorized(service), rootProvider.hasSavedRoot(service) {
                    folderErrors[service] = "Folder access is no longer available. Choose the folder again."
                } else {
                    folderErrors[service] = nil
                }
            }
        }
    }

    func handle(_ message: CoreMessage) {
        if message.type == "observer_status",
           let service = message.agent.flatMap(AgentService.init(rawValue:)),
           let status = message.status {
            observerStatuses[service] = status
            if status == "monitoring" {
                folderErrors[service] = nil
            } else if requiresFolderAuthorization,
                      ["access_required", "access_denied"].contains(status),
                      rootProvider.hasSavedRoot(service) {
                folderErrors[service] = "Folder access is no longer available. Choose the folder again."
            }
            if ["monitoring", "access_required", "access_denied", "directory_missing"].contains(status) {
                if service == .claude { claudeFolderAuthorized = status == "monitoring" }
                else { codexFolderAuthorized = status == "monitoring" }
            }
            if ["access_required", "access_denied", "directory_missing"].contains(status) {
                for (session, previous) in activities.filter({ $0.value.agent == service.rawValue }) {
                    activities[session] = ActivityState(agent: previous.agent, phase: "idle", intensity: 0,
                        toolClass: nil, pack: previous.pack)
                }
            }
            updateGlobalAudio()
            return
        }
        if message.type == "error", message.code == "PARSE3006",
           let agent = message.component.flatMap(AgentService.init(rawValue:)) {
            unrecognizedAgents.insert(agent)
            return
        }

        if message.type == "session_closed", let session = message.session {
            pausedSessions.remove(session)
            activities.removeValue(forKey: session)
            updateGlobalAudio()
            return
        }

        guard message.type == "activity",
              let session = message.session,
              let agent = message.agent,
              let phase = message.phase,
              let intensity = message.intensity
        else {
            return
        }
        if let service = AgentService(rawValue: agent), phase != "idle" {
            unrecognizedAgents.remove(service)
        }

        guard !pausedSessions.contains(session) else { return }

        // Each session draws its own pack when a turn starts, avoiding packs
        // other sessions are using so they stay distinguishable.
        let previous = activities[session]
        var pack = previous?.pack ?? audio.pack
        if phase != "idle", (previous?.phase ?? "idle") == "idle" {
            let taken = activities
                .filter { $0.key != session && $0.value.phase != "idle" }
                .map(\.value.pack)
            pack = Self.randomPack(excluding: taken + [pack])
        }

        activities[session] = ActivityState(
            agent: agent,
            phase: phase,
            intensity: intensity,
            toolClass: message.toolClass,
            pack: pack
        )

        updateGlobalAudio()
    }

    func isPaused(_ service: AgentService) -> Bool {
        activities.contains { $0.value.agent == service.rawValue && pausedSessions.contains($0.key) }
    }

    func pauseSessions(for service: AgentService) {
        let sessions = activities.filter { $0.value.agent == service.rawValue && !pausedSessions.contains($0.key)
            && $0.value.phase != "idle" && $0.value.intensity >= 0.06 }.keys
        for session in sessions {
            pausedSessions.insert(session)
            bridge.setSessionPaused(session, paused: true)
        }
        updateGlobalAudio()
    }

    func resumeSessions(for service: AgentService) {
        for session in pausedSessions.filter({ activities[$0]?.agent == service.rawValue }) {
            pausedSessions.remove(session)
            if let previous = activities[session] {
                activities[session] = ActivityState(agent: previous.agent, phase: "idle", intensity: 0,
                    toolClass: nil, pack: previous.pack)
            }
            bridge.setSessionPaused(session, paused: false)
        }
        updateGlobalAudio()
    }

    private func updateGlobalAudio() {
        let monitored = activities.filter { !pausedSessions.contains($0.key) }.map(\.value)
        let busy = monitored.filter { $0.phase != "idle" && $0.intensity >= 0.06 }
        // A still keycap printed "muted" reads as silenced.
        keyPress.update(active: !muted && !busy.isEmpty, intensity: busy.map(\.intensity).max() ?? 0)

        for service in AgentService.allCases {
            let agent = service.rawValue
            let phase = monitored
                .filter { $0.agent == agent && $0.phase != "idle" && $0.intensity >= 0.06 }
                .max(by: { $0.intensity < $1.intensity })?.phase ?? (isPaused(service) ? "paused" : "idle")
            if agent == "claude" { claudeState = phase.capitalized }
            else { codexState = phase.capitalized }
        }

        guard !muted,
              let strongest = busy
                .filter({ TypingScheduler.keysPerSecond(
                    intensity: $0.intensity, phase: $0.phase, toolClass: $0.toolClass
                ) > 0 })
                .max(by: { $0.intensity < $1.intensity })
        else {
            scheduler.stop()
            audio.stop()
            return
        }

        // Only the strongest session is heard, in its own pack.
        if strongest.phase != "idle" {
            audio.setPack(soundPack ?? strongest.pack)
            if playingPack != audio.pack { playingPack = audio.pack }
        }
        scheduler.update(
            phase: strongest.phase,
            intensity: strongest.intensity,
            toolClass: strongest.toolClass
        )
    }
}

private struct ActivityState {
    let agent: String
    let phase: String
    let intensity: Double
    let toolClass: String?
    let pack: SoundPackID
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }

    /// Maps `range` onto `shown` piecewise-linearly so that `pivot` lands on `shownPivot`.
    func pivoted(_ range: ClosedRange<Double>, pivot: Double, to shown: ClosedRange<Double>, shownPivot: Double) -> Double {
        self <= pivot
            ? shown.lowerBound + (self - range.lowerBound) / (pivot - range.lowerBound) * (shownPivot - shown.lowerBound)
            : shownPivot + (self - pivot) / (range.upperBound - pivot) * (shown.upperBound - shownPivot)
    }
}
