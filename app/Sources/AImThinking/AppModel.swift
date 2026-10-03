import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var coreStatus: CoreStatus = .stopped
    @Published private(set) var claudeState = "Waiting"
    @Published private(set) var codexState = "Waiting"
    /// nil means Random: a new pack is drawn whenever an agent starts a turn.
    @Published private(set) var soundPack: SoundPackID?
    @Published private(set) var volume: Double
    /// Typing speed multiplier; the slider's midpoint is the default.
    @Published private(set) var typingSpeed: Double
    static let typingSpeedRange = 0.6...1.8
    @Published private(set) var muted: Bool
    @Published private(set) var startAtLogin: Bool
    @Published private(set) var claudeFolderAuthorized = false
    @Published private(set) var codexFolderAuthorized = false

    let distributionMode: DistributionMode
    let keyPress = KeyPressAnimator()

    private let bridge: CoreBridge
    private let sandboxProvider: SandboxAgentRootProvider?
    private let audio: KeyboardAudioEngine
    private let scheduler: TypingScheduler
    private let defaults: UserDefaults
    private var activities: [UInt32: ActivityState] = [:]
    private var wakeTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, startMonitoring: Bool = true) {
        self.defaults = defaults
        let storedPack = defaults.string(forKey: "soundPack").flatMap(SoundPackID.init(rawValue:))
        let storedVolume = defaults.object(forKey: "volume") as? Double
        let initialVolume = max(0.0, min(1.0, storedVolume ?? 0.55))
        let storedSpeed = defaults.object(forKey: "typingSpeed") as? Double
        let initialSpeed = (storedSpeed ?? 1.2).clamped(to: Self.typingSpeedRange)
        let initialMuted = defaults.bool(forKey: "muted")
        let mode = DistributionMode.current

        let rootProvider: any AgentRootProviding
        let sandboxProvider: SandboxAgentRootProvider?
        switch mode {
        case .direct:
            rootProvider = DirectAgentRootProvider()
            sandboxProvider = nil
        case .appStore:
            let provider = SandboxAgentRootProvider(defaults: defaults)
            rootProvider = provider
            sandboxProvider = provider
        }

        distributionMode = mode
        self.sandboxProvider = sandboxProvider
        bridge = CoreBridge(rootProvider: rootProvider)

        soundPack = storedPack
        volume = initialVolume
        typingSpeed = initialSpeed
        muted = initialMuted
        startAtLogin = LoginItemManager.isEnabled

        let audio = KeyboardAudioEngine(pack: storedPack ?? SoundPackID.allCases.randomElement()!)
        audio.volume = initialVolume
        audio.muted = initialMuted
        self.audio = audio
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

    var requiresFolderAuthorization: Bool {
        distributionMode == .appStore
    }

    func authorizeFolder(for service: AgentService) {
        guard let sandboxProvider, sandboxProvider.chooseRoot(for: service) else {
            return
        }
        refreshAuthorizationState()
        restartCore()
    }

    func revokeFolder(for service: AgentService) {
        sandboxProvider?.revoke(service)
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

    private func resetActivity() {
        activities.removeAll(keepingCapacity: false)
        scheduler.stop()
        audio.stop()
        keyPress.update(active: false, intensity: 0)
        claudeState = "Waiting"
        codexState = "Waiting"
    }

    func selectSoundPack(_ pack: SoundPackID?) {
        soundPack = pack
        defaults.set(pack?.rawValue ?? "random", forKey: "soundPack")
        audio.setPack(pack ?? Self.randomPack(excluding: [audio.pack]))
        audio.preview()
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
    }

    func setMuted(_ newValue: Bool) {
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
            try LoginItemManager.setEnabled(enabled)
        } catch {
            // The OS remains the source of truth.
        }
        startAtLogin = LoginItemManager.isEnabled
    }

    private func refreshAuthorizationState() {
        claudeFolderAuthorized = sandboxProvider?.isAuthorized(.claude) ?? true
        codexFolderAuthorized = sandboxProvider?.isAuthorized(.codex) ?? true
    }

    func handle(_ message: CoreMessage) {
        if message.type == "session_closed", let session = message.session {
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

    private func updateGlobalAudio() {
        // The icon animates even when muted.
        let busy = activities.values.filter { $0.phase != "idle" && $0.intensity >= 0.06 }
        keyPress.update(active: !busy.isEmpty, intensity: busy.map(\.intensity).max() ?? 0)

        for agent in ["claude", "codex"] {
            let phase = activities.values
                .filter { $0.agent == agent && $0.phase != "idle" && $0.intensity >= 0.06 }
                .max(by: { $0.intensity < $1.intensity })?.phase ?? "idle"
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
}
