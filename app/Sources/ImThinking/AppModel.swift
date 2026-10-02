import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var coreStatus: CoreStatus = .stopped
    @Published private(set) var claudeState = "Waiting"
    @Published private(set) var codexState = "Waiting"

    private let bridge = CoreBridge()

    init() {
        bridge.onStatus = { [weak self] status in
            self?.coreStatus = status
        }
        bridge.onMessage = { [weak self] message in
            self?.handle(message)
        }
        bridge.start()
    }

    func restartCore() {
        bridge.restart()
    }

    func stopCore() {
        bridge.stop()
    }

    private func handle(_ message: CoreMessage) {
        guard message.type == "activity",
              let agent = message.agent,
              let phase = message.phase
        else {
            return
        }

        switch agent {
        case "claude":
            claudeState = phase.capitalized
        case "codex":
            codexState = phase.capitalized
        default:
            break
        }
    }
}
