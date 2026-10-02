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
    #expect(TypingScheduler.keysPerSecond(intensity: 1, phase: "writing", toolClass: nil) <= 15)
}

@Test
func higherWritingIntensityProducesFasterCadence() {
    let low = TypingScheduler.keysPerSecond(intensity: 0.25, phase: "writing", toolClass: nil)
    let high = TypingScheduler.keysPerSecond(intensity: 0.85, phase: "writing", toolClass: nil)
    #expect(high > low)
}
