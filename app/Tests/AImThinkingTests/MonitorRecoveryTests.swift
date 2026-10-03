import AVFoundation
import Foundation
import Testing
@testable import AImThinking

@Test @MainActor
func invalidBookmarkRequiresAuthorizationAndCannotFinishOnboarding() throws {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data([1, 2, 3]), forKey: "agentRootBookmark.claude")
    let provider = SandboxAgentRootProvider(defaults: defaults)
    #expect(provider.hasSavedRoot(.claude))
    #expect(!provider.isAuthorized(.claude))
    #expect(provider.roots().claude.isEmpty)
    let model = AppModel(defaults: defaults, startMonitoring: false, distributionMode: .appStore)
    #expect(!model.claudeFolderAuthorized)
    #expect(!model.canFinishOnboarding)
    #expect(model.folderErrors[.claude]?.contains("Choose the folder again") == true)
    model.handle(try JSONDecoder().decode(CoreMessage.self, from: Data(
        #"{"v":1,"type":"observer_status","agent":"claude","status":"monitoring"}"#.utf8)))
    #expect(model.claudeFolderAuthorized)
    #expect(model.folderErrors[.claude] == nil)
    provider.revoke(.claude)
    #expect(!provider.hasSavedRoot(.claude))
}

@Test @MainActor
func directFolderChoicePersistsAndResetRestoresDefault() throws {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = directory.appending(path: "projects")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let provider = DirectAgentRootProvider(defaults: defaults)
    #expect(provider.saveRoot(folder, for: .claude) == .granted)
    let restored = DirectAgentRootProvider(defaults: defaults)
    #expect(restored.roots().claude.first?.path == folder.path)
    #expect(restored.isAuthorized(.claude))
    #expect(restored.hasSavedRoot(.claude))
    // A rejected choice must preserve the working selection.
    if case .rejected = restored.saveRoot(directory, for: .claude) {} else {
        Issue.record("Accepted a parent folder")
    }
    #expect(restored.roots().claude.first?.path == folder.path)
    try FileManager.default.removeItem(at: folder)
    #expect(!restored.isAuthorized(.claude))
    restored.revoke(.claude)
    #expect(restored.roots().claude.first?.path == AgentService.claude.suggestedDirectory.path)
    #expect(!restored.hasSavedRoot(.claude))
}

@Test @MainActor
func observerFailureClearsOnlyAffectedActivityAndExplainsRecovery() throws {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "muted")
    // Only Claude has a folder the user chose; Codex uses the default.
    defaults.set("/nonexistent/.claude/projects", forKey: "agentRootPath.claude")
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults, startMonitoring: false, distributionMode: .direct)
    func deliver(_ json: String) throws {
        model.handle(try JSONDecoder().decode(CoreMessage.self, from: Data(json.utf8)))
    }
    try deliver(#"{"v":1,"type":"activity","session":1,"agent":"claude","phase":"thinking","intensity":0.4}"#)
    try deliver(#"{"v":1,"type":"activity","session":2,"agent":"codex","phase":"thinking","intensity":0.4}"#)
    try deliver(#"{"v":1,"type":"observer_status","agent":"claude","status":"directory_missing"}"#)
    #expect(model.observerProblem(for: .claude) == "Folder missing")
    #expect(!model.claudeFolderAuthorized)
    #expect(model.claudeState == "Idle")
    #expect(model.codexState == "Thinking")
    try deliver(#"{"v":1,"type":"observer_status","agent":"claude","status":"monitoring"}"#)
    #expect(model.observerProblem(for: .claude) == nil)
    #expect(model.claudeFolderAuthorized)
    #expect(model.claudeState == "Idle") // Old activity must not resume.
    try deliver(#"{"v":1,"type":"observer_status","agent":"codex","status":"error"}"#)
    #expect(model.observerProblem(for: .codex) == "Using file polling")
    #expect(model.codexState == "Thinking") // Polling can keep delivering activity.
    model.pauseSessions(for: .codex)
    try deliver(#"{"v":1,"type":"observer_status","agent":"codex","status":"access_denied"}"#)
    #expect(model.isPaused(.codex)) // A temporary failure must not lose the resume control.
    // An agent the user never set up is not reported as a problem.
    try deliver(#"{"v":1,"type":"observer_status","agent":"codex","status":"directory_missing"}"#)
    #expect(model.observerProblem(for: .codex) == nil)
    try deliver(#"{"v":1,"type":"observer_status","agent":"codex","status":"access_required"}"#)
    #expect(model.observerProblem(for: .codex) == nil)
    model.stopCore()
}

@Test @MainActor
func loginRegistrationErrorIsShownWithoutChangingOSSettings() {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults, startMonitoring: false, loginItemSetter: { _ in
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Registration denied"])
    })
    model.setStartAtLogin(true)
    #expect(model.loginItemMessage?.contains("Registration denied") == true)
    #expect(model.startAtLogin == LoginItemManager.isEnabled)
}

@Test @MainActor
func previewStopsEngineWhenIdleButLeavesActivityPlaying() async throws {
    let sounds = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Resources/Sounds").standardized
    let audio = KeyboardAudioEngine(pack: .hermes, soundsDirectory: sounds)
    audio.volume = 0
    let scheduler = TypingScheduler(audio: audio)
    defer { scheduler.stop(); audio.stop() }
    audio.preview()
    #expect(audio.isRunning)
    try await Task.sleep(for: .seconds(1))
    #expect(!audio.isRunning)

    audio.preview { scheduler.isRunning }
    try await Task.sleep(for: .milliseconds(100))
    scheduler.update(phase: "writing", intensity: 0.5, toolClass: nil)
    try await Task.sleep(for: .seconds(1))
    #expect(scheduler.isRunning)
    #expect(audio.isRunning)
    scheduler.stop()
    audio.stop()
    audio.muted = true
    audio.preview()
    try await Task.sleep(for: .milliseconds(250))
    #expect(!audio.isRunning)
}

private func makeCore(_ body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "fake-core")
    try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

@Test @MainActor
func crashedCoreRecoversAndCompletedHandshakeDoesNotTimeOut() async throws {
    let executable = try makeCore(#"""
    attempts="$(dirname "$0")/attempts"
    printf '.\n' >> "$attempts"
    if [ "$(wc -l < "$attempts")" -eq 1 ]; then exit 1; fi
    printf '%s\n' '{"v":1,"type":"hello"}'
    read -r command
    printf '%s\n' '{"v":1,"type":"ready"}'
    while read -r command; do
        case "$command" in *shutdown*) exit 0 ;; esac
    done
    """#)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let bridge = CoreBridge(executableURL: executable, handshakeTimeout: .milliseconds(500), retryDelay: .milliseconds(30))
    var status = CoreStatus.stopped
    bridge.onStatus = { status = $0 }
    bridge.start()
    defer { bridge.stop(force: true) }
    for _ in 0..<150 where status != .monitoring {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(status == .monitoring)
    try await Task.sleep(for: .milliseconds(600))
    #expect(status == .monitoring)
    #expect(bridge.diagnosticLog.contains("code=CORE_EXIT"))
    let attempts = try String(contentsOf: executable.deletingLastPathComponent().appending(path: "attempts"), encoding: .utf8)
    #expect(attempts.split(separator: "\n").count == 2)
}

@Test @MainActor
func handshakeTimeoutRetriesAreBoundedAndManualStopCancelsRetry() async throws {
    // Never announces hello; unlike sleep, read exits immediately on shutdown/EOF.
    let executable = try makeCore(#"""
    printf '.\n' >> "$(dirname "$0")/attempts"
    while read -r command; do
        case "$command" in *shutdown*) exit 0 ;; esac
    done
    """#)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    let bridge = CoreBridge(executableURL: executable, handshakeTimeout: .milliseconds(500), retryDelay: .milliseconds(30))
    var status = CoreStatus.stopped
    bridge.onStatus = { status = $0 }
    bridge.start()
    defer { bridge.stop(force: true) }
    for _ in 0..<300 where status != .failed("CORE_RETRY_LIMIT") {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(status == .failed("CORE_RETRY_LIMIT"))
    #expect(bridge.diagnosticLog.contains("code=CORE_TIMEOUT"))
    let attemptsURL = executable.deletingLastPathComponent().appending(path: "attempts")
    let attempts = try String(contentsOf: attemptsURL, encoding: .utf8)
    #expect(attempts.split(separator: "\n").count == 4)
    bridge.restart()
    bridge.stop(force: true)
    try await Task.sleep(for: .milliseconds(400))
    #expect(status == .stopped)
    #expect(try String(contentsOf: attemptsURL, encoding: .utf8) == attempts)
}
