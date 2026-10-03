import AVFoundation
import Foundation
import Testing
@testable import ImThinking

@Test
func fiveBuiltInSoundPacksExist() {
    #expect(SoundPackID.allCases.count == 5)
}

@Test
func idleAndNonMutationToolsAreSilent() {
    #expect(TypingScheduler.keysPerSecond(intensity: 1, phase: "idle", toolClass: nil) == 0)
    #expect(TypingScheduler.keysPerSecond(intensity: 1, phase: "tool", toolClass: "shell") == 0)
}

@Test
func maximumRateIsBounded() {
    for speed in [0.6, 1.2, 1.8] {
        #expect(TypingScheduler.keysPerSecond(intensity: 1, phase: "writing", toolClass: nil, speedScale: speed) <= 15)
    }
}

@Test @MainActor
func activityAnimationStopsForIdleSilenceAndMonitorShutdown() async throws {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: "muted")
    let model = AppModel(defaults: defaults, startMonitoring: false)

    func activity(_ session: Int, _ phase: String, _ intensity: Double) throws -> CoreMessage {
        let data = try JSONSerialization.data(withJSONObject: [
            "v": 1, "type": "activity", "session": session, "agent": "codex",
            "phase": phase, "intensity": intensity
        ])
        return try JSONDecoder().decode(CoreMessage.self, from: data)
    }

    model.handle(try activity(1, "thinking", 0.4))
    #expect(model.keyPress.isAnimating) // Mute does not hide activity.
    try await Task.sleep(for: .milliseconds(20))
    model.handle(try activity(1, "idle", 0.3)) // Even a residual tail is idle.
    #expect(!model.keyPress.isAnimating)
    #expect(model.keyPress.frame == 0)

    model.handle(try activity(1, "thinking", 0.4))
    model.handle(try activity(2, "thinking", 0.0)) // A stale/replayed session.
    model.handle(try activity(1, "idle", 0))
    #expect(!model.keyPress.isAnimating)
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
        for buffer in (bank?.keys ?? []) + (bank?.spaces ?? []) + (bank?.enters ?? []) {
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            let peak = samples.map(abs).max() ?? 0
            #expect(peak > 0.1 && peak <= 1.0)
            #expect(buffer.frameLength < AVAudioFrameCount(SoundSamples.sampleRate * 0.4))
        }
    }
}

private let soundsDirectory = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .appending(path: "../../Resources/Sounds/kc1000")
    .standardized
