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

            Picker(
                "Sound",
                selection: Binding(
                    get: { model.soundPack },
                    set: { model.selectSoundPack($0) }
                )
            ) {
                ForEach(SoundPackID.allCases) { pack in
                    Text(pack.displayName).tag(pack)
                }
            }

            HStack {
                Text("Volume")
                Slider(
                    value: Binding(
                        get: { model.volume },
                        set: { model.setVolume($0) }
                    ),
                    in: 0...1
                )
            }

            Toggle(
                "Mute",
                isOn: Binding(
                    get: { model.muted },
                    set: { model.setMuted($0) }
                )
            )

            Toggle(
                "Start at Login",
                isOn: Binding(
                    get: { model.startAtLogin },
                    set: { model.setStartAtLogin($0) }
                )
            )

            Button("Preview Sound") {
                model.previewSound()
            }
            .disabled(model.muted)

            Divider()

            HStack {
                Button("Rescan Agents") {
                    model.rescanAgents()
                }

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
        .frame(width: 320)
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
