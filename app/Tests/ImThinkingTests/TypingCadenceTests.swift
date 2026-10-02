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
    #expect(TypingScheduler.keysPerSecond(intensity: 1, phase: "writing", toolClass: nil) <= 15)
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
