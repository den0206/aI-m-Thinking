import Foundation

@MainActor
final class AmbientAccentScheduler {
    static let minimumInterval: TimeInterval = 5 * 60
    static let maximumInterval: TimeInterval = 15 * 60

    private let audio: AmbientAudioEngine
    private var task: Task<Void, Never>?
    private var phase: String?
    private var toolClass: String?

    var isEnabled = false {
        didSet {
            if !isEnabled {
                task?.cancel()
                task = nil
                audio.fadeOutAndStop()
            } else if phase != nil {
                scheduleIfNeeded()
            }
        }
    }

    var volume: Double {
        get { audio.volume }
        set { audio.volume = newValue }
    }

    var muted: Bool {
        get { audio.muted }
        set { audio.muted = newValue }
    }

    #if DEBUG
    var intervalScale: Double = 1
    #endif

    init(audio: AmbientAudioEngine) {
        self.audio = audio
    }

    func update(phase: String?, toolClass: String?) {
        guard let phase, phase != "idle", phase != "paused" else {
            self.phase = nil
            self.toolClass = nil
            task?.cancel()
            task = nil
            audio.fadeOutAndStop()
            return
        }

        self.phase = phase
        self.toolClass = toolClass
        guard isEnabled, !muted else { return }
        scheduleIfNeeded()
    }

    func stop() {
        task?.cancel()
        task = nil
        phase = nil
        toolClass = nil
        audio.stop()
    }

    #if DEBUG
    func setDebugGain(_ value: Double) {
        audio.gain = value
    }

    func setDebugReverb(_ value: Double) {
        audio.reverbAmount = Float(value)
    }

    func preview(_ kind: AmbientAccentKind) {
        audio.play(kind)
    }
    #endif

    private func scheduleIfNeeded() {
        guard task == nil else { return }

        var delay = Double.random(in: Self.minimumInterval...Self.maximumInterval)
        #if DEBUG
        delay *= max(0.01, intervalScale)
        #endif

        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            guard self.isEnabled, !self.muted, let phase = self.phase else { return }

            self.audio.play(Self.chooseKind(phase: phase, toolClass: self.toolClass))
            self.scheduleIfNeeded()
        }
    }

    nonisolated static func chooseKind(
        phase: String,
        toolClass: String?,
        roll: Double = .random(in: 0..<1)
    ) -> AmbientAccentKind {
        let weights: [(AmbientAccentKind, Double)]

        if phase == "thinking" {
            weights = [(.writing, 0.40), (.pageTurn, 0.30), (.rain, 0.22), (.thunder, 0.08)]
        } else if phase == "writing" {
            weights = [(.rain, 0.50), (.thunder, 0.20), (.pageTurn, 0.20), (.writing, 0.10)]
        } else if phase == "tool", ["read", "search", "subagent"].contains(toolClass ?? "") {
            weights = [(.pageTurn, 0.55), (.writing, 0.20), (.rain, 0.20), (.thunder, 0.05)]
        } else {
            weights = [(.rain, 0.55), (.thunder, 0.25), (.pageTurn, 0.12), (.writing, 0.08)]
        }

        var cursor = max(0, min(0.999_999, roll))
        for (kind, weight) in weights {
            if cursor < weight { return kind }
            cursor -= weight
        }
        return weights.last?.0 ?? .rain
    }
}
