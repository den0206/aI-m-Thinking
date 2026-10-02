import AVFoundation
import Foundation

@MainActor
final class KeyboardAudioEngine {
    private let engine = AVAudioEngine()
    private let voices: [AVAudioPlayerNode]
    private var bank: SoundBank?
    private var voiceIndex = 0

    var volume: Double = 0.55 {
        didSet {
            engine.mainMixerNode.outputVolume = Float(max(0.0, min(1.0, volume)))
        }
    }

    var muted = false

    init(pack: SoundPackID) {
        voices = (0..<4).map { _ in AVAudioPlayerNode() }

        let format = AVAudioFormat(
            standardFormatWithSampleRate: SoundSynthesizer.sampleRate,
            channels: 1
        )

        for voice in voices {
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
        }

        engine.mainMixerNode.outputVolume = Float(volume)
        bank = SoundSynthesizer.makeBank(for: pack)
        engine.prepare()
    }

    func setPack(_ pack: SoundPackID) {
        for voice in voices {
            voice.stop()
        }
        bank = SoundSynthesizer.makeBank(for: pack)
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
        voice.scheduleBuffer(buffer)

        if !voice.isPlaying {
            voice.play()
        }
    }

    func preview() {
        play(.key)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard let self, !Task.isCancelled else { return }
            self.play(.key)

            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            self.play(.enter)
        }
    }

    func stop() {
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
