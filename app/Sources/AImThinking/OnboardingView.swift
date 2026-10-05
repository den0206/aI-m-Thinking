import AppKit
import SwiftUI

/// Shown on first launch and from the menu: the app has no Dock icon or window, so this
/// points at the menu bar and, in the App Store build, collects folder access.
struct OnboardingView: View {
    static let windowID = "onboarding"

    @ObservedObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            menuBarHint

            VStack(alignment: .leading, spacing: 8) {
                Text("aI'm Thinking is in your menu bar")
                    .font(.title2.bold())
                Text(
                    model.requiresFolderAuthorization
                        ? "It plays keyboard sounds while Claude Code or Codex is working. Allow access to their session folders so it can tell when they are busy."
                        : "It plays keyboard sounds while Claude Code or Codex is working. There is nothing to set up — just start an agent as usual."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if model.requiresFolderAuthorization {
                folderAccess
            }

            loginRow
            if let message = model.loginItemMessage {
                LoginItemNotice(message: message)
            }
            footer
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .frame(width: 480)
        // The App Store build stays here until a folder is allowed (or Quit).
        .windowDismissBehavior(model.canFinishOnboarding ? .enabled : .disabled)
        .onAppear {
            model.refreshLoginStatus()
            // A menu bar app is never active on launch; bring the window forward.
            NSApp.activate()
        }
        .onDisappear {
            model.completeOnboarding()
        }
    }

    // MARK: - Menu bar hint

    private var menuBarHint: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(nsImage: KeycapIcon.frames[0])
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
                .overlay(alignment: .top) {
                    callout
                        .fixedSize()
                        .offset(y: 26)
                }
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(Date.now, format: .dateTime.weekday().hour().minute())
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.white.opacity(0.85))
        .frame(height: 132, alignment: .top)
        .background(Color(red: 0xDC / 255, green: 0xE3 / 255, blue: 0xEC / 255))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The key icon in the menu bar opens sound, volume and typing speed settings.")
    }

    private var callout: some View {
        VStack(spacing: 0) {
            CalloutArrow()
                .fill(Color(white: 0.11))
                .frame(width: 14, height: 8)
            Text("Click the key for sound, volume and typing speed")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(width: 224)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Folder access

    private var folderAccess: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Session folder access")
                    .font(.system(size: 14, weight: .semibold))
                Text("Read-only. Only lines written after launch are read, and nothing is saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ForEach(AgentService.allCases, id: \.self) { service in
                Divider()
                folderRow(service)
            }
        }
        .padding(.bottom, 4)
        .card()
    }

    private func folderRow(_ service: AgentService) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(service.tint)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(service.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text(service.suggestedDisplayPath)
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(.secondary)
                if let error = model.folderErrors[service] {
                    FolderErrorLabel(message: error)
                        .padding(.top, 3)
                }
            }

            Spacer()

            if model.isFolderAuthorized(service) {
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.allowedText)
            } else {
                Button("Choose Folder…") {
                    model.authorizeFolder(for: service)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Login and footer

    private var loginRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start at Login")
                    .font(.system(size: 14, weight: .semibold))
                Text("Sounds are ready whenever you open a terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Start at Login",
                isOn: Binding(
                    get: { model.startAtLogin },
                    set: { model.setStartAtLogin($0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .card()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.requiresFolderAuthorization {
                Button("Quit aI'm Thinking") {
                    model.quit()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.canFinishOnboarding {
                Text("Choose a folder to continue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Done") {
                dismissWindow(id: Self.windowID)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canFinishOnboarding)
        }
    }
}

/// Red error line under a folder row, shared with the menu.
struct FolderErrorLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.caption)
            .foregroundStyle(Color.errorText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct LoginItemNotice: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Login Items Settings…") { LoginItemManager.openSettings() }
                .font(.caption)
        }
    }
}

private struct CalloutArrow: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private extension View {
    func card() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

private extension Color {
    /// System red/green are too light for 12pt text on white; darken them in light mode.
    static let errorText = adaptive(light: NSColor(srgbRed: 0xC4 / 255, green: 0x28 / 255, blue: 0x1C / 255, alpha: 1), dark: .systemRed)
    static let allowedText = adaptive(light: NSColor(srgbRed: 0x1B / 255, green: 0x7A / 255, blue: 0x3A / 255, alpha: 1), dark: .systemGreen)

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}
