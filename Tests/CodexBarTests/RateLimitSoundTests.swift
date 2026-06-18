import AppKit
import Testing
@testable import AgentMeter

@Suite("Rate-limit sound")
struct RateLimitSoundTests {
    @Test
    func firstObservationNeverPlays() {
        let decision = RateLimitSoundLogic.decision(previousUsed: nil, currentUsed: 100)
        #expect(decision.play == false)
        #expect(decision.remembered == 100)
    }

    @Test
    func risingEdgeAcrossThresholdPlaysOnce() {
        let cross = RateLimitSoundLogic.decision(previousUsed: 80, currentUsed: 99)
        #expect(cross.play == true)
        let stay = RateLimitSoundLogic.decision(previousUsed: 99, currentUsed: 100)
        #expect(stay.play == false)
    }

    @Test
    func recoveryThenReCrossPlaysAgain() {
        let recover = RateLimitSoundLogic.decision(previousUsed: 99, currentUsed: 50)
        #expect(recover.play == false)
        let reCross = RateLimitSoundLogic.decision(previousUsed: 50, currentUsed: 99.5)
        #expect(reCross.play == true)
    }

    @Test
    func belowThresholdNeverPlays() {
        #expect(RateLimitSoundLogic.decision(previousUsed: 10, currentUsed: 98.9).play == false)
    }

    @Test
    func volumeClamps() {
        #expect(RateLimitSoundLogic.clampVolume(-1) == 0)
        #expect(RateLimitSoundLogic.clampVolume(2) == 1)
        #expect(RateLimitSoundLogic.clampVolume(0.5) == 0.5)
    }

    @MainActor
    @Test
    func bundledAlertResourceExists() throws {
        let url = try #require(RateLimitSoundPlayer.resourceURL())
        #expect(url.pathExtension == "mp3")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
