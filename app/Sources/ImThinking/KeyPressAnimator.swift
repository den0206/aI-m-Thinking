import Foundation

/// Drives the menu bar keycap like RunCat: it keeps striking while any agent
/// is active, faster as activity intensity rises.
@MainActor
final class KeyPressAnimator: ObservableObject {
    /// Index into `KeycapIcon.frames`; 0 is released.
    @Published private(set) var frame = 0

    private var intensity = 0.0
    /// User speed setting, shared with the typing sound.
    var speedScale = 1.0
    private var loop: Task<Void, Never>?

    var isAnimating: Bool { loop != nil }

    func update(active: Bool, intensity: Double) {
        self.intensity = max(0.0, min(1.0, intensity))
        if !active {
            loop?.cancel()
            loop = nil
            frame = 0
        } else if loop == nil {
            loop = Task { [weak self] in await self?.run() }
        }
    }

    /// 2 strikes/s for an idle-looking tool run up to 12/s at full intensity.
    nonisolated static func strikesPerSecond(intensity: Double) -> Double {
        2.0 + 10.0 * max(0.0, min(1.0, intensity))
    }

    private func run() async {
        let bottom = KeycapIcon.frames.count - 1
        while !Task.isCancelled {
            let period = 1.0 / (Self.strikesPerSecond(intensity: intensity) * speedScale)
            // Most strikes bottom out; some are lighter, like real typing.
            let depth = Int.random(in: 0..<10) < 7 ? bottom : bottom - 1

            // A key snaps down and springs back more slowly. Step times shrink
            // with the period so fast typing still completes every stroke.
            let down = min(0.012, period * 0.08)
            let hold = min(0.035, period * 0.2)
            let up = min(0.022, period * 0.4 / Double(depth))

            var spent = 0.0
            func show(_ value: Int, for seconds: Double) async -> Bool {
                frame = value
                spent += seconds
                try? await Task.sleep(for: .seconds(seconds))
                return !Task.isCancelled
            }

            guard await show(depth / 2, for: down),
                  await show(depth, for: hold) else { break }
            for value in stride(from: depth - 1, through: 1, by: -1) {
                guard await show(value, for: up) else { return }
            }
            guard await show(0, for: max(0, period - spent)) else { break }
        }
    }
}
