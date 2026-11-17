import Foundation
import Testing
@testable import CodexBarCore

struct UsagePoolPaceTests {
    private let now = Date(timeIntervalSince1970: 0)

    private func result(used: Double, elapsed: Double, size: Double? = nil) throws -> UsagePoolForecast.Result {
        let account = UsagePoolForecast.Account(
            id: "invented-pace-\(Int(used))", displayName: "Invented pace account",
            weekly: RateWindow(usedPercent: used, windowMinutes: 10080,
                               resetsAt: self.now.addingTimeInterval((1 - elapsed) * 604800), resetDescription: nil),
            isActive: true, calibratedCapacity: size)
        return try UsagePoolForecast.forecast(provider: .codex, accounts: [account], now: self.now,
                                              pace: .init(unitsPerDay: 0, assumption: "Invented idle fixture"))
    }

    @Test func signedDeltaAndSizeWeighting() throws {
        let ahead = try self.result(used: 80, elapsed: 0.5, size: 200)
        let behind = try self.result(used: 20, elapsed: 0.5, size: 100)
        let combined = UsagePoolForecast.pacePosition(results: [ahead, behind], now: self.now)
        #expect(abs(try #require(combined.delta) - 0.1) < 0.000001)
        #expect(combined.driver?.deltaPoints == 30)
        #expect(combined.driver?.capacity == 200)
        #expect(UsagePoolForecast.pacePosition(results: [], now: self.now).delta == nil)
    }

    @Test func unknownClockExcludedRatherThanOnPace() throws {
        let account = UsagePoolForecast.Account(
            id: "invented-unknown-clock", displayName: "Invented unknown clock",
            weekly: .init(usedPercent: 50, windowMinutes: 10080, resetsAt: nil, resetDescription: nil), isActive: true)
        let result = try UsagePoolForecast.forecast(provider: .codex, accounts: [account], now: self.now,
                                                  pace: .init(unitsPerDay: 0, assumption: "Invented idle fixture"))
        let pace = UsagePoolForecast.pacePosition(results: [result], now: self.now)
        #expect(pace.delta == nil)
        #expect(pace.excludedAccountIDs == [account.id])
    }

    @Test func reportedWindowDurationAndPassedTopUp() throws {
        let result = try self.result(used: 50, elapsed: 0.5)
        let afterTopUp = UsagePoolForecast.pacePosition(results: [result], now: self.now.addingTimeInterval(4 * 86400))
        #expect(abs(try #require(afterTopUp.delta) + 0.5 / 7) < 0.000001)
    }
    /// Unreadable logins count from their last reading, marked estimated, whatever forecast scenario is chosen.
    /// Before the recorded top-up they keep the last usage; after it they count as full.
    @Test func unreadableLoginsCountFromTheirLastReading() throws {
        func accounts(unreadableReset: TimeInterval) -> [UsagePoolForecast.Account] {
            [
                .init(id: "invented-readable", displayName: "Invented readable",
                      weekly: .init(usedPercent: 60, windowMinutes: 10080,
                                    resetsAt: self.now.addingTimeInterval(302400), resetDescription: nil), isActive: true),
                .init(id: "invented-unreadable", displayName: "Invented unreadable",
                      weekly: .init(usedPercent: 99, windowMinutes: 10080,
                                    resetsAt: self.now.addingTimeInterval(unreadableReset), resetDescription: nil),
                      measuredAt: self.now.addingTimeInterval(-86400), refusedSince: self.now),
            ]
        }
        for scenario in [UsagePoolForecast.Scenario.dead, .lastReading, .fullAfterPassedTopUp] {
            let result = try UsagePoolForecast.forecast(
                provider: .claude, accounts: accounts(unreadableReset: 302400), now: self.now,
                pace: .init(unitsPerDay: 0, assumption: "Invented idle fixture"),
                scenarios: ["invented-unreadable": scenario])
            let pace = UsagePoolForecast.pacePosition(results: [result], now: self.now)
            #expect(pace.excludedAccountIDs.isEmpty)
            #expect(pace.contributions.first { $0.accountID == "invented-unreadable" }?.estimated == true)
            // Half the week gone: readable is 10 points over, unreadable 49 over; equal sizes average to 29.5.
            #expect(abs(try #require(pace.delta) - 0.295) < 0.000001)
            #expect(pace.driver?.accountID == "invented-unreadable")
        }
        // A top-up that passed after the last reading counts the login as full again.
        let toppedUp = try UsagePoolForecast.forecast(
            provider: .claude, accounts: accounts(unreadableReset: -3600), now: self.now,
            pace: .init(unitsPerDay: 0, assumption: "Invented idle fixture"))
        let pace = UsagePoolForecast.pacePosition(results: [toppedUp], now: self.now)
        let unreadable = try #require(pace.contributions.first { $0.accountID == "invented-unreadable" })
        #expect(abs(unreadable.deltaPoints - (0 - 100 * 3600 / 604800)) < 0.000001)
        // No weekly reading at all is the only exclusion.
        let blank = try UsagePoolForecast.forecast(
            provider: .claude,
            accounts: [accounts(unreadableReset: 302400)[0],
                       .init(id: "invented-blank", displayName: "Invented blank", weekly: nil, refusedSince: self.now)],
            now: self.now, pace: .init(unitsPerDay: 0, assumption: "Invented idle fixture"))
        #expect(UsagePoolForecast.pacePosition(results: [blank], now: self.now).excludedAccountIDs == ["invented-blank"])
    }

}
