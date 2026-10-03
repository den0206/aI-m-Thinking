import AVFoundation
import Foundation
import Testing
@testable import AImThinking

@Test
func sixBuiltInSoundPacksExist() {
    #expect(SoundPackID.allCases.count == 6)
}

@Test
func idleAndNonMutationToolsAreSilent() {
    #expect(TypingScheduler.keysPerSecond(intensity: 1, phase: "idle", toolClass: nil) == 0)
    #expect(TypingScheduler.keysPerSecond(intensity: 1, phase: "tool", toolClass: "shell") == 0)
}

@Test
func maximumRateIsBounded() {
    for speed in [0.3, 1.2, 2.1] {
        #expect(TypingScheduler.keysPerSecond(intensity: 1, phase: "writing", toolClass: nil, speedScale: speed) <= TypingScheduler.maxKeysPerSecond)
    }
}

@Test
func speedSliderChangesRateAtFullIntensity() {
    let rate = { TypingScheduler.keysPerSecond(intensity: 1, phase: "writing", toolClass: nil, speedScale: $0) }
    #expect(rate(2.1) > rate(1.2))
    #expect(rate(1.2) > rate(0.3))
}

@Test @MainActor
func zeroVolumeMutesAndUnmuteRestoresVolume() {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults, startMonitoring: false)
    model.setVolume(0)
    #expect(model.muted)
    model.setMuted(false)
    #expect(model.volume > 0)
    model.setVolume(0.3)
    #expect(!model.muted)
}

@Test @MainActor
func savedZeroVolumeStartsMuted() {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(0.0, forKey: "volume")
    let model = AppModel(defaults: defaults, startMonitoring: false)
    #expect(model.muted)
}

@Test @MainActor
func activityAnimationStopsForIdleSilenceAndMonitorShutdown() async throws {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    // Nearly silent rather than muted: mute stops the keycap animation.
    defaults.set(0.01, forKey: "volume")
    let model = AppModel(defaults: defaults, startMonitoring: false)

    func activity(_ session: Int, _ phase: String, _ intensity: Double) throws -> CoreMessage {
        let data = try JSONSerialization.data(withJSONObject: [
            "v": 1, "type": "activity", "session": session, "agent": "codex",
            "phase": phase, "intensity": intensity
        ])
        return try JSONDecoder().decode(CoreMessage.self, from: data)
    }

    model.handle(try activity(1, "thinking", 0.4))
    #expect(model.keyPress.isAnimating)
    model.setMuted(true)
    #expect(!model.keyPress.isAnimating)
    #expect(model.menuBarState == .muted)
    model.setMuted(false)
    #expect(model.keyPress.isAnimating)
    #expect(model.menuBarState == nil)
    try await Task.sleep(for: .milliseconds(20))
    model.handle(try activity(1, "idle", 0.3)) // Even a residual tail is idle.
    #expect(!model.keyPress.isAnimating)
    #expect(model.keyPress.frame == 0)

    model.handle(try activity(1, "thinking", 0.4))
    model.handle(try activity(2, "thinking", 0.0)) // A stale/replayed session.
    model.handle(try activity(1, "idle", 0))
    #expect(!model.keyPress.isAnimating)
    #expect(model.codexState == "Idle") // Silent history must not leave Thinking… visible.
    model.handle(try activity(2, "thinking", 0.05))
    #expect(model.codexState == "Idle")
    model.handle(try activity(2, "thinking", 0.4))
    #expect(model.codexState == "Thinking")
    model.handle(try activity(2, "idle", 0))
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.keyPress.frame == 0) // Cancelled tasks cannot redraw a pressed key.

    model.handle(try activity(1, "writing", 0.4))
    model.stopCore()
    #expect(!model.keyPress.isAnimating)
    #expect(model.keyPress.frame == 0)
}

@Test
func higherWritingIntensityProducesFasterCadence() {
    let low = TypingScheduler.keysPerSecond(intensity: 0.25, phase: "writing", toolClass: nil)
    let high = TypingScheduler.keysPerSecond(intensity: 0.85, phase: "writing", toolClass: nil)
    #expect(high > low)
}

@Test @MainActor
func oldCoreExitCannotDisconnectRestartedMonitor() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appending(path: "fake-core")
    try """
    #!/bin/sh
    trap '' TERM
    printf '%s\\n' '{"v":1,"type":"hello"}'
    read -r command
    printf '%s\\n' '{"v":1,"type":"ready"}'
    while read -r command; do
        case "$command" in
            *shutdown*) sleep 0.6; exit 0 ;;
            *rescan*) printf '%s\\n' '{"v":1,"type":"observer_status","agent":"codex","status":"monitoring"}' ;;
        esac
    done
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let bridge = CoreBridge(executableURL: executable)
    var status: CoreStatus = .unavailable
    var rescanned = false
    bridge.onStatus = { status = $0 }
    bridge.onMessage = { if $0.type == "observer_status" { rescanned = true } }
    bridge.start()
    defer { bridge.stop(force: true) }
    for _ in 0..<100 where status != .monitoring {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(status == .monitoring)
    bridge.restart()
    try await Task.sleep(for: .seconds(1))
    #expect(status == .monitoring)
    bridge.rescan()
    for _ in 0..<100 where !rescanned {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(rescanned)
    #expect(bridge.diagnosticLog.contains("type=ready"))
    #expect(!bridge.diagnosticLog.contains(directory.path))
}


@Test @MainActor
func directRootGrantEncodesOnlyPath() {
    let grant = AgentRootGrant.direct(URL(fileURLWithPath: "/tmp/claude"))
    #expect(grant.path == "/tmp/claude")
    #expect(grant.bookmark == nil)
    #expect(grant.jsonObject["path"] as? String == "/tmp/claude")
    #expect(grant.jsonObject["bookmark"] == nil)
}

@Test
func bookmarkRootGrantEncodesOnlyBookmark() {
    let data = Data([0x01, 0x02, 0x03])
    let grant = AgentRootGrant.bookmark(data)
    #expect(grant.path == nil)
    #expect(grant.bookmark == data.base64EncodedString())
    #expect(grant.jsonObject["path"] == nil)
    #expect(grant.jsonObject["bookmark"] as? String == data.base64EncodedString())
}

@Test
func everySoundPackSynthesizesAudibleUnclippedBuffers() {
    for pack in SoundPackID.allCases {
        let bank = SoundSamples.makeBank(for: pack, directory: soundsDirectory)
        #expect(bank != nil)
        #expect(bank?.keys.isEmpty == false)
        #expect(bank?.spaces.isEmpty == false)
        #expect(bank?.enters.isEmpty == false)
        for buffer in (bank?.keys ?? []) + (bank?.spaces ?? []) + (bank?.enters ?? []) {
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            let peak = samples.map(abs).max() ?? 0
            #expect(peak > 0.1 && peak <= 1.0)
            #expect(buffer.frameLength < AVAudioFrameCount(SoundSamples.sampleRate * 0.4))
        }
    }
}

@Test
func dedicatedKeycapSamplesKeepTheirPitchAndStayOutOfNormalKeys() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let packDirectory = directory.appending(path: "hermes")
    try FileManager.default.createDirectory(at: packDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = soundsDirectory.appending(path: "hermes/key_press.wav")
    for name in ["key_press.wav", "space_press.wav", "enter_press.wav"] {
        try FileManager.default.copyItem(at: source, to: packDirectory.appending(path: name))
    }
    let bank = try #require(SoundSamples.makeBank(for: .hermes, directory: directory))
    #expect(bank.keys.count == 1)
    #expect(bank.spaces.count == 1)
    #expect(bank.enters.count == 1)
    #expect(bank.keys[0].frameLength == bank.spaces[0].frameLength)
    #expect(bank.keys[0].frameLength == bank.enters[0].frameLength)

    try FileManager.default.removeItem(at: packDirectory.appending(path: "enter_press.wav"))
    let fallback = try #require(SoundSamples.makeBank(for: .hermes, directory: directory))
    #expect(fallback.enters.count == 1)
    #expect(fallback.enters[0].frameLength > fallback.keys[0].frameLength)
}

private let soundsDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "../../Resources/Sounds")
    .standardized

@Test @MainActor
func sessionPauseRequiresManualResumeAndLeavesOtherSessionsActive() throws {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    // Nearly silent rather than muted: mute stops the keycap animation.
    defaults.set(0.01, forKey: "volume")
    let model = AppModel(defaults: defaults, startMonitoring: false)
    func activity(_ session: Int, _ agent: String, _ intensity: Double) throws -> CoreMessage {
        let data = try JSONSerialization.data(withJSONObject: [
            "v": 1, "type": "activity", "session": session, "agent": agent,
            "phase": "thinking", "intensity": intensity
        ])
        return try JSONDecoder().decode(CoreMessage.self, from: data)
    }
    model.handle(try activity(1, "claude", 0.8))
    model.handle(try activity(2, "claude", 0.4))
    model.handle(try activity(3, "codex", 0.5))
    model.pauseSessions(for: .claude)
    #expect(model.pausedSessions == [1, 2]) // Every active Claude session.
    #expect(model.claudeState == "Paused")
    #expect(model.codexState == "Thinking")
    #expect(model.keyPress.isAnimating) // Codex continues.
    #expect(model.menuBarState == .paused)
    model.setMuted(true)
    #expect(model.menuBarState == .muted) // Mute wins over pause.
    model.setMuted(false)
    model.handle(try activity(1, "claude", 1))
    #expect(model.claudeState == "Paused")
    // A session that starts after the pause is monitored and can be paused too.
    model.handle(try activity(4, "claude", 0.4))
    #expect(model.claudeState == "Thinking")
    model.pauseSessions(for: .claude)
    #expect(model.pausedSessions == [1, 2, 4])
    model.resumeSessions(for: .claude)
    #expect(model.pausedSessions.isEmpty)
    #expect(model.claudeState == "Idle")
    #expect(model.menuBarState == nil)
    model.handle(try activity(1, "claude", 0.4))
    #expect(model.claudeState == "Thinking")
    model.pauseSessions(for: .claude)
    let closed = try JSONDecoder().decode(CoreMessage.self, from: Data(
        #"{"v":1,"type":"session_closed","session":1}"#.utf8))
    model.handle(closed)
    #expect(!model.isPaused(.claude))
    model.handle(try activity(6, "claude", 0.8))
    model.pauseSessions(for: .claude)
    model.handle(try activity(7, "claude", 0.4))
    #expect(model.isPaused(.claude))
    #expect(model.claudeState == "Thinking")
    model.resumeSessions(for: .claude)
    #expect(model.pausedSessions.isEmpty)
    #expect(model.claudeState == "Thinking") // The unpaused session continues.
    model.stopCore()
    #expect(model.pausedSessions.isEmpty)
}

@Test @MainActor
func stateKeycapsArePrintedTemplatesOfTheSameHeight() {
    for state in KeycapIcon.State.allCases {
        for frame in KeycapIcon.frames.indices {
            let image = KeycapIcon.image(frame: frame, state: state)
            #expect(image !== KeycapIcon.frames[frame])
            #expect(image.isTemplate)
            #expect(image.size.height == KeycapIcon.frames[frame].size.height)
        }
    }
    #expect(KeycapIcon.image(frame: 2, state: nil) === KeycapIcon.frames[2])
}

@Test @MainActor
func sliderLabelsReadDefaultsAsFiftyPercentAndOneX() {
    #expect(AppModel.volumeLabel(0) == "0%")
    #expect(AppModel.volumeLabel(AppModel.defaultVolume) == "50%")
    #expect(AppModel.volumeLabel(1) == "100%")
    #expect(AppModel.typingSpeedLabel(AppModel.typingSpeedRange.lowerBound) == "×0.2")
    #expect(AppModel.typingSpeedLabel(AppModel.defaultTypingSpeed) == "×1.0")
    #expect(AppModel.typingSpeedLabel(AppModel.typingSpeedRange.upperBound) == "×2.0")
}


@Test
func ambientAccentSelectionMatchesActivityContext() {
    #expect(AmbientAccentScheduler.chooseKind(phase: "thinking", toolClass: nil, roll: 0.10) == .writing)
    #expect(AmbientAccentScheduler.chooseKind(phase: "thinking", toolClass: nil, roll: 0.45) == .pageTurn)
    #expect(AmbientAccentScheduler.chooseKind(phase: "writing", toolClass: nil, roll: 0.10) == .rain)
    #expect(AmbientAccentScheduler.chooseKind(phase: "tool", toolClass: "read", roll: 0.10) == .pageTurn)
}

@Test @MainActor
func ambientAccentsDefaultOffAndPersist() {
    let suite = "ambient-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults, startMonitoring: false)
    #expect(!model.ambientAccentsEnabled)
    model.setAmbientAccentsEnabled(true)
    #expect(model.ambientAccentsEnabled)
    #expect(defaults.bool(forKey: "ambientAccentsEnabled"))
}
