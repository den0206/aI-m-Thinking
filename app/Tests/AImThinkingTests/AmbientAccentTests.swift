import AVFoundation
import Foundation
import Testing
@testable import AImThinking

@Test
func ambientAccentSelectionMatchesActivityContext() {
    #expect(AmbientAccentScheduler.chooseKind(phase: "thinking", toolClass: nil, roll: 0.10) == .pageTurn)
    #expect(AmbientAccentScheduler.chooseKind(phase: "thinking", toolClass: nil, roll: 0.60) == .rain)
    #expect(AmbientAccentScheduler.chooseKind(phase: "writing", toolClass: nil, roll: 0.10) == .rain)
    #expect(AmbientAccentScheduler.chooseKind(phase: "tool", toolClass: "read", roll: 0.10) == .pageTurn)
}

@Test
func ambientAccentNeverRepeatsThePreviousSound() {
    for roll in stride(from: 0.0, to: 1.0, by: 0.05) {
        for previous in AmbientAccentKind.allCases {
            let kind = AmbientAccentScheduler.chooseKind(phase: "thinking", toolClass: nil, excluding: previous, roll: roll)
            #expect(kind != previous)
        }
    }
}

@Test @MainActor
func ambientAccentTimerCountsOnlyAudibleWorkingTime() async throws {
    // Missing directory: play() is a silent no-op, lastKind still records the accent.
    let scheduler = AmbientAccentScheduler(
        audio: AmbientAudioEngine(directory: nil),
        interval: 2...2
    )
    scheduler.isEnabled = true

    scheduler.update(phase: "thinking", toolClass: nil, audible: true)
    try await Task.sleep(for: .milliseconds(1000))
    // A turn left open but silent (permission prompt, quiet tool) must not count.
    scheduler.update(phase: "tool", toolClass: "shell", audible: false)
    try await Task.sleep(for: .milliseconds(1500))
    #expect(scheduler.lastKind == nil, "silent time must not count")

    // ~1 s of the 2 s budget is left; a reset timer would need the full 2 s.
    // Each check keeps 0.5 s or more of slack for slow CI runners.
    scheduler.update(phase: "thinking", toolClass: nil, audible: true)
    try await Task.sleep(for: .milliseconds(1500))
    #expect(scheduler.lastKind != nil)
    scheduler.stop()
}

@Test
func everyAmbientAccentFileIsBundledAndReadable() throws {
    let directory = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/Ambient")
    for kind in AmbientAccentKind.allCases {
        let file = try AVAudioFile(forReading: directory.appending(path: kind.fileName))
        #expect(file.length > 0, "\(kind.fileName)")
    }
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
