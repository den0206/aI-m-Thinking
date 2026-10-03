import Foundation

@MainActor
final class TypingScheduler {
    private let audio: KeyboardAudioEngine
    private var phase = "idle"
    private var intensity = 0.0
    /// User speed setting; multiplies the intensity-derived rate.
    var speedScale = 1.0
    private var toolClass: String?
    private var generation: UInt64 = 0
    private var scheduled = false
    /// Keys left in the current "word" before a space.
    private var wordRemaining = 0

    init(audio: KeyboardAudioEngine) {
        self.audio = audio
    }

    func update(phase: String, intensity: Double, toolClass: String?) {
        self.phase = phase
        self.intensity = max(0.0, min(1.0, intensity))
        self.toolClass = toolClass

        if Self.keysPerSecond(
            intensity: self.intensity,
            phase: phase,
            toolClass: toolClass
        ) == 0 {
            generation &+= 1
            scheduled = false
            return
        }

        if !scheduled {
            scheduleNext()
        }
    }

    func stop() {
        generation &+= 1
        scheduled = false
    }

    nonisolated static func keysPerSecond(
        intensity: Double,
        phase: String,
        toolClass: String?,
        speedScale: Double = 1.0
    ) -> Double {
        let value = max(0.0, min(1.0, intensity))
        guard value >= 0.06 else { return 0 }

        let multiplier: Double
        switch phase {
        case "thinking":
            multiplier = 0.78
        case "writing":
            multiplier = 1.0
        case "tool" where toolClass == "mutation":
            multiplier = 0.90
        default:
            return 0
        }

        // Even light activity types at a real typist's pace (~6 keys/s);
        // intensity pushes it toward a fast burst.
        let base = 6.0 + 9.0 * pow(value, 1.2)
        return min(15.0, base * multiplier * max(0, speedScale))
    }

    private func scheduleNext() {
        let speed = Self.keysPerSecond(
            intensity: intensity,
            phase: phase,
            toolClass: toolClass,
            speedScale: speedScale
        )
        guard speed > 0 else {
            scheduled = false
            return
        }

        let currentGeneration = generation
        // Keys within a word roll quickly; the beat after a space is longer.
        let kind = nextKind()
        let jitter = Double.random(in: 0.6...1.25)
        var delay = (1.0 / speed) * jitter
        delay = max(1.0 / 15.0, delay)
        if kind != .key {
            delay += Double.random(in: 0.04...0.14)
        }

        if phase == "thinking", Int.random(in: 0..<6) == 0 {
            delay += Double.random(in: 0.08...0.22)
        }

        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.scheduled = false
            self.audio.play(kind)
            self.scheduleNext()
        }
    }

    private func nextKind() -> KeySoundKind {
        if wordRemaining > 0 {
            wordRemaining -= 1
            return .key
        }
        wordRemaining = Int.random(in: 2...8)
        return Int.random(in: 0..<12) == 0 ? .enter : .space
    }
}
