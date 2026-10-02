import SwiftUI

@main
struct ImThinkingApp: App {
    @StateObject private var model = AppModel()

    private var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "I'm Thinking"
    }

    var body: some Scene {
        MenuBarExtra(displayName, systemImage: "brain") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
