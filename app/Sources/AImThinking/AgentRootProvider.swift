import AppKit
import Foundation

enum AgentService: String, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var suggestedDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            return home.appending(path: ".claude/projects", directoryHint: .isDirectory)
        case .codex:
            return home.appending(path: ".codex/sessions", directoryHint: .isDirectory)
        }
    }

    var suggestedDisplayPath: String {
        switch self {
        case .claude: "~/.claude/projects"
        case .codex: "~/.codex/sessions"
        }
    }

    /// Why `url` is not this agent's session folder, or nil when it looks right.
    /// Exact paths are not required (CLAUDE_CONFIG_DIR / CODEX_HOME move them),
    /// and empty folders pass: a fresh install has no sessions yet.
    func folderProblem(at url: URL) -> String? {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let components = url.pathComponents
        switch self {
        case .claude:
            // Codex nests sessions as YYYY/MM/DD.
            if components.contains(".codex")
                || children.contains(where: { $0.count == 4 && $0.allSatisfy(\.isNumber) }) {
                return "This looks like the Codex folder. Choose ~/.claude/projects."
            }
            // Core also watches the sibling `sessions` only for a root named `projects`.
            if url.lastPathComponent != "projects" {
                return "Choose the projects folder inside ~/.claude."
            }
        case .codex:
            // Claude names each project folder after its path: "-Users-…".
            if components.contains(".claude") || children.contains(where: { $0.hasPrefix("-") }) {
                return "This looks like a Claude Code folder. Choose ~/.codex/sessions."
            }
            if url.lastPathComponent != "sessions" {
                return "Choose the sessions folder inside ~/.codex."
            }
        }
        return nil
    }
}

enum FolderChoice: Equatable {
    case granted
    case cancelled
    case rejected(String)
}

struct AgentRootGrant: Sendable, Equatable {
    let path: String?
    let bookmark: String?

    static func direct(_ url: URL) -> Self {
        Self(path: url.path, bookmark: nil)
    }

    static func bookmark(_ data: Data) -> Self {
        Self(path: nil, bookmark: data.base64EncodedString())
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        if let path {
            object["path"] = path
        }
        if let bookmark {
            object["bookmark"] = bookmark
        }
        return object
    }
}

struct AgentRootConfiguration: Sendable, Equatable {
    let claude: [AgentRootGrant]
    let codex: [AgentRootGrant]
}

@MainActor
protocol AgentRootProviding: AnyObject {
    func roots() -> AgentRootConfiguration
}

@MainActor
final class DirectAgentRootProvider: AgentRootProviding {
    func roots() -> AgentRootConfiguration {
        AgentRootConfiguration(
            claude: [.direct(AgentService.claude.suggestedDirectory)],
            codex: [.direct(AgentService.codex.suggestedDirectory)]
        )
    }
}

@MainActor
final class SandboxAgentRootProvider: AgentRootProviding {
    private let defaults: UserDefaults
    private var activeURLs: [AgentService: URL] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        for url in activeURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func roots() -> AgentRootConfiguration {
        AgentRootConfiguration(
            claude: transferGrant(for: .claude).map { [$0] } ?? [],
            codex: transferGrant(for: .codex).map { [$0] } ?? []
        )
    }

    func isAuthorized(_ service: AgentService) -> Bool {
        defaults.data(forKey: bookmarkKey(for: service)) != nil
    }

    func chooseRoot(for service: AgentService) -> FolderChoice {
        let panel = NSOpenPanel()
        panel.title = "Select \(service.displayName) session folder"
        panel.message = "aI'm Thinking only reads newly appended session data from this folder."
        panel.prompt = "Allow Read Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = service.suggestedDirectory.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }
        if let problem = service.folderProblem(at: url) {
            return .rejected(problem)
        }

        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: bookmarkKey(for: service))
            releaseActiveURL(for: service)
            return .granted
        } catch {
            return .rejected("Could not save access to this folder. Try again.")
        }
    }

    func revoke(_ service: AgentService) {
        releaseActiveURL(for: service)
        defaults.removeObject(forKey: bookmarkKey(for: service))
    }

    private func transferGrant(for service: AgentService) -> AgentRootGrant? {
        guard let bookmark = defaults.data(forKey: bookmarkKey(for: service)) else {
            return nil
        }

        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )

            guard url.startAccessingSecurityScopedResource() else {
                return nil
            }

            releaseActiveURL(for: service)
            activeURLs[service] = url

            if stale {
                let refreshed = try url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                defaults.set(refreshed, forKey: bookmarkKey(for: service))
            }

            // Apple recommends a regular/implicit bookmark for transferring a
            // user-granted sandbox extension to another process.
            let transfer = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return .bookmark(transfer)
        } catch {
            releaseActiveURL(for: service)
            return nil
        }
    }

    private func bookmarkKey(for service: AgentService) -> String {
        "agentRootBookmark.\(service.rawValue)"
    }

    private func releaseActiveURL(for service: AgentService) {
        guard let url = activeURLs.removeValue(forKey: service) else {
            return
        }
        url.stopAccessingSecurityScopedResource()
    }
}
