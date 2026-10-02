import SwiftUI

@main
struct ImThinkingApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("I'm Thinking", systemImage: "brain") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
