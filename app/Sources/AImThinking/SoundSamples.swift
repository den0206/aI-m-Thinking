import AVFoundation
import Foundation

struct SoundBank {
    let keys: [AVAudioPCMBuffer]
    let spaces: [AVAudioPCMBuffer]
    let enters: [AVAudioPCMBuffer]
}

/// Builds packs from bundled mono, 44.1 kHz WAVs in `Contents/Resources/Sounds`.
enum SoundSamples {
    static let sampleRate = 44_100.0

    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appending(path: "Sounds")
    }

    static func makeBank(for pack: SoundPackID, directory: URL? = bundledDirectory) -> SoundBank? {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory.appending(path: pack.sampleDirectory), includingPropertiesForKeys: nil
              )
        else {
            return nil
        }
        let wavs = urls
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let takes = wavs
            .filter { $0.lastPathComponent.hasPrefix("key") }
            .compactMap(load)
        guard !takes.isEmpty else { return nil }

        let profile = pack.profile
        func render(_ samples: [[Float]], _ rateScale: Double, _ gainScale: Double) -> [AVAudioPCMBuffer] {
            samples.enumerated().compactMap { index, samples in
                // Small level spread so repeated keys don't sound copy-pasted.
                let level = 0.8 + 0.2 * Double(index % 5) / 4.0
                return buffer(
                    from: samples,
                    rate: profile.rate * rateScale,
                    lowpass: profile.lowpass,
                    peak: profile.gain * gainScale * level
                )
            }
        }

        func special(_ prefix: String, _ fallbackRate: Double, _ gain: Double) -> [AVAudioPCMBuffer] {
            let samples = wavs.filter { $0.lastPathComponent.hasPrefix(prefix) }.compactMap(load)
            // Use dedicated keycap sounds when available; otherwise lower the normal keys.
            return render(samples.isEmpty ? takes : samples, samples.isEmpty ? fallbackRate : 1.0, gain)
        }
        return SoundBank(
            keys: render(takes, 1.0, 1.0),
            spaces: special("space", 0.82, 1.1),
            enters: special("enter", 0.88, 1.15)
        )
    }

    /// Reads a take and trims it to start right at the strike (~2 ms pre-roll)
    /// and end once it decays, so playback latency stays constant.
    private static func load(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0]
        else {
            return nil
        }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let peak = samples.map(abs).max() ?? 0
        guard peak > 0,
              let onset = samples.firstIndex(where: { abs($0) > peak * 0.1 }),
              let end = samples.lastIndex(where: { abs($0) > peak * 0.02 })
        else {
            return nil
        }
        let start = max(0, onset - Int(sampleRate * 0.002))
        let stop = min(samples.count, end + Int(sampleRate * 0.005))
        return Array(samples[start..<stop])
    }

    private static func buffer(from input: [Float], rate: Double, lowpass: Double?, peak: Double) -> AVAudioPCMBuffer? {
        // Resample by linear interpolation: rate < 1 plays slower and lower.
        let count = Int(Double(input.count - 1) / rate)
        guard count > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let out = buffer.floatChannelData?[0]
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(count)

        let a = lowpass.map { Float(1.0 - exp(-2.0 * .pi * $0 / sampleRate)) } ?? 1
        var y: Float = 0
        var maxValue: Float = 0
        for i in 0..<count {
            let position = Double(i) * rate
            let j = Int(position)
            let frac = Float(position - Double(j))
            let x = input[j] + (input[j + 1] - input[j]) * frac
            y += a * (x - y)
            out[i] = y
            maxValue = max(maxValue, abs(y))
        }
        guard maxValue > 0 else { return nil }

        let fade = min(count, Int(sampleRate * 0.005))
        let scale = Float(peak) / maxValue
        for i in 0..<count {
            out[i] *= scale * min(1, Float(count - i) / Float(fade))
        }
        return buffer
    }
}
