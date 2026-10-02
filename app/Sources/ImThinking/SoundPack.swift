import Foundation

enum SoundPackID: String, CaseIterable, Identifiable {
    case mechanicalClicky = "mechanical-clicky"
    case mechanicalThock = "mechanical-thock"
    case laptop
    case typewriter
    case soft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mechanicalClicky: "Mechanical Clicky"
        case .mechanicalThock: "Mechanical Thock"
        case .laptop: "Laptop"
        case .typewriter: "Typewriter"
        case .soft: "Soft"
        }
    }

    var profile: SoundProfile {
        switch self {
        case .mechanicalClicky:
            SoundProfile(frequency: 2_900, secondaryFrequency: 5_600, toneMix: 0.32, noiseMix: 0.68, decay: 0.014, duration: 0.055, gain: 0.56)
        case .mechanicalThock:
            SoundProfile(frequency: 620, secondaryFrequency: 1_350, toneMix: 0.72, noiseMix: 0.28, decay: 0.026, duration: 0.085, gain: 0.58)
        case .laptop:
            SoundProfile(frequency: 1_750, secondaryFrequency: 3_400, toneMix: 0.42, noiseMix: 0.58, decay: 0.012, duration: 0.045, gain: 0.42)
        case .typewriter:
            SoundProfile(frequency: 1_150, secondaryFrequency: 4_800, toneMix: 0.38, noiseMix: 0.62, decay: 0.022, duration: 0.075, gain: 0.66)
        case .soft:
            SoundProfile(frequency: 540, secondaryFrequency: 980, toneMix: 0.78, noiseMix: 0.22, decay: 0.018, duration: 0.060, gain: 0.34)
        }
    }
}

struct SoundProfile {
    let frequency: Double
    let secondaryFrequency: Double
    let toneMix: Double
    let noiseMix: Double
    let decay: Double
    let duration: Double
    let gain: Double
}

enum KeySoundKind {
    case key
    case space
    case enter
}
