import AVFoundation
import Foundation

struct SoundBank {
    let keys: [AVAudioPCMBuffer]
    let spaces: [AVAudioPCMBuffer]
    let enters: [AVAudioPCMBuffer]
}

enum SoundSynthesizer {
    static let sampleRate = 44_100.0

    static func makeBank(for pack: SoundPackID) -> SoundBank? {
        let keys = (0..<6).compactMap { makeBuffer(profile: pack.profile, kind: .key, variant: $0) }
        let spaces = (0..<2).compactMap { makeBuffer(profile: pack.profile, kind: .space, variant: $0 + 11) }
        let enters = (0..<2).compactMap { makeBuffer(profile: pack.profile, kind: .enter, variant: $0 + 21) }

        guard keys.count == 6, spaces.count == 2, enters.count == 2 else {
            return nil
        }

        return SoundBank(keys: keys, spaces: spaces, enters: enters)
    }

    private static func makeBuffer(
        profile: SoundProfile,
        kind: KeySoundKind,
        variant: Int
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            return nil
        }

        let kindScale: Double
        let durationScale: Double
        let gainScale: Double
        switch kind {
        case .key:
            kindScale = 1.0
            durationScale = 1.0
            gainScale = 1.0
        case .space:
            kindScale = 0.72
            durationScale = 1.18
            gainScale = 0.90
        case .enter:
            kindScale = 0.88
            durationScale = 1.30
            gainScale = 1.10
        }

        let duration = profile.duration * durationScale
        let frameCount = AVAudioFrameCount(max(1, Int(sampleRate * duration)))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let samples = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = frameCount

        var random = UInt64(variant + 1) &* 0x9E37_79B9_7F4A_7C15
        let pitchVariation = 0.96 + Double(variant % 6) * 0.016
        let primary = profile.frequency * kindScale * pitchVariation
        let secondary = profile.secondaryFrequency * kindScale * pitchVariation

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let envelope = exp(-time / profile.decay)
            let attack = min(1.0, time / 0.0008)

            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noiseUnit = Double((random >> 40) & 0xFF_FFFF) / Double(0xFF_FFFF)
            let noise = noiseUnit * 2.0 - 1.0

            let primaryTone = sin(2.0 * .pi * primary * time)
            let secondaryTone = sin(2.0 * .pi * secondary * time) * 0.45
            let transient = time < 0.003 ? (1.0 - time / 0.003) * noise * 0.9 : 0.0

            let value = (
                (primaryTone + secondaryTone) * profile.toneMix
                + noise * profile.noiseMix
                + transient
            ) * envelope * attack * profile.gain * gainScale

            samples[frame] = Float(max(-1.0, min(1.0, value)))
        }

        return buffer
    }
}
