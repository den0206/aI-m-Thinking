import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            content
        }
        .padding(12)
        .frame(width: 320)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            agentsModule

            if model.requiresFolderAuthorization {
                folderAccessModule
            }

            HStack(spacing: 10) {
                muteTile
                soundPackTile
            }

            sliderModule(
                title: "Volume",
                systemImage: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                value: model.muted ? 0 : model.volume,
                in: 0...1,
                set: model.setVolume
            )

            sliderModule(
                title: "Typing Speed",
                systemImage: "gauge.with.dots.needle.33percent",
                value: model.typingSpeed,
                in: AppModel.typingSpeedRange,
                set: model.setTypingSpeed
            )

            footer
        }
    }

    // MARK: - Agents

    private var agentsModule: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Agents")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(coreStatusColor)
                    .frame(width: 6, height: 6)
                Text(model.coreStatus.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                agentTile(.claude, state: model.claudeState)
                agentTile(.codex, state: model.codexState)
            }
        }
        .module()
    }

    private var coreStatusColor: Color {
        switch model.coreStatus {
        case .monitoring: .green
        case .failed, .unavailable: .orange
        default: .secondary
        }
    }

    private func agentTile(_ service: AgentService, state: String) -> some View {
        let active = state != "Waiting" && state != "Idle"
        let unrecognized = !active && model.unrecognizedAgents.contains(service)
        return VStack(alignment: .leading, spacing: 2) {
            Text(service.displayName)
                .font(.callout.weight(.semibold))
            if unrecognized {
                Label("Unsupported format", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("This \(service.displayName) version writes transcripts this app cannot read yet. Update aI'm Thinking or share the diagnostic log.")
            } else {
                Text(active ? "\(state)…" : state)
                    .font(.caption)
                    .foregroundStyle(active ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            active ? AnyShapeStyle(service.tint) : AnyShapeStyle(.primary.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .animation(.easeOut(duration: 0.2), value: active)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Folder access

    private var folderAccessModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent Folder Access")
                .font(.headline)

            folderAccessRow(service: .claude, authorized: model.claudeFolderAuthorized)
            folderAccessRow(service: .codex, authorized: model.codexFolderAuthorized)
        }
        .module()
    }

    private func folderAccessRow(service: AgentService, authorized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(service.displayName)
                Spacer()

                if authorized {
                    Text("Allowed")
                        .foregroundStyle(.secondary)

                    Button("Revoke") {
                        model.revokeFolder(for: service)
                    }
                } else {
                    Button("Choose Folder…") {
                        model.authorizeFolder(for: service)
                    }
                }
            }

            if let error = model.folderErrors[service] {
                FolderErrorLabel(message: error)
            }
        }
    }

    // MARK: - Sound tiles

    private var muteTile: some View {
        Button {
            model.setMuted(!model.muted)
        } label: {
            tileLabel(
                systemImage: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                highlighted: !model.muted,
                title: "Sound",
                subtitle: model.muted ? "Muted" : "On"
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mute")
        .accessibilityValue(model.muted ? "On" : "Off")
    }

    private var soundPackTile: some View {
        Menu {
            Picker(
                "Sound Pack",
                selection: Binding(
                    get: { model.soundPack },
                    set: { model.selectSoundPack($0) }
                )
            ) {
                Text("Random").tag(SoundPackID?.none)
                Divider()
                ForEach(SoundPackID.allCases) { pack in
                    Text(pack.displayName).tag(Optional(pack))
                }
            }
            .pickerStyle(.inline)
        } label: {
            tileLabel(
                systemImage: model.soundPack == nil ? "shuffle" : "keyboard",
                highlighted: false,
                title: model.playingPack.displayName,
                subtitle: model.soundPack == nil ? "Random" : "Sound Pack"
            )
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    private func tileLabel(
        systemImage: String,
        highlighted: Bool,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(width: 30, height: 30)
                .background(
                    highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.1)),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
    }

    // MARK: - Sliders

    private func sliderModule(
        title: String,
        systemImage: String,
        value: Double,
        in range: ClosedRange<Double>,
        set: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ModuleSlider(
                title: title,
                systemImage: systemImage,
                value: value,
                range: range,
                set: set
            )
        }
        .module()
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Start at Login",
                isOn: Binding(
                    get: { model.startAtLogin },
                    set: { model.setStartAtLogin($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)

            Button("Restart Monitor") {
                model.restartCore()
            }
            .buttonStyle(.plain)

            Button("Copy Diagnostic Log") {
                model.copyDiagnosticLog()
            }
            .buttonStyle(.plain)

            Button("Quit aI'm Thinking") {
                model.quit()
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .module()
    }
}

/// Control Center style thick slider: an accent-color fill grows from the leading edge.
private struct ModuleSlider: View {
    let title: String
    let systemImage: String
    let value: Double
    let range: ClosedRange<Double>
    let set: (Double) -> Void

    private static let height: CGFloat = 28

    private var fraction: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.12))
                Capsule()
                    .fill(.tint.opacity(0.75))
                    .frame(width: fraction > 0 ? max(Self.height, geometry.size.width * fraction) : 0)
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(fraction > 0 ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: Self.height)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    // The fill never shrinks below the icon, so the icon's half is the bottom.
                    let f = drag.location.x < Self.height / 2
                        ? 0 : min(drag.location.x / geometry.size.width, 1)
                    set(range.lowerBound + f * (range.upperBound - range.lowerBound))
                }
            )
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 10
            switch direction {
            case .increment: set(min(value + step, range.upperBound))
            case .decrement: set(max(value - step, range.lowerBound))
            @unknown default: break
            }
        }
    }
}

private extension View {
    func module() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

extension AgentService {
    /// Brand tints from den0206/account-switcher (#d97757 / #10a37f),
    /// darkened so the white tile text keeps 4.5:1 contrast.
    var tint: Color {
        switch self {
        case .claude: Color(red: 0xB8 / 255, green: 0x5A / 255, blue: 0x3B / 255)
        case .codex: Color(red: 0x0B / 255, green: 0x7D / 255, blue: 0x61 / 255)
        }
    }
}
