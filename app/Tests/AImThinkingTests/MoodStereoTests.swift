import AppKit
import Foundation
import Testing
@testable import AImThinking

@Test
func moodUsesMaximumIntensityAndRejectsInactiveOrInvalidSamples() {
    var selection = MoodSelection()
    selection.update([
        MoodActivity(agent: .claude, phase: "thinking", intensity: 0.3),
        MoodActivity(agent: .claude, phase: "writing", intensity: 0.3),
        MoodActivity(agent: .codex, phase: "tool", intensity: 0.5),
        MoodActivity(agent: .claude, phase: "idle", intensity: 1),
        MoodActivity(agent: .claude, phase: "thinking", intensity: .nan)
    ], now: 0)
    #expect(selection.selected?.agent == .codex)
    selection.update([MoodActivity(agent: .codex, phase: "writing", intensity: 0.05)], now: 1)
    #expect(selection.selected == nil)
    #expect(selection.deadline == nil)
}

@Test
func moodDominanceMustBeSustainedAndRespectDwell() {
    var selection = MoodSelection()
    let claude = MoodActivity(agent: .claude, phase: "writing", intensity: 0.4)
    let codex = MoodActivity(agent: .codex, phase: "writing", intensity: 0.8)
    selection.update([claude], now: 0)
    selection.update([claude, codex], now: 0.1)
    #expect(selection.deadline == 2)
    selection.update([claude, codex], now: 1.99)
    #expect(selection.selected?.agent == .claude)
    selection.update([claude, codex], now: 2)
    #expect(selection.selected?.agent == .codex)
    #expect(selection.deadline == nil)
    // Losing the incumbent overrides dwell immediately.
    selection.update([claude], now: 2.01)
    #expect(selection.selected?.agent == .claude)
}

@Test
func moodContenderTimerRestartsAfterDominanceIsLost() {
    var selection = MoodSelection()
    let claude = MoodActivity(agent: .claude, phase: "thinking", intensity: 0.4)
    let strong = MoodActivity(agent: .codex, phase: "writing", intensity: 0.8)
    let weak = MoodActivity(agent: .codex, phase: "writing", intensity: 0.5)
    selection.update([claude], now: 0)
    selection.update([claude, strong], now: 2)
    selection.update([claude, weak], now: 2.5)
    #expect(selection.deadline == nil)
    selection.update([claude, strong], now: 3)
    #expect(selection.deadline == 3.8)
    selection.update([claude, strong], now: 3.7)
    #expect(selection.selected?.agent == .claude)
    selection.update([claude, strong], now: 3.8)
    #expect(selection.selected?.agent == .codex)
}

@Test @MainActor
func moodDeadlineSelectsWithoutAnotherActivityEvent() async throws {
    let mood = MoodCoordinator()
    let claude = MoodActivity(agent: .claude, phase: "writing", intensity: 0.3)
    mood.update([claude], enabled: true, glow: 0.3, reducedMotion: true)
    mood.update([claude, MoodActivity(agent: .codex, phase: "writing", intensity: 0.8)],
                enabled: true, glow: 0.3, reducedMotion: true)
    #expect(mood.hasPendingSelection)
    let timeout = ContinuousClock.now + .seconds(3)
    while mood.selection.selected?.agent != .codex, ContinuousClock.now < timeout {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(mood.selection.selected?.agent == .codex)
    #expect(!mood.hasPendingSelection)
    #expect(!mood.isAnimating)
    mood.reset()
}

@Test @MainActor
func moodPulseStopsForReducedMotionDisableIdleAndZeroGlow() async throws {
    let mood = MoodCoordinator()
    let activity = [MoodActivity(agent: .claude, phase: "thinking", intensity: 0.8)]
    mood.update(activity, enabled: true, glow: 1, reducedMotion: false)
    #expect(mood.isAnimating)
    try await Task.sleep(for: .milliseconds(400))
    let first = mood.appearance
    try await Task.sleep(for: .milliseconds(700))
    #expect(mood.appearance != first)
    mood.update(activity, enabled: true, glow: 1, reducedMotion: true)
    #expect(!mood.isAnimating)
    #expect(mood.appearance?.agent == .claude)
    mood.update(activity, enabled: true, glow: 0, reducedMotion: false)
    #expect(!mood.isAnimating)
    #expect(mood.appearance == nil)
    mood.update(activity, enabled: false, glow: 1, reducedMotion: false)
    #expect(mood.selection.selected == nil)
    #expect(!mood.hasPendingSelection)
    mood.update(activity, enabled: true, glow: 1, reducedMotion: false)
    mood.update([], enabled: true, glow: 1, reducedMotion: false)
    #expect(mood.appearance == nil)
    #expect(!mood.isAnimating)
}

@Test @MainActor
func moodIntegrationPreservesPartialPauseAndNeutralizesMuteAndFailure() throws {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults, startMonitoring: false)
    model.setReducedMotion(true)
    model.setMoodEnabled(true)
    func activity(_ session: Int, _ agent: String) throws -> CoreMessage {
        try JSONDecoder().decode(CoreMessage.self, from: JSONSerialization.data(withJSONObject: [
            "v": 1, "type": "activity", "session": session, "agent": agent,
            "phase": "thinking", "intensity": 0.8
        ]))
    }
    model.handle(try activity(1, "claude"))
    model.handle(try activity(2, "codex"))
    model.pauseSessions(for: .claude)
    #expect(model.menuBarState == .paused)
    #expect(model.mood.appearance?.agent == .codex)
    #expect(!model.keyPress.isAnimating)
    model.setMuted(true)
    #expect(model.menuBarState == .muted)
    #expect(model.mood.appearance == nil)
    model.setMuted(false)
    #expect(model.mood.appearance?.agent == .codex)
    model.handle(try JSONDecoder().decode(CoreMessage.self, from: Data(
        #"{"v":1,"type":"observer_status","agent":"codex","status":"directory_missing"}"#.utf8)))
    #expect(model.mood.appearance == nil)
    model.handle(try activity(3, "claude"))
    #expect(model.mood.appearance?.agent == .claude)
    model.stopCore()
    #expect(model.mood.appearance == nil)
    #expect(!model.mood.isAnimating)
    #expect(!model.mood.hasPendingSelection)
}

@Test @MainActor
func newSettingsDefaultOffClampAndPersist() {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults, startMonitoring: false)
    #expect(!model.moodEnabled && !model.stereoEnabled)
    #expect(AppModel.moodGlowIntensity == 0.3 && model.stereoWidth == 0.25)
    model.setMoodEnabled(true)
    model.setStereoEnabled(true)
    model.setStereoWidth(.infinity)
    #expect(AppModel.moodGlowIntensity == 0.3 && model.stereoWidth == 0.25)
    model.setStereoWidth(-1)
    let restored = AppModel(defaults: defaults, startMonitoring: false)
    #expect(restored.moodEnabled && restored.stereoEnabled)
    #expect(restored.stereoWidth == 0)
    defaults.set("invalid", forKey: "glowIntensity")
    defaults.set(Double.nan, forKey: "stereoWidthV2")
    let invalid = AppModel(defaults: defaults, startMonitoring: false)
    #expect(AppModel.moodGlowIntensity == 0.3 && invalid.stereoWidth == 0.25)
}

@Test
func stereoIsCenteredAtZeroAndBoundedAtEveryWidth() {
    for kind in [KeySoundKind.key, .space, .enter] {
        for index in 0..<32 {
            for variance in [-1.0, -0.06, 0, 0.06, 1] {
                #expect(StereoProfile.pan(kind: kind, sampleIndex: index, sampleCount: 32,
                                          width: 0, variation: variance) == 0)
                for width in [0.25, 1, 2, Double.nan] {
                    let pan = StereoProfile.pan(kind: kind, sampleIndex: index, sampleCount: 32,
                                                width: width, variation: variance)
                    #expect(pan.isFinite && abs(pan) <= 1)
                }
            }
        }
    }
    #expect(StereoProfile.pan(kind: .key, sampleIndex: 0, sampleCount: 1, width: 1, variation: 0) == 0)
    #expect(StereoProfile.pan(kind: .key, sampleIndex: 0, sampleCount: 32, width: 1, variation: 0) < 0)
    #expect(StereoProfile.pan(kind: .key, sampleIndex: 31, sampleCount: 32, width: 1, variation: 0) > 0)
    let base = StereoProfile.pan(kind: .key, sampleIndex: 10, sampleCount: 32, width: 1, variation: 0)
    let varied = StereoProfile.pan(kind: .key, sampleIndex: 10, sampleCount: 32, width: 1, variation: 0.06)
    #expect(abs(varied - base) <= 0.08)
}

@Test @MainActor
func coloredKeycapsPreserveGeometryTemplatesAndBoundedCache() {
    for frame in KeycapIcon.frames.indices {
        for dark in [false, true] {
            for contrast in [false, true] {
                for agent in AgentService.allCases {
                    for level in 1...MoodAppearance.levels {
                        let image = KeycapMoodRenderer.image(frame: frame, state: nil,
                            mood: MoodAppearance(agent: agent, level: level), dark: dark, highContrast: contrast)
                        #expect(!image.isTemplate)
                        #expect(image.size == KeycapIcon.frames[frame].size)
                        #expect(KeycapMoodRenderer.cachedImageCount <= KeycapMoodRenderer.cacheLimit)
                    }
                }
            }
        }
    }
    let mood = MoodAppearance(agent: .claude, level: 10)
    let image = KeycapMoodRenderer.image(frame: 2, state: .paused, mood: mood, dark: true, highContrast: true)
    #expect(image.size == KeycapIcon.image(frame: 2, state: .paused).size)
    #expect(image === KeycapMoodRenderer.image(frame: 2, state: .paused, mood: mood, dark: true, highContrast: true))
    #expect(KeycapMoodRenderer.image(frame: 2, state: .muted, mood: mood, dark: true, highContrast: true).isTemplate)
    #expect(KeycapMoodRenderer.image(frame: 2, state: nil, mood: nil, dark: true, highContrast: false) === KeycapIcon.frames[2])
    // A point outside the keycap remains transparent; drawing must not add a halo.
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
    for point in [NSPoint(x: image.size.width / 2, y: 15), NSPoint(x: image.size.width - 4, y: 9)] {
        let color = bitmap.colorAt(x: Int(point.x * CGFloat(bitmap.pixelsWide) / image.size.width),
                                   y: Int(point.y * CGFloat(bitmap.pixelsHigh) / image.size.height))!
            .usingColorSpace(.sRGB)!
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        #expect(channels.max()! - channels.min()! > 0.01)
    }
}

@Test @MainActor
func inactiveAgentCannotRemainColoredDuringTransition() async throws {
    let mood = MoodCoordinator()
    let claude = MoodActivity(agent: .claude, phase: "writing", intensity: 0.8)
    mood.update([claude], enabled: true, glow: 1, reducedMotion: true)
    #expect(mood.appearance?.agent == .claude)
    mood.update([MoodActivity(agent: .claude, phase: "idle", intensity: 0.8),
                 MoodActivity(agent: .codex, phase: "writing", intensity: 0.8)],
                enabled: true, glow: 1, reducedMotion: false)
    #expect(mood.selection.selected?.agent == .codex)
    #expect(mood.appearance?.agent != .claude)
    try await Task.sleep(for: .milliseconds(450))
    #expect(mood.appearance?.agent == .codex)
    #expect(!mood.isAnimating)
    mood.reset()
}

@Test
func stereoHalfWidthMatchesFormerFullWidthIncludingVariance() {
    for index in 0..<32 {
        let position = 2 * Double(index) / 31 - 1
        for variance in [-0.06, 0, 0.06] {
            let old = Float(max(-0.65, min(0.65, (position + variance) * 0.65)))
            #expect(StereoProfile.pan(kind: .key, sampleIndex: index, sampleCount: 32,
                                      width: 0.5, variation: variance) == old)
        }
    }
    #expect(StereoProfile.pan(kind: .key, sampleIndex: 0, sampleCount: 32, width: 1, variation: 0) == -1)
    #expect(StereoProfile.pan(kind: .key, sampleIndex: 31, sampleCount: 32, width: 1, variation: 0) == 1)
}

@Test @MainActor
func stereoLegacyWidthIsConvertedOnlyOnce() {
    let suite = "im-thinking-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(1.0, forKey: "stereoWidth")
    let model = AppModel(defaults: defaults, startMonitoring: false)
    #expect(model.stereoWidth == 0.5)
    model.setStereoWidth(0.75)
    let restored = AppModel(defaults: defaults, startMonitoring: false)
    #expect(restored.stereoWidth == 0.75)
    #expect(defaults.double(forKey: "stereoWidth") == 1)
}
