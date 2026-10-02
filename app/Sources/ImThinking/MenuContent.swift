import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: coreIcon)
                Text(model.coreStatus.label)
                    .font(.headline)
            }

            Divider()

            agentRow(name: "Claude Code", state: model.claudeState)
            agentRow(name: "Codex", state: model.codexState)

            Divider()

            HStack {
                Button("Restart Monitor") {
                    model.restartCore()
                }

                Spacer()

                Button("Quit") {
                    model.stopCore()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var coreIcon: String {
        switch model.coreStatus {
        case .monitoring:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        case .unavailable:
            "questionmark.circle"
        default:
            "circle"
        }
    }

    private func agentRow(name: String, state: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(state)
                .foregroundStyle(.secondary)
        }
    }
}
