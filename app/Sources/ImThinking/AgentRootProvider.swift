import Foundation

struct AgentRootConfiguration: Sendable, Equatable {
    let claude: [URL]
    let codex: [URL]
}

protocol AgentRootProviding: Sendable {
    func roots() -> AgentRootConfiguration
}

struct DirectAgentRootProvider: AgentRootProviding {
    func roots() -> AgentRootConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AgentRootConfiguration(
            claude: [home.appending(path: ".claude/projects", directoryHint: .isDirectory)],
            codex: [home.appending(path: ".codex/sessions", directoryHint: .isDirectory)]
        )
    }
}
