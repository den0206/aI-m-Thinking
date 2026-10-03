import Foundation

@MainActor
final class AmbientAccentScheduler {
    static let defaultInterval: ClosedRange<TimeInterval> = 3 * 60...8 * 60

    private let audio: AmbientAudioEngine
    private let interval: ClosedRange<TimeInterval>
    private var task: Task<Void, Never>?
    private var phase: String?
    private var toolClass: String?
    private var audible = false
    private(set) var lastKind: AmbientAccentKind?
    /// Audible working time left before the next accent. It counts down only while
    /// an agent is audibly active and carries over gaps and turns, so short bursts add up.
    private var remaining: TimeInterval
    private var runningSince: SuspendingClock.Instant?

    var isEnabled = false {
        didSet {
            if !isEnabled { audio.fadeOutAndStop() }
            refresh()
        }
    }

    var volume: Double {
        get { audio.volume }
        set { audio.volume = newValue }
    }

    var muted: Bool {
        get { audio.muted }
        set {
            audio.muted = newValue
            refresh()
        }
    }

    init(audio: AmbientAudioEngine, interval: ClosedRange<TimeInterval> = defaultInterval) {
        self.audio = audio
        self.interval = interval
        remaining = .random(in: interval)
    }

    /// `phase` is nil once no turn is open; `audible` is whether any agent is
    /// active enough to be heard right now.
    func update(phase: String?, toolClass: String?, audible: Bool) {
        let active = phase.map { $0 != "idle" && $0 != "paused" } ?? false
        // Idle updates repeat; fade only once, on the way out of a turn.
        if !active, self.phase != nil { audio.fadeOutAndStop() }
        self.phase = active ? phase : nil
        self.toolClass = active ? toolClass : nil
        self.audible = active && audible
        refresh()
    }

    func stop() {
        pause()
        phase = nil
        toolClass = nil
        audible = false
        audio.stop()
    }

    #if DEBUG
    func setDebugGain(_ value: Double) {
        audio.gain = value
    }

    func preview(_ kind: AmbientAccentKind) {
        audio.play(kind)
    }
    #endif

    private func refresh() {
        if isEnabled, !muted, phase != nil, audible {
            resume()
        } else {
            pause()
        }
    }

    private func resume() {
        guard task == nil else { return }
        runningSince = .now
        let delay = remaining
        // The suspending clock stops during system sleep, so waking never fires a backlog.
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay), clock: .suspending)
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.runningSince = nil
            self.remaining = .random(in: self.interval)
            if let phase = self.phase {
                let kind = Self.chooseKind(phase: phase, toolClass: self.toolClass, excluding: self.lastKind)
                self.lastKind = kind
                self.audio.play(kind)
            }
            self.refresh()
        }
    }

    private func pause() {
        task?.cancel()
        task = nil
        guard let runningSince else { return }
        let elapsed = runningSince.duration(to: .now).components
        remaining = max(0, remaining - (Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18))
        self.runningSince = nil
    }

    nonisolated static func chooseKind(
        phase: String,
        toolClass: String?,
        excluding previous: AmbientAccentKind? = nil,
        roll: Double = .random(in: 0..<1)
    ) -> AmbientAccentKind {
        var weights: [(AmbientAccentKind, Double)]

        if phase == "thinking" {
            weights = [(.pageTurn, 0.50), (.rain, 0.37), (.thunder, 0.13)]
        } else if phase == "writing" {
            weights = [(.rain, 0.56), (.thunder, 0.22), (.pageTurn, 0.22)]
        } else if phase == "tool", ["read", "search", "subagent"].contains(toolClass ?? "") {
            weights = [(.pageTurn, 0.69), (.rain, 0.25), (.thunder, 0.06)]
        } else {
            weights = [(.rain, 0.60), (.thunder, 0.27), (.pageTurn, 0.13)]
        }
        // Never the same sound twice in a row; the rest keep their proportions.
        weights.removeAll { $0.0 == previous }

        var cursor = max(0, min(0.999_999, roll)) * weights.reduce(0) { $0 + $1.1 }
        for (kind, weight) in weights {
            if cursor < weight { return kind }
            cursor -= weight
        }
        return weights.last?.0 ?? .rain
    }
}
