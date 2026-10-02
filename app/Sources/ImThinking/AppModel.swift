import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var coreStatus: CoreStatus = .stopped
    @Published private(set) var claudeState = "Waiting"
    @Published private(set) var codexState = "Waiting"
    @Published private(set) var soundPack: SoundPackID
    @Published private(set) var volume: Double
    @Published private(set) var muted: Bool
    @Published private(set) var startAtLogin: Bool
    @Published private(set) var claudeFolderAuthorized = false
    @Published private(set) var codexFolderAuthorized = false

    let distributionMode: DistributionMode

    private let bridge: CoreBridge
    private let sandboxProvider: SandboxAgentRootProvider?
    private let audio: KeyboardAudioEngine
    private let scheduler: TypingScheduler
    private var activities: [UInt32: ActivityState] = [:]
    private var wakeTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let storedPack = defaults.string(forKey: "soundPack").flatMap(SoundPackID.init(rawValue:))
        let initialPack = storedPack ?? .laptop
        let storedVolume = defaults.object(forKey: "volume") as? Double
        let initialVolume = max(0.0, min(1.0, storedVolume ?? 0.55))
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

        soundPack = initialPack
        volume = initialVolume
        muted = initialMuted
        startAtLogin = LoginItemManager.isEnabled

        let audio = KeyboardAudioEngine(pack: initialPack)
        audio.volume = initialVolume
        audio.muted = initialMuted
        self.audio = audio
        scheduler = TypingScheduler(audio: audio)

        refreshAuthorizationState()

        bridge.onStatus = { [weak self] status in
            self?.coreStatus = status
        }
        bridge.onMessage = { [weak self] message in
            self?.handle(message)
        }
        bridge.start()

        wakeTask = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didWakeNotification
            ) {
                guard !Task.isCancelled else { return }
                self?.bridge.rescan()
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
        activities.removeAll(keepingCapacity: false)
        scheduler.stop()
        bridge.restart()
    }

    func rescanAgents() {
        bridge.rescan()
    }

    func stopCore() {
        scheduler.stop()
        audio.stop()
        bridge.stop()
    }

    func selectSoundPack(_ pack: SoundPackID) {
        soundPack = pack
        UserDefaults.standard.set(pack.rawValue, forKey: "soundPack")
        audio.setPack(pack)
        audio.preview()
    }

    func setVolume(_ newValue: Double) {
        let value = max(0.0, min(1.0, newValue))
        volume = value
        UserDefaults.standard.set(value, forKey: "volume")
        audio.volume = value
    }

    func setMuted(_ newValue: Bool) {
        muted = newValue
        UserDefaults.standard.set(newValue, forKey: "muted")
        audio.muted = newValue
        if newValue {
            scheduler.stop()
        }
    }

    func setStartAtLogin(_ enabled: Bool) {
        do {
            try LoginItemManager.setEnabled(enabled)
        } catch {
            // The OS remains the source of truth.
        }
        startAtLogin = LoginItemManager.isEnabled
    }

    func previewSound() {
        audio.preview()
    }

    private func refreshAuthorizationState() {
        claudeFolderAuthorized = sandboxProvider?.isAuthorized(.claude) ?? true
        codexFolderAuthorized = sandboxProvider?.isAuthorized(.codex) ?? true
    }

    private func handle(_ message: CoreMessage) {
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

        activities[session] = ActivityState(
            agent: agent,
            phase: phase,
            intensity: intensity,
            toolClass: message.toolClass
        )

        switch agent {
        case "claude":
            claudeState = phase.capitalized
        case "codex":
            codexState = phase.capitalized
        default:
            break
        }

        updateGlobalAudio()
    }

    private func updateGlobalAudio() {
        guard !muted,
              let strongest = activities.values.max(by: { $0.intensity < $1.intensity })
        else {
            scheduler.stop()
            return
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
}
