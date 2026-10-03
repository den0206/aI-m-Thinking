import SwiftUI

@main
struct AImThinkingApp: App {
    @StateObject private var model = AppModel()

    init() {
        // A write to a core that just exited must fail with EPIPE, which
        // CoreBridge handles, instead of killing the app.
        signal(SIGPIPE, SIG_IGN)
    }

    private var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "aI'm Thinking"
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            KeycapLabel(animator: model.keyPress, model: model)
                .accessibilityLabel(displayName)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to \(displayName)", id: OnboardingView.windowID) {
            OnboardingView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(model.onboardingCompleted ? .suppressed : .presented)
    }
}

private struct KeycapLabel: View {
    @ObservedObject var animator: KeyPressAnimator
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: KeycapIcon.image(frame: animator.frame, state: model.menuBarState))
            .accessibilityValue(model.menuBarState?.rawValue.capitalized ?? "")
    }
}
