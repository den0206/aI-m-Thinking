import AVFoundation
import Foundation

enum AmbientAccentKind: String, CaseIterable, Sendable {
    case rain
    case thunder
    case pageTurn
    case writing

    var fileName: String {
        switch self {
        case .rain: "rain.mp3"
        case .thunder: "thunder.ogg"
        case .pageTurn: "page-turn.mp3"
        case .writing: "writing.mp3"
        }
    }

    var maximumDuration: TimeInterval {
        switch self {
        case .rain: 9.0
        case .thunder: 8.0
        case .pageTurn: 1.2
        case .writing: 3.5
        }
    }

    var fadeIn: TimeInterval {
        switch self {
        case .rain: 1.2
        case .thunder: 0.8
        case .pageTurn: 0.06
        case .writing: 0.25
        }
    }

    var fadeOut: TimeInterval {
        switch self {
        case .rain: 1.6
        case .thunder: 1.4
        case .pageTurn: 0.10
        case .writing: 0.45
        }
    }

    var relativeLevel: Float {
        switch self {
        case .rain: 0.82
        case .thunder: 0.72
        case .pageTurn: 0.90
        case .writing: 0.86
        }
    }
}

@MainActor
final class AmbientAudioEngine {
    static let defaultGain = 0.82
    static let defaultReverb: Float = 10

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let reverb = AVAudioUnitReverb()
    private let directory: URL?
    private var playbackTask: Task<Void, Never>?

    var volume: Double = 0.55 {
        didSet { updateOutputVolume() }
    }

    var gain: Double = defaultGain {
        didSet { updateOutputVolume() }
    }

    var reverbAmount: Float = defaultReverb {
        didSet { reverb.wetDryMix = min(35, max(0, reverbAmount)) }
    }

    var muted = false {
        didSet {
            if muted { stop() }
        }
    }

    init(directory: URL? = Bundle.main.resourceURL?.appending(path: "Ambient")) {
        self.directory = directory
        engine.attach(player)
        engine.attach(reverb)
        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = Self.defaultReverb
        engine.connect(player, to: reverb, format: nil)
        engine.connect(reverb, to: engine.mainMixerNode, format: nil)
        updateOutputVolume()
        engine.prepare()
    }

    func play(_ kind: AmbientAccentKind) {
        guard !muted,
              let url = directory?.appending(path: kind.fileName),
              let file = try? AVAudioFile(forReading: url),
              file.length > 0
        else {
            return
        }

        playbackTask?.cancel()
        player.stop()

        let sampleRate = file.processingFormat.sampleRate
        let wantedFrames = AVAudioFramePosition(kind.maximumDuration * sampleRate)
        let frameCount = AVAudioFrameCount(min(file.length, max(1, wantedFrames)))
        let maxStart = max(0, file.length - AVAudioFramePosition(frameCount))
        let startFrame: AVAudioFramePosition
        if kind == .rain, maxStart > 0 {
            startFrame = AVAudioFramePosition.random(in: 0...maxStart)
        } else {
            startFrame = 0
        }

        startIfNeeded()
        player.volume = 0
        player.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionHandler: nil
        )
        player.play()

        let duration = Double(frameCount) / sampleRate
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rampVolume(to: kind.relativeLevel, over: min(kind.fadeIn, duration * 0.35))
            guard !Task.isCancelled else { return }

            let hold = max(0, duration - kind.fadeIn - kind.fadeOut)
            if hold > 0 {
                try? await Task.sleep(for: .seconds(hold))
            }
            guard !Task.isCancelled else { return }

            await self.rampVolume(to: 0, over: min(kind.fadeOut, duration * 0.4))
            guard !Task.isCancelled else { return }
            self.player.stop()
            self.playbackTask = nil
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
    }

    func fadeOutAndStop() {
        guard player.isPlaying else {
            stop()
            return
        }
        playbackTask?.cancel()
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rampVolume(to: 0, over: 0.45)
            self.stop()
        }
    }

    private func rampVolume(to target: Float, over seconds: TimeInterval) async {
        let start = player.volume
        let steps = max(1, Int(seconds / 0.05))
        for step in 1...steps {
            guard !Task.isCancelled else { return }
            let progress = Float(step) / Float(steps)
            player.volume = start + (target - start) * progress
            try? await Task.sleep(for: .milliseconds(50))
        }
        player.volume = target
    }

    private func startIfNeeded() {
        guard !engine.isRunning else { return }
        try? engine.start()
    }

    private func updateOutputVolume() {
        engine.mainMixerNode.outputVolume = Float(
            min(1.0, max(0.0, volume) * min(1.25, max(0.0, gain)))
        )
    }
}
