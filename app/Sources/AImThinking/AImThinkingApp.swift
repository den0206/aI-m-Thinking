import SwiftUI

@main
struct AImThinkingApp: App {
    @StateObject private var model = AppModel()

    private var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "aI'm Thinking"
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            KeycapLabel(animator: model.keyPress)
                .accessibilityLabel(displayName)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct KeycapLabel: View {
    @ObservedObject var animator: KeyPressAnimator

    var body: some View {
        Image(nsImage: KeycapIcon.frames[animator.frame])
    }
}
