import AVFoundation
import Foundation

@MainActor
final class KeyboardAudioEngine {
    private let engine = AVAudioEngine()
    private let voices: [AVAudioPlayerNode]
    private var bank: SoundBank?
    private(set) var pack: SoundPackID
    /// The pack used just before, kept so two sessions alternating as the
    /// loudest one do not rebuild a bank (~0.2 s on the main thread) per swap.
    private var previous: (pack: SoundPackID, bank: SoundBank?)?
    private var voiceIndex = 0
    private var previewTask: Task<Void, Never>?
    private let soundsDirectory: URL?
    var isRunning: Bool { engine.isRunning }

    var volume: Double = 0.55 {
        didSet {
            engine.mainMixerNode.outputVolume = Float(max(0.0, min(1.0, volume)))
        }
    }

    var muted = false

    init(pack: SoundPackID, soundsDirectory: URL? = SoundSamples.bundledDirectory) {
        self.pack = pack
        self.soundsDirectory = soundsDirectory
        voices = (0..<4).map { _ in AVAudioPlayerNode() }

        let format = AVAudioFormat(
            standardFormatWithSampleRate: SoundSamples.sampleRate,
            channels: 1
        )

        for voice in voices {
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
        }

        engine.mainMixerNode.outputVolume = Float(volume)
        bank = SoundSamples.makeBank(for: pack, directory: soundsDirectory)
        engine.prepare()
    }

    func setPack(_ pack: SoundPackID) {
        guard pack != self.pack else { return }
        previewTask?.cancel()
        previewTask = nil
        let outgoing = (pack: self.pack, bank: bank)
        self.pack = pack
        for voice in voices {
            voice.stop()
        }
        bank = previous?.pack == pack ? previous?.bank : SoundSamples.makeBank(for: pack, directory: soundsDirectory)
        previous = outgoing
    }

    func play(_ kind: KeySoundKind) {
        guard !muted, let bank else { return }
        startIfNeeded()

        let buffers: [AVAudioPCMBuffer]
        switch kind {
        case .key: buffers = bank.keys
        case .space: buffers = bank.spaces
        case .enter: buffers = bank.enters
        }

        guard let buffer = buffers.randomElement(), !voices.isEmpty else { return }

        let voice = voices[voiceIndex % voices.count]
        voiceIndex = (voiceIndex + 1) % voices.count
        // Drop the previous sound on this voice instead of queueing buffers
        // faster than a long recording can finish. At most four are retained.
        voice.stop()
        // Different keys sit at different spots and get hit with different force.
        voice.pan = Float.random(in: -0.35...0.35)
        voice.volume = Float.random(in: 0.7...1.0)
        voice.scheduleBuffer(buffer)

        if !voice.isPlaying {
            voice.play()
        }
    }

    func preview(isActivityPlaying: @escaping @MainActor () -> Bool = { false }) {
        previewTask?.cancel()
        play(.key)

        previewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self, !Task.isCancelled else { return }
            self.play(.key)

            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            self.play(.enter)
            let buffers = (self.bank?.keys ?? []) + (self.bank?.enters ?? [])
            let tail = buffers.map {
                Double($0.frameLength) / $0.format.sampleRate
            }.max() ?? 0
            try? await Task.sleep(for: .seconds(tail + 0.05))
            guard !Task.isCancelled else { return }
            self.previewTask = nil
            if !isActivityPlaying() { self.stop() }
        }
    }

    func stop() {
        previewTask?.cancel()
        previewTask = nil
        for voice in voices {
            voice.stop()
        }
        engine.stop()
    }

    private func startIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            return
        }
    }
}
