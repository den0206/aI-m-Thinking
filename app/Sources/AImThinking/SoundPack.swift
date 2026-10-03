import Foundation

enum SoundPackID: String, CaseIterable, Identifiable {
    case mechanicalClicky = "mechanical-clicky"
    case mechanicalThock = "mechanical-thock"
    case laptop
    case typewriter
    case soft
    case hermes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mechanicalClicky: "Mechanical Clicky"
        case .mechanicalThock: "Mechanical Thock"
        case .laptop: "Laptop"
        case .typewriter: "Typewriter"
        case .soft: "Soft"
        case .hermes: "Hermes Precisa 305"
        }
    }

    var sampleDirectory: String {
        switch self {
        case .hermes: rawValue
        default: "kc1000"
        }
    }

    // The original five packs share KC 1000 takes; Laptop keeps their original tone.
    var profile: SoundProfile {
        switch self {
        case .mechanicalClicky: SoundProfile(rate: 1.15, lowpass: nil, gain: 0.60)
        case .mechanicalThock: SoundProfile(rate: 0.78, lowpass: 2_800, gain: 0.70)
        case .laptop: SoundProfile(rate: 1.0, lowpass: nil, gain: 0.55)
        case .typewriter: SoundProfile(rate: 0.90, lowpass: nil, gain: 0.72)
        case .soft: SoundProfile(rate: 0.92, lowpass: 1_600, gain: 0.45)
        case .hermes: SoundProfile(rate: 1.0, lowpass: nil, gain: 0.60)
        }
    }
}

struct SoundProfile {
    /// Playback rate; below 1 is lower and longer.
    let rate: Double
    /// One-pole lowpass cutoff in Hz, nil to keep the recording's full brightness.
    let lowpass: Double?
    let gain: Double
}

enum KeySoundKind {
    case key
    case space
    case enter
}
