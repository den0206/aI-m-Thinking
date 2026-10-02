import Foundation

@MainActor
final class TypingScheduler {
    private let audio: KeyboardAudioEngine
    private var phase = "idle"
    private var intensity = 0.0
    private var toolClass: String?
    private var generation: UInt64 = 0
    private var scheduled = false

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

    static func keysPerSecond(
        intensity: Double,
        phase: String,
        toolClass: String?
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

        let base = 1.2 + 13.8 * pow(value, 1.8)
        return min(15.0, base * multiplier)
    }

    private func scheduleNext() {
        let speed = Self.keysPerSecond(
            intensity: intensity,
            phase: phase,
            toolClass: toolClass
        )
        guard speed > 0 else {
            scheduled = false
            return
        }

        let currentGeneration = generation
        let jitter = Double.random(in: 0.82...1.18)
        var delay = (1.0 / speed) * jitter

        if phase == "thinking", Int.random(in: 0..<6) == 0 {
            delay += Double.random(in: 0.08...0.22)
        }

        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.scheduled = false
            self.audio.play(self.nextKind())
            self.scheduleNext()
        }
    }

    private func nextKind() -> KeySoundKind {
        switch Int.random(in: 0..<100) {
        case 0..<4: .enter
        case 4..<16: .space
        default: .key
        }
    }
}
