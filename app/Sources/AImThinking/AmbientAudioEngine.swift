import AVFoundation
import Foundation

enum AmbientAccentKind: String, CaseIterable, Sendable {
    case rain
    case thunder
    case pageTurn

    var fileName: String {
        switch self {
        case .rain: "rain.m4a"
        case .thunder: "thunder.m4a"
        case .pageTurn: "page-turn.m4a"
        }
    }

    /// Longest slice of the recording played per accent.
    var maximumDuration: TimeInterval {
        switch self {
        case .rain: 5.0
        case .thunder: 8.5
        case .pageTurn: 2.5
        }
    }

    /// Continuous recordings start at a random point; one-shots play from the top.
    var startsAtRandomPoint: Bool {
        self == .rain
    }

    var fadeIn: TimeInterval {
        switch self {
        case .rain: 0.8
        case .thunder: 0.3
        case .pageTurn: 0.03
        }
    }

    var fadeOut: TimeInterval {
        switch self {
        case .rain: 1.2
        case .thunder: 1.2
        case .pageTurn: 0.08
        }
    }

    var relativeLevel: Float {
        switch self {
        case .rain: 0.82
        case .thunder: 0.72
        case .pageTurn: 0.90
        }
    }
}

@MainActor
final class AmbientAudioEngine {
    static let defaultGain = 0.54

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let directory: URL?
    private var playbackTask: Task<Void, Never>?

    var volume: Double = 0.55 {
        didSet { updateOutputVolume() }
    }

    var gain: Double = defaultGain {
        didSet { updateOutputVolume() }
    }

    var muted = false {
        didSet {
            if muted { stop() }
        }
    }

    init(directory: URL? = Bundle.main.resourceURL?.appending(path: "Ambient")) {
        self.directory = directory
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
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
        if kind.startsAtRandomPoint, maxStart > 0 {
            startFrame = AVAudioFramePosition.random(in: 0...maxStart)
        } else {
            startFrame = 0
        }

        startIfNeeded()
        // play() on a stopped engine raises an Objective-C exception.
        guard engine.isRunning else { return }
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
        let fadeIn = min(kind.fadeIn, duration * 0.35)
        let fadeOut = min(kind.fadeOut, duration * 0.4)
        playbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Engine start-up delays the first sample, so time the envelope from the
            // player's own timeline rather than from this call.
            await self.waitForPlaybackStart()
            guard !Task.isCancelled else { return }
            await self.rampVolume(to: kind.relativeLevel, over: fadeIn)
            guard !Task.isCancelled else { return }

            let hold = max(0, duration - fadeIn - fadeOut)
            if hold > 0 {
                try? await Task.sleep(for: .seconds(hold))
            }
            guard !Task.isCancelled else { return }

            await self.rampVolume(to: 0, over: fadeOut)
            // Rendered audio is still in flight (Bluetooth adds ~0.2 s); stopping now
            // would clip the tail.
            try? await Task.sleep(for: .seconds(self.engine.outputNode.presentationLatency + 0.1))
            guard !Task.isCancelled else { return }
            // Stop the engine too; an idle AVAudioEngine still holds the output device.
            self.stop()
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
            // A newer play() cancelled this fade; leave its playback alone.
            guard !Task.isCancelled else { return }
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

    private func waitForPlaybackStart() async {
        // ponytail: 10 ms polling, capped at 2 s for slow output devices.
        for _ in 0..<200 {
            if let nodeTime = player.lastRenderTime,
               let playerTime = player.playerTime(forNodeTime: nodeTime),
               playerTime.sampleTime > 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }
        }
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
