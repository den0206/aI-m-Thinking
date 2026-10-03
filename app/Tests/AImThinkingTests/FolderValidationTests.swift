import Foundation
import Testing
@testable import AImThinking

/// Each test owns one temporary root and removes it with `defer`.
private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "im-thinking-\(UUID().uuidString)")
}

private func makeFolder(_ path: String, children: [String] = [], in root: URL) throws -> URL {
    let url = root
        .appending(path: UUID().uuidString)
        .appending(path: path, directoryHint: .isDirectory)
    for child in children {
        try FileManager.default.createDirectory(at: url.appending(path: child), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test
func expectedFoldersPassEvenWhenEmptyOrRelocated() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(AgentService.claude.folderProblem(at: try makeFolder(".claude/projects", children: ["-Users-me-app"], in: root)) == nil)
    #expect(AgentService.codex.folderProblem(at: try makeFolder(".codex/sessions", children: ["2026"], in: root)) == nil)
    #expect(AgentService.claude.folderProblem(at: try makeFolder("custom-claude/projects", in: root)) == nil)
    #expect(AgentService.codex.folderProblem(at: try makeFolder("custom-codex/sessions", in: root)) == nil)
}

@Test
func swappedAgentFoldersAreRejected() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let codexLayout = try makeFolder("elsewhere/projects", children: ["2026"], in: root)
    #expect(AgentService.claude.folderProblem(at: codexLayout)?.contains("Codex") == true)
    #expect(AgentService.claude.folderProblem(at: try makeFolder(".codex/sessions", in: root))?.contains("Codex") == true)

    let claudeLayout = try makeFolder("elsewhere/sessions", children: ["-Users-me-app"], in: root)
    #expect(AgentService.codex.folderProblem(at: claudeLayout)?.contains("Claude Code") == true)
    // ~/.claude/sessions is Claude's, even though it is named "sessions".
    #expect(AgentService.codex.folderProblem(at: try makeFolder(".claude/sessions", in: root))?.contains("Claude Code") == true)
}

@Test
func parentFoldersAreRejected() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(AgentService.claude.folderProblem(at: try makeFolder(".claude", in: root)) == "Choose the projects folder inside ~/.claude.")
    #expect(AgentService.codex.folderProblem(at: try makeFolder("codex-home", in: root)) == "Choose the sessions folder inside ~/.codex.")
}
