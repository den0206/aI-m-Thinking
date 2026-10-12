import Foundation

enum StereoProfile {
    static func pan(kind: KeySoundKind, sampleIndex: Int, sampleCount: Int,
                    width: Double, variation: Double) -> Float {
        let width = width.isFinite ? max(0, min(1, width)) : 0.25
        let position: Double
        switch kind {
        case .key:
            // Sample order gives each sound a stable position, independent of player voice.
            position = sampleCount > 1
                ? 2 * Double(sampleIndex) / Double(sampleCount - 1) - 1 : 0
        case .space: position = -0.05
        case .enter: position = 0.65
        }
        let variance = variation.isFinite ? max(-0.06, min(0.06, variation)) : 0
        // The former 100% spread is now 50%; wider settings can reach full left/right.
        let limit = min(1, 1.3 * width)
        return Float(max(-limit, min(limit, (position + variance) * 1.3 * width)))
    }
}
