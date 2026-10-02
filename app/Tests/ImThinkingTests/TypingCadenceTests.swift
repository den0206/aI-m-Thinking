import XCTest
@testable import ImThinking

final class TypingCadenceTests: XCTestCase {
    func testFiveBuiltInSoundPacksExist() {
        XCTAssertEqual(SoundPackID.allCases.count, 5)
    }

    func testIdleAndNonMutationToolsAreSilent() {
        XCTAssertEqual(
            TypingScheduler.keysPerSecond(
                intensity: 1,
                phase: "idle",
                toolClass: nil
            ),
            0
        )
        XCTAssertEqual(
            TypingScheduler.keysPerSecond(
                intensity: 1,
                phase: "tool",
                toolClass: "shell"
            ),
            0
        )
    }

    func testMaximumRateIsBounded() {
        XCTAssertLessThanOrEqual(
            TypingScheduler.keysPerSecond(
                intensity: 1,
                phase: "writing",
                toolClass: nil
            ),
            15
        )
    }

    func testHigherWritingIntensityProducesFasterCadence() {
        let low = TypingScheduler.keysPerSecond(
            intensity: 0.25,
            phase: "writing",
            toolClass: nil
        )
        let high = TypingScheduler.keysPerSecond(
            intensity: 0.85,
            phase: "writing",
            toolClass: nil
        )
        XCTAssertGreaterThan(high, low)
    }
}
