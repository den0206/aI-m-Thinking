import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var coreStatus: CoreStatus = .stopped
    @Published private(set) var claudeState = "Waiting"
    @Published private(set) var codexState = "Waiting"
    @Published private(set) var soundPack: SoundPackID
    @Published private(set) var volume: Double
    @Published private(set) var muted: Bool

    private let bridge = CoreBridge()
    private let audio: KeyboardAudioEngine
    private let scheduler: TypingScheduler
    private var activities: [UInt32: ActivityState] = [:]

    init() {
        let defaults = UserDefaults.standard
        let storedPack = defaults.string(forKey: "soundPack").flatMap(SoundPackID.init(rawValue:))
        let initialPack = storedPack ?? .laptop
        let storedVolume = defaults.object(forKey: "volume") as? Double
        let initialVolume = max(0.0, min(1.0, storedVolume ?? 0.55))
        let initialMuted = defaults.bool(forKey: "muted")

        soundPack = initialPack
        volume = initialVolume
        muted = initialMuted

        let audio = KeyboardAudioEngine(pack: initialPack)
        audio.volume = initialVolume
        audio.muted = initialMuted
        self.audio = audio
        scheduler = TypingScheduler(audio: audio)

        bridge.onStatus = { [weak self] status in
            self?.coreStatus = status
        }
        bridge.onMessage = { [weak self] message in
            self?.handle(message)
        }
        bridge.start()
    }

    func restartCore() {
        activities.removeAll(keepingCapacity: false)
        scheduler.stop()
        bridge.restart()
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

    func previewSound() {
        audio.preview()
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
