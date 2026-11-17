import Foundation
import Testing
@testable import CodexBarCore

struct UsagePoolForecastTests {
    private let now = Self.date("2026-11-06T09:50:00Z")

    private static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func window(_ used: Double, _ reset: String?, minutes: Int = 10080) -> RateWindow {
        RateWindow(usedPercent: used, windowMinutes: minutes, resetsAt: reset.map(Self.date), resetDescription: nil)
    }

    // Slot labels and all identifiers are plainly invented. No live cache is a fixture.
    private func claudeAccounts() -> [UsagePoolForecast.Account] {
        [
            .init(id: "invented-work-1", displayName: "Work-1",
                  weekly: self.window(65, "2026-11-09T19:00:00Z"),
                  session: self.window(14, "2026-11-06T14:10:00Z", minutes: 300),
                  measuredAt: self.now, isActive: true),
            .init(id: "invented-personal", displayName: "Personal",
                  weekly: self.window(69, "2026-11-11T02:00:00Z"), measuredAt: self.now, isPersonal: true),
            .init(id: "invented-work-2", displayName: "Work-2",
                  weekly: self.window(95, "2026-11-04T22:00:00Z"),
                  measuredAt: Self.date("2026-11-03T09:00:00Z"),
                  refusedSince: Self.date("2026-11-03T09:00:00Z")),
            .init(id: "invented-work-3", displayName: "Work-3",
                  weekly: self.window(95, "2026-11-09T14:00:00Z"),
                  measuredAt: Self.date("2026-11-03T09:00:00Z"),
                  refusedSince: Self.date("2026-11-03T09:00:00Z")),
        ]
    }

    private func credits(_ json: String) throws -> CodexResetCredits {
        try JSONDecoder().decode(CodexResetCredits.self, from: Data(json.utf8))
    }

    private func close(_ actual: Date?, _ expected: String, hours: Double = 0.2) throws {
        #expect(abs(try #require(actual).timeIntervalSince(Self.date(expected))) < hours * 3600)
    }

    // The semaphore bounds even a synchronous engine loop that cannot observe task cancellation.
    private final class TimedForecast: @unchecked Sendable {
        let completed = DispatchSemaphore(value: 0)
        var result: Swift.Result<UsagePoolForecast.Result, Error>?
    }

    private func withinTimeout(
        _ operation: @escaping @Sendable () throws -> UsagePoolForecast.Result) throws -> UsagePoolForecast.Result
    {
        let task = TimedForecast()
        DispatchQueue.global().async {
            task.result = Swift.Result { try operation() }
            task.completed.signal()
        }
        try #require(task.completed.wait(timeout: .now() + 3) == .success)
        return try #require(task.result).get()
    }

    @Test func morningClaudeRunwayAndSeparateScenarios() throws {
        let pace = try UsagePoolForecast.Pace(
            unitsPerDay: 17 * 3, assumption: "17 points/day per work-equivalent, three work logins = 51 total")
        let accounts = self.claudeAccounts()
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: accounts, now: self.now, pace: pace)
        try self.close(result.ownRunwayUntil, "2026-11-07T17:00:00Z")
        #expect(result.assumptions.scenarios["invented-work-2"] == .fullAfterPassedTopUp)
        #expect(result.assumptions.scenarios["invented-work-3"] == .dead)
        #expect(result.assumptions.sizeLabel == "size estimated")
        #expect(result.comingUp.contains { $0.kind == .switchAccount && $0.accountID == "invented-work-2" })
        #expect(result.comingUp.map(\.at) == result.comingUp.map(\.at).sorted())
        // The maths' default dead scenario for Work-3 cannot also promise its Monday capacity.
        try self.close(result.actingRunwayUntil, "2026-11-09T16:00:00Z")
        let confirmedAfterTopUp = try UsagePoolForecast.forecast(
            provider: .claude, accounts: accounts, now: self.now, pace: pace,
            scenarios: ["invented-work-3": .lastReading], continuationDays: 7)
        #expect(confirmedAfterTopUp.actingRunwayUntil == nil)
        let dead = try UsagePoolForecast.forecast(
            provider: .claude, accounts: accounts, now: self.now, pace: pace,
            scenarios: ["invented-work-2": .dead], continuationDays: 7)
        #expect(dead.actingRunwayUntil == result.ownRunwayUntil)
        let last = try UsagePoolForecast.forecast(
            provider: .claude, accounts: accounts, now: self.now, pace: pace,
            scenarios: ["invented-work-2": .lastReading], continuationDays: 7)
        #expect(try #require(last.actingRunwayUntil) > #require(dead.actingRunwayUntil))
        #expect(try #require(last.actingRunwayUntil) < #require(result.actingRunwayUntil))
    }

    @Test func morningCodexRedemptionPlanReanchorsWeeklyClock() throws {
        let credits = try self.credits("""
        {"available_count":3,"credits":[
          {"id":"invented-reset-one","status":"available","expires_at":"2026-11-06T23:21:00Z"},
          {"id":"invented-reset-two","status":"available","expires_at":"2026-11-30T19:54:00Z"},
          {"id":"invented-reset-three","status":"available","expires_at":"2026-12-01T22:28:00Z"}
        ]}
        """)
        let snapshot = UsageSnapshot(
            primary: nil, secondary: self.window(33, "2026-11-12T09:18:00Z"),
            codexResetCredits: credits, updatedAt: self.now)
        let account = try UsagePoolForecast.codexAccount(snapshot: snapshot)
        let result = try UsagePoolForecast.forecast(
            provider: .codex, accounts: [account], now: self.now,
            pace: .init(unitsPerDay: 32, assumption: "32 points/day"), credits: snapshot.codexResetCredits)
        try self.close(result.ownRunwayUntil, "2026-11-08T12:00:00Z")
        #expect(result.redemptions.count == 3)
        try self.close(result.redemptions.first?.at, "2026-11-06T23:16:00Z", hours: 0.001)
        try self.close(result.redemptions.dropFirst().first?.at, "2026-11-10T02:16:00Z", hours: 0.001)
        try self.close(result.redemptions.last?.at, "2026-11-13T05:16:00Z", hours: 0.001)
        #expect(abs(try #require(result.redemptions.first).valuePercent - 50.91) < 0.02)
        #expect(result.redemptions.dropFirst().allSatisfy { abs($0.valuePercent - 100) < 0.001 })
        #expect(abs(try #require(result.redemptions.first?.paceToUseBeforeExpiry) - 4.96) < 0.05)
        try self.close(result.actingRunwayUntil, "2026-11-16T08:16:00Z", hours: 0.001)
        #expect(!result.comingUp.contains { $0.kind == .topUp && $0.at == Self.date("2026-11-12T09:18:00Z") })
        #expect(result.accounts.first?.session == nil)
    }

    @Test func calibrationRequiresThreeSoloStretchesAndRejectsTopUps() {
        typealias Stretch = UsagePoolForecast.SoloStretch
        let valid: [Stretch] = [.init(spend: 20, usedPoints: 10), .init(spend: 90, usedPoints: 30),
                                .init(spend: 40, usedPoints: 10)]
        #expect(UsagePoolForecast.calibratedCapacity(stretches: Array(valid.prefix(2))) == nil)
        #expect(UsagePoolForecast.calibratedCapacity(stretches: valid) == 300)
        #expect(UsagePoolForecast.calibratedCapacity(stretches: valid + [.init(spend: 25, usedPoints: 10)]) == 275)
        #expect(UsagePoolForecast.calibratedCapacity(stretches: valid + [
            .init(spend: 999, usedPoints: 9), .init(spend: 999, usedPoints: 20, includesTopUp: true),
            .init(spend: .nan, usedPoints: 20), .init(spend: 999, usedPoints: 20, isSolo: false),
        ]) == 300)
    }

    @Test func noSessionWindowAndAllRefusedAreNotInventedCapacity() throws {
        let account = UsagePoolForecast.Account(
            id: "invented-only", displayName: "Work-1", weekly: self.window(50, nil),
            measuredAt: self.now, refusedSince: self.now, isActive: true)
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [account], now: self.now,
            pace: .init(unitsPerDay: 24, assumption: "one point/hour"), continuationDays: 7)
        #expect(result.ownRunwayUntil == self.now)
        #expect(result.actingRunwayUntil == self.now)
        #expect(result.accounts.first?.session == nil)
        #expect(result.comingUp.isEmpty)
        #expect(result.unmetDemand == 168)
    }

    @Test func reportedSessionLimitsOnlyItsLoginAndDoesNotRecur() throws {
        let account = UsagePoolForecast.Account(
            id: "invented-session", displayName: "Work-1", weekly: self.window(0, nil),
            session: self.window(99, "2026-11-06T12:50:00Z", minutes: 300), isActive: true)
        let personal = UsagePoolForecast.Account(
            id: "invented-overflow", displayName: "Personal", weekly: self.window(99, nil), isPersonal: true)
        let pace = try UsagePoolForecast.Pace(unitsPerDay: 24, assumption: "one point/hour")
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [account, personal], now: self.now, pace: pace, continuationDays: 7)
        #expect(result.ownRunwayUntil == self.now.addingTimeInterval(101 * 3600))
        #expect(result.unmetDemand == 67)
        #expect(!result.comingUp.contains { $0.kind == .topUp })
    }

    @Test func topUpsDiscardRemainderAndRecurWeekly() throws {
        let account = UsagePoolForecast.Account(
            id: "invented-top-up", displayName: "Work-1", weekly: self.window(20, "2026-11-06T10:50:00Z"),
            isActive: true)
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [account], now: self.now,
            pace: .init(unitsPerDay: 0, assumption: "idle"))
        #expect(result.wasteByAccount[account.id] == 80)
        #expect(result.comingUp.first?.unusedPercent == 80)
        #expect(result.comingUp.first?.wording == "Work-1 tops up")
        #expect(result.ownRunwayUntil == nil)
        #expect(result.actingRunwayUntil == nil)
    }

    @Test func creditWithoutExpiryWaitsForEmptyAndZeroUsedDoesNothing() throws {
        let credits = try self.credits(#"{"available_count":1,"credits":[{"id":"invented-no-expiry","status":"available"}]}"#)
        let account = UsagePoolForecast.Account(
            id: "codex", displayName: "Codex", weekly: self.window(0, nil), isActive: true)
        let result = try UsagePoolForecast.forecast(
            provider: .codex, accounts: [account], now: self.now,
            pace: .init(unitsPerDay: 100, assumption: "100 points/day"), credits: credits, continuationDays: 7)
        #expect(result.redemptions.count == 1)
        #expect(result.redemptions.first?.at == self.now.addingTimeInterval(86400))
        #expect(result.redemptions.first?.valuePercent == 100)
        #expect(result.redemptions.first?.paceToUseBeforeExpiry == nil)
        let expiring = try self.credits("""
        {"credits":[{"id":"invented-zero","status":"available","expires_at":"2026-11-06T10:00:00Z"}]}
        """)
        let idle = try UsagePoolForecast.forecast(
            provider: .codex, accounts: [account], now: self.now,
            pace: .init(unitsPerDay: 0, assumption: "idle"), credits: expiring, continuationDays: 7)
        #expect(idle.redemptions.isEmpty)
        #expect(idle.wasteByAccount["codex"] == 100)
        #expect(idle.comingUp.first?.kind == .creditExpiry)
    }

    @Test func cacheParsingSanitizesLabelsAndPreservesReports() throws {
        let usage = Data("""
        {"schemaVersion":1,"accounts":{
          "1":{"fetchedAt":1793958600,"lastAttemptAt":1793958600,"lastError":"http-403", "lastGood":{
            "fetchedAt":1793696400,
            "seven_day":{"pct":95,"resets_at":"2026-11-04T22:00:00Z"},
            "scoped":[{"name":"Invented model","pct":8}]}},
          "2":{"fetchedAt":1793958600,"lastGood":{"seven_day":{"pct":69}}},
          "3":{"lastError":"http-403"}
        }}
        """.utf8)
        let sequence = Data("""
        {"activeAccountNumber":1,"accounts":{
          "1":{"email":"invented-work@example.invalid","alias":"Invented alias"},
          "2":{"email":"invented-personal@example.invalid"},
          "3":{"email":"invented-other@example.invalid","alias":"invented-other@example.invalid"}
        }}
        """.utf8)
        let umbrella = Data(#"{"personal":"invented-personal@example.invalid"}"#.utf8)
        let accounts = try UsagePoolClaudeCache.accounts(usage: usage, sequence: sequence, umbrella: umbrella, now: self.now)
        #expect(accounts.map(\.displayName) == ["Invented alias", "Personal", "Work-2"])
        #expect(accounts[0].isActive)
        #expect(accounts[1].isPersonal)
        #expect(accounts[1].session == nil)
        #expect(accounts[0].scoped.first?.window.usedPercent == 8)
        #expect(UsagePoolForecast.defaultScenario(for: accounts[0], now: self.now) == .fullAfterPassedTopUp)
        #expect(UsagePoolForecast.defaultScenario(for: accounts[2], now: self.now) == .dead)
        #expect(!String(describing: accounts).contains("@"))
        #expect(throws: UsagePoolClaudeCache.CacheError.self) {
            try UsagePoolClaudeCache.accounts(usage: Data(), sequence: sequence, umbrella: umbrella, now: self.now)
        }
        let noncanonicalSlot = Data(#"{"accounts":{"01":{}}}"#.utf8)
        #expect(throws: UsagePoolClaudeCache.CacheError.self) {
            try UsagePoolClaudeCache.accounts(
                usage: usage, sequence: noncanonicalSlot, umbrella: umbrella, now: self.now)
        }
        let malformedReading = Data(#"{"schemaVersion":1,"accounts":{"1":42,"2":{"lastGood":{"seven_day":{"pct":0}}}}}"#.utf8)
        let unreadable = try UsagePoolClaudeCache.accounts(
            usage: malformedReading, sequence: sequence, umbrella: umbrella, now: self.now)
        #expect(unreadable.allSatisfy { UsagePoolForecast.defaultScenario(for: $0, now: self.now) == .dead })
    }

    @Test func localDailyHistoryUsesMeasuredConversionAndRequiresCompleteDays() throws {
        let entries = (1...28).map { days -> CostUsageDailyReport.Entry in
            let date = self.now.addingTimeInterval(-Double(days) * 86400)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return .init(date: formatter.string(from: date), inputTokens: nil, outputTokens: nil,
                         totalTokens: 2400, costUSD: 48, modelsUsed: nil, modelBreakdowns: nil)
        }
        let claude = try #require(try UsagePoolForecast.Pace.localHistory(
            entries, provider: .claude, now: self.now, capacityUnitsPerRawUnit: 1))
        #expect(claude.weekdayRates == Array(repeating: 2, count: 7))
        let codex = try #require(try UsagePoolForecast.Pace.localHistory(
            entries, provider: .codex, now: self.now, capacityUnitsPerRawUnit: 0.01))
        #expect(codex.weekdayRates == Array(repeating: 1, count: 7))
        #expect(try UsagePoolForecast.Pace.localHistory(
            Array(entries.dropLast()), provider: .codex, now: self.now, capacityUnitsPerRawUnit: 1) == nil)
        let fallback = try UsagePoolForecast.Pace.windowAverage(accounts: self.claudeAccounts(), now: self.now)
        #expect(abs(fallback.meanPerHour - 65 / (168 - 81.1666667)) < 0.0001)
    }

    @Test func historicalUtilisationNeverSubstitutesForecastWaste() throws {
        let account = UsagePoolForecast.Account(
            id: "invented-history", displayName: "Work-1", weekly: self.window(50, nil), isActive: true)
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [account], now: self.now,
            pace: .init(unitsPerDay: 1, assumption: "one point/day"),
            history: .init(demand: 200, waste: 50), continuationDays: 7)
        #expect(result.utilisation?.wasteBased == 0.8)
        #expect(result.utilisation?.pressureBased == 0.5)
        let unknownWaste = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [account], now: self.now,
            pace: .init(unitsPerDay: 1, assumption: "one point/day"),
            history: .init(demand: 200, waste: nil), continuationDays: 7)
        #expect(unknownWaste.utilisation?.wasteBased == nil)
    }

    @Test func lexicographicPolicyAvoidsUnnecessarySwitchButBurnsDiscardRisk() throws {
        let current = UsagePoolForecast.Account(
            id: "invented-current", displayName: "Work-1", weekly: self.window(0, nil), isActive: true)
        let spare = UsagePoolForecast.Account(
            id: "invented-spare", displayName: "Work-2", weekly: self.window(90, "2026-11-06T19:50:00Z"))
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [current, spare], now: self.now,
            pace: .init(unitsPerDay: 24, assumption: "one point/hour"), continuationDays: 7)
        #expect(result.wasteByAccount[spare.id] == 0)
        #expect(result.comingUp.first?.kind == .switchAccount)
        #expect(result.comingUp.first?.accountID == spare.id)
        let expensive = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [current, spare], now: self.now,
            pace: .init(unitsPerDay: 1, assumption: "one point/day"), kappa: 1000, continuationDays: 7)
        #expect(!expensive.comingUp.contains { $0.kind == .switchAccount })
        #expect(expensive.actingRunwayUntil == nil)
    }

    @Test func latestSwitchDeadlineAvoidsAnExtraManualAction() throws {
        let current = UsagePoolForecast.Account(
            id: "invented-deadline-current", displayName: "Work-1", weekly: self.window(90, nil), isActive: true)
        let spare = UsagePoolForecast.Account(
            id: "invented-deadline-spare", displayName: "Work-2",
            weekly: self.window(95, "2026-11-06T19:50:00Z"))
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [current, spare], now: self.now,
            pace: .init(unitsPerDay: 24, assumption: "one point/hour"), continuationDays: 7)
        #expect(result.comingUp.filter { $0.kind == .switchAccount }.count == 2)
        #expect(result.wasteByAccount[spare.id] == 0)
        try self.close(result.comingUp.first?.at, "2026-11-06T14:50:00Z", hours: 0.001)
    }

    @Test func recurringTopUpsMaintainCoverageAcrossContinuation() throws {
        let account = UsagePoolForecast.Account(
            id: "invented-recurring", displayName: "Work-1",
            weekly: self.window(20, "2026-11-06T10:50:00Z"), isActive: true)
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [account], now: self.now,
            pace: .init(unitsPerDay: 14, assumption: "98 points/week"))
        #expect(result.ownRunwayUntil == nil)
        #expect(result.actingRunwayUntil == nil)
        #expect(result.evaluatedUntil == self.now.addingTimeInterval(28 * 86400))
        #expect(abs(try #require(result.wasteByAccount[account.id]) - (80 - 14.0 / 24)) < 0.0001)
    }

    @Test func oldRefusalsAndUnknownCreditDetailsStayExplicit() throws {
        let old = UsagePoolForecast.Account(
            id: "invented-old-refusal", displayName: "Work-1",
            weekly: self.window(95, "2026-11-04T22:00:00Z"),
            measuredAt: Self.date("2026-10-29T09:00:00Z"),
            refusedSince: Self.date("2026-10-29T09:00:00Z"), isActive: true)
        #expect(UsagePoolForecast.defaultScenario(for: old, now: self.now) == .dead)
        let countOnly = try self.credits(#"{"available_count":3}"#)
        let codex = UsagePoolForecast.Account(
            id: "codex", displayName: "Codex", weekly: self.window(50, nil), isActive: true)
        let result = try UsagePoolForecast.forecast(
            provider: .codex, accounts: [codex], now: self.now,
            pace: .init(unitsPerDay: 24, assumption: "one point/hour"), credits: countOnly, continuationDays: 7)
        #expect(result.unplannedCreditCount == 3)
        #expect(result.redemptions.isEmpty)
        #expect(result.actingRunwayUntil == result.ownRunwayUntil)
        #expect(throws: UsagePoolForecast.ForecastError.self) {
            try UsagePoolForecast.Pace(unitsPerDay: .nan, assumption: "invalid invented input")
        }
    }

    @Test func weekdayPaceChangesAreEventsAndUnmetDemandPrecedesManualCost() throws {
        // Friday is idle, Saturday has one point/hour, all other days are idle.
        let pace = try UsagePoolForecast.Pace(
            weekdayRates: [0, 0, 0, 0, 0, 0, 1], assumption: "invented Saturday-only workload")
        let current = UsagePoolForecast.Account(
            id: "invented-weekday-current", displayName: "Work-1", weekly: self.window(99, nil), isActive: true)
        let spare = UsagePoolForecast.Account(
            id: "invented-weekday-spare", displayName: "Work-2", weekly: self.window(0, nil))
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [current, spare], now: self.now, pace: pace,
            credits: self.credits(#"{"available_count":3}"#), kappa: 1000, continuationDays: 7)
        try self.close(result.ownRunwayUntil, "2026-11-07T01:00:00Z", hours: 0.001)
        #expect(result.actingRunwayUntil == nil)
        #expect(result.unmetDemand == 0)
        #expect(result.comingUp.contains { $0.kind == .switchAccount })
        #expect(result.unplannedCreditCount == 0)
        #expect(result.redemptions.isEmpty)
    }

    @Test func personalIsOverflowUntilManuallySelectedWithAnEvent() throws {
        let work = UsagePoolForecast.Account(
            id: "invented-work", displayName: "Work-1",
            weekly: self.window(40, "2026-11-10T13:50:00Z"), isActive: true)
        let personal = UsagePoolForecast.Account(
            id: "invented-personal", displayName: "Personal",
            weekly: self.window(70, "2026-11-06T12:50:00Z"), isPersonal: true)
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [work, personal], now: self.now,
            pace: .init(unitsPerDay: 240, assumption: "invented ten points/hour"), continuationDays: 7)
        #expect(result.ownRunwayUntil == self.now.addingTimeInterval(16 * 3600))
        #expect(result.actingRunwayUntil == self.now.addingTimeInterval(19 * 3600))
        let switches = result.comingUp.filter { $0.kind == .switchAccount }
        #expect(switches.count == 1)
        #expect(switches.first?.accountID == personal.id)
        #expect(switches.first?.at == self.now)
        // With no unmet demand either way, personal's manual action must participate in the cost.
        let fullWork = UsagePoolForecast.Account(
            id: "invented-full-work", displayName: "Work-1", weekly: self.window(0, nil), isActive: true)
        let automatic = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [fullWork, personal], now: self.now,
            pace: .init(unitsPerDay: 24, assumption: "invented one point/hour"), kappa: 1000, continuationDays: 7)
        #expect(automatic.actingRunwayUntil == nil)
        #expect(automatic.wasteByAccount[personal.id] == 30)
        #expect(!automatic.comingUp.contains { $0.kind == .switchAccount })
        let freeAction = try UsagePoolForecast.forecast(
            provider: .claude, accounts: [fullWork, personal], now: self.now,
            pace: .init(unitsPerDay: 24, assumption: "invented one point/hour"), kappa: 0, continuationDays: 7)
        #expect(freeAction.actingRunwayUntil == nil)
        #expect(try #require(freeAction.wasteByAccount[personal.id]) < 30)
        #expect(freeAction.comingUp.contains { $0.kind == .switchAccount && $0.accountID == personal.id })
    }

    @Test func overflowReturnsToWorkAtWeeklyTopUpOrReportedSessionEnd() throws {
        let personal = UsagePoolForecast.Account(
            id: "invented-personal", displayName: "Personal",
            weekly: self.window(0, "2026-11-06T13:50:00Z"), isPersonal: true)
        for sessionBlocked in [false, true] {
            let work = UsagePoolForecast.Account(
                id: "invented-work", displayName: "Work-1",
                weekly: self.window(sessionBlocked ? 0 : 100, sessionBlocked ? nil : "2026-11-06T11:50:00Z"),
                session: sessionBlocked ? self.window(100, "2026-11-06T11:50:00Z", minutes: 300) : nil,
                isActive: true)
            let result = try UsagePoolForecast.forecast(
                provider: .claude, accounts: [work, personal], now: self.now,
                pace: .init(unitsPerDay: 240, assumption: "invented ten points/hour"), continuationDays: 7)
            #expect(result.ownRunwayUntil == self.now.addingTimeInterval(22 * 3600))
        }
    }

    @Test func sessionPercentNeverBecomesWeeklyUnitsAndMissingResetIsDropped() throws {
        for percent in [0.0, 99, 100] {
            let work = UsagePoolForecast.Account(
                id: "invented-work", displayName: "Work-1", weekly: self.window(50, nil),
                session: self.window(percent, nil, minutes: 300), isActive: true, calibratedCapacity: 200)
            #expect(work.session == nil)
            let result = try UsagePoolForecast.forecast(
                provider: .claude, accounts: [work], now: self.now,
                pace: .init(unitsPerDay: 24, assumption: "invented one point/hour"), continuationDays: 7)
            #expect(result.ownRunwayUntil == self.now.addingTimeInterval(100 * 3600))
        }
    }

    @Test func overflowCacheRestoresChosenWorkWithoutExportingEmails() throws {
        let usage = Data("""
        {"schemaVersion":1,"accounts":{
          "1":{"fetchedAt":\(self.now.timeIntervalSince1970),"lastGood":{
            "seven_day":{"pct":100,"resets_at":"2026-11-06T11:50:00Z"}}},
          "2":{"fetchedAt":\(self.now.timeIntervalSince1970),"lastGood":{
            "seven_day":{"pct":0,"resets_at":"2026-11-06T13:50:00Z"}}}
        }}
        """.utf8)
        let sequence = Data("""
        {"activeAccountNumber":2,"accounts":{
          "1":{"email":"invented-work@example.invalid"},
          "2":{"email":"invented-personal@example.invalid"}}}
        """.utf8)
        let umbrella = Data(#"{"personal":"invented-personal@example.invalid"}"#.utf8)
        let state = Data(#"{"chosen_work":["invented-work@example.invalid","invented-org"]}"#.utf8)
        let accounts = try UsagePoolClaudeCache.accounts(
            usage: usage, sequence: sequence, umbrella: umbrella, umbrellaState: state, now: self.now)
        #expect(accounts[0].isActive)
        #expect(!accounts[1].isActive)
        #expect(accounts[1].isPersonal)
        #expect(!String(describing: accounts).contains("@"))
        // The signed-in login is reported separately from the forecast's planning login.
        #expect(accounts.map(\.isCurrentLogin) == [false, true])
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: accounts, now: self.now,
            pace: .init(unitsPerDay: 240, assumption: "invented ten points/hour"), continuationDays: 7)
        #expect(result.ownRunwayUntil == self.now.addingTimeInterval(22 * 3600))
        let workActive = Data("""
        {"activeAccountNumber":1,"accounts":{"1":{"email":"invented-work@example.invalid"},
          "2":{"email":"invented-personal@example.invalid"}}}
        """.utf8)
        let staleState = Data(#"{"chosen_work":["invented-other@example.invalid","invented-org"]}"#.utf8)
        let explicit = try UsagePoolClaudeCache.accounts(
            usage: usage, sequence: workActive, umbrella: umbrella, umbrellaState: staleState, now: self.now)
        #expect(explicit[0].isActive)
        #expect(explicit.map(\.isCurrentLogin) == [true, false])
        let unknown = try UsagePoolClaudeCache.accounts(
            usage: usage, sequence: sequence, umbrella: umbrella, umbrellaState: staleState, now: self.now)
        #expect(!unknown.contains { $0.isActive })
    }

    @Test func schemaTwoRetainsLastSuccessAfterRefusalAndRejectsUnknownVersions() throws {
        let usage = Data("""
        {"schemaVersion":2,"accounts":{
          "1":{"fetchedAt":1793958600,"lastAttemptAt":1793962200,"lastError":"http-403",
            "lastGood":{"seven_day":{"pct":65,"resets_at":"2026-11-09T19:00:00Z"}}},
          "2":{"fetchedAt":1793958600,"lastGood":{"seven_day":{"pct":20,"resets_at":"2026-11-10T21:00:00Z"}}}
        }}
        """.utf8)
        let sequence = Data(#"{"activeAccountNumber":2,"accounts":{"1":{},"2":{}}}"#.utf8)
        let accounts = try UsagePoolClaudeCache.accounts(
            usage: usage, sequence: sequence, umbrella: Data("{}".utf8), now: self.now)
        #expect(accounts.count == 2)
        #expect(accounts[0].measuredAt == Date(timeIntervalSince1970: 1793958600))
        #expect(accounts[0].refusedSince == Date(timeIntervalSince1970: 1793962200))
        #expect(accounts[0].weekly?.usedPercent == 65)
        #expect(accounts[1].refusedSince == nil)
        #expect(accounts[1].isActive)
        #expect(try UsagePoolForecast.forecast(provider: .claude, accounts: accounts, now: self.now).accounts.count == 2)
        let future = Data(String(decoding: usage, as: UTF8.self).replacingOccurrences(
            of: "schemaVersion\":2", with: "schemaVersion\":99").utf8)
        #expect(throws: UsagePoolClaudeCache.CacheError.self) {
            try UsagePoolClaudeCache.accounts(
                usage: future, sequence: sequence, umbrella: Data("{}".utf8), now: self.now)
        }
    }

    @Test func cacheSeparatesGoodReadingAndRefusalTimestamps() throws {
        let fetched = self.now.timeIntervalSince1970
        let good = fetched - 2 * 86400
        let attempted = fetched - 3600
        let usage = Data("""
        {"schemaVersion":1,"accounts":{
          "1":{"fetchedAt":\(fetched),"lastAttemptAt":\(attempted),"lastError":"http-403",
            "last429At":\(fetched),"nextPollAt":\(fetched + 3600),"lastGood":{"fetchedAt":\(good),
              "seven_day":{"pct":95,"resets_at":"2026-11-05T09:50:00Z"}}},
          "2":{"fetchedAt":\(fetched),"lastAttemptAt":\(attempted),"lastError":"http-403",
            "lastGood":{"seven_day":{"pct":95,"resets_at":"2026-11-05T09:50:00Z"}}},
          "3":{"fetchedAt":\(fetched),"lastGood":{"seven_day":{"pct":95}}},
          "4":{"fetchedAt":\(fetched),"lastAttemptAt":\(fetched - 8 * 86400),"lastError":"http-403",
            "lastGood":{"fetchedAt":\(good),"seven_day":{"pct":95,"resets_at":"2026-11-05T09:50:00Z"}}},
          "5":{"fetchedAt":\(fetched),"lastGood":{"fetchedAt":\(good),"seven_day":{"pct":95}}}
        }}
        """.utf8)
        let sequence = Data(#"{"accounts":{"1":{},"2":{},"3":{},"4":{},"5":{}}}"#.utf8)
        let accounts = try UsagePoolClaudeCache.accounts(
            usage: usage, sequence: sequence, umbrella: Data("{}".utf8), now: self.now)
        #expect(accounts[0].measuredAt == Date(timeIntervalSince1970: good))
        #expect(accounts[0].refusedSince == Date(timeIntervalSince1970: attempted))
        #expect(UsagePoolForecast.defaultScenario(for: accounts[0], now: self.now) == .fullAfterPassedTopUp)
        #expect(accounts[1].measuredAt == nil)
        #expect(UsagePoolForecast.defaultScenario(for: accounts[1], now: self.now) == .dead)
        #expect(accounts[2].measuredAt == self.now)
        #expect(accounts[2].refusedSince == nil)
        #expect(UsagePoolForecast.defaultScenario(for: accounts[3], now: self.now) == .dead)
        #expect(accounts[4].measuredAt == Date(timeIntervalSince1970: good))
    }

    @Test func deadCodexWithExpiringCreditsTerminatesWithinTimeout() throws {
        let credits = try self.credits("""
        {"credits":[{"id":"invented-expiring","status":"available","expires_at":"2026-11-06T10:50:00Z"}]}
        """)
        for missingWeekly in [false, true] {
            let account = UsagePoolForecast.Account(
                id: "codex", displayName: "Codex", weekly: missingWeekly ? nil : self.window(50, nil),
                refusedSince: missingWeekly ? nil : self.now, isActive: true)
            let result = try self.withinTimeout {
                try UsagePoolForecast.forecast(
                    provider: .codex, accounts: [account], now: self.now,
                    pace: .init(unitsPerDay: 24, assumption: "invented one point/hour"),
                    credits: credits, continuationDays: 7)
            }
            #expect(result.actingRunwayUntil == self.now)
            #expect(result.redemptions.isEmpty)
            #expect(result.comingUp.isEmpty)
        }
    }

    @Test func flatPaceDeadlineMatchesExactDemandAcrossDays() throws {
        let pace = try UsagePoolForecast.Pace(unitsPerDay: 24, assumption: "Invented flat demand")
        let end = self.now.addingTimeInterval(3 * 86400)
        #expect(pace.latestStart(consuming: 30, before: end, after: self.now) == end.addingTimeInterval(-30 * 3600))
        #expect(pace.latestStart(consuming: 72, before: end, after: self.now) == self.now)
        #expect(pace.latestStart(consuming: 73, before: end, after: self.now) == nil)
        #expect(pace.latestStart(consuming: 0, before: end, after: self.now) == nil)
        #expect(pace.rate(at: end) == 1)
        #expect(pace.nextChange(after: self.now) == .distantFuture)
        let idle = try UsagePoolForecast.Pace(unitsPerDay: 0, assumption: "Invented idle demand")
        #expect(idle.latestStart(consuming: 1, before: end, after: self.now) == nil)
    }

    @Test func sixAccountSearchCompletesWithinTimeout() throws {
        let accounts = (0..<6).map { (index: Int) -> UsagePoolForecast.Account in
            let reset = self.now.addingTimeInterval(Double(index + 1) * 43200)
            let weekly = RateWindow(
                usedPercent: Double(index * 13), windowMinutes: 10080, resetsAt: reset, resetDescription: nil)
            return UsagePoolForecast.Account(
                id: "invented-slot-\(index)", displayName: "Invented slot \(index)",
                weekly: weekly,
                isActive: index == 0, isPersonal: index == 5)
        }
        let result = try self.withinTimeout {
            try UsagePoolForecast.forecast(
                provider: .claude, accounts: accounts, now: self.now,
                pace: .init(unitsPerDay: 100, assumption: "invented 100 points/day"))
        }
        #expect(result.evaluatedUntil == self.now.addingTimeInterval(28 * 86400))
        #expect(result.unmetDemand.isFinite)
        #expect((0...700).contains(result.unmetDemand))
        #expect(!result.comingUp.isEmpty)
    }

    @Test func codexKeepsNaturalTopUpWithinAnHour() throws {
        let credits = try self.credits("""
        {"credits":[{"id":"invented-expiring","status":"available","expires_at":"2026-11-06T10:10:00Z"}]}
        """)
        for seconds in [1800.0, 3600, 3601] {
            let account = UsagePoolForecast.Account(
                id: "codex", displayName: "Codex",
                weekly: RateWindow(usedPercent: 100, windowMinutes: 10080,
                                   resetsAt: self.now.addingTimeInterval(seconds), resetDescription: nil), isActive: true)
            let result = try UsagePoolForecast.forecast(
                provider: .codex, accounts: [account], now: self.now,
                pace: .init(unitsPerDay: 24, assumption: "invented one point/hour"), credits: credits, continuationDays: 7)
            if seconds <= 3600 {
                #expect(result.redemptions.isEmpty)
                #expect(result.comingUp.contains { $0.kind == .topUp && $0.at == self.now.addingTimeInterval(seconds) })
            } else {
                #expect(result.redemptions.first?.at == self.now)
            }
        }
    }

    @Test func fallbackPaceSkipsWindowsYoungerThanSixHours() throws {
        func account(_ hours: Double, active: Bool) -> UsagePoolForecast.Account {
            .init(id: "invented-\(hours)", displayName: "Invented window",
                  weekly: RateWindow(usedPercent: 50, windowMinutes: 10080,
                                     resetsAt: self.now.addingTimeInterval((168 - hours) * 3600), resetDescription: nil),
                  isActive: active)
        }
        let young = account(5.999, active: true)
        #expect(throws: UsagePoolForecast.ForecastError.self) {
            try UsagePoolForecast.Pace.windowAverage(accounts: [young], now: self.now)
        }
        let mature = account(6, active: false)
        let pace = try UsagePoolForecast.Pace.windowAverage(accounts: [young, mature], now: self.now)
        #expect(abs(pace.meanPerHour - 50.0 / 6) < 0.000001)
    }

    @Test func youngWindowKeepsKnownEventsWithoutPaceAndRejectsInvalidInput() throws {
        let credits = try self.credits("""
        {"available_count":2,"credits":[{"id":"invented-young-reset","status":"available","expires_at":"2026-11-06T23:21:00Z"}]}
        """)
        // Use an eight-day window so a hard-coded seven-day age would incorrectly infer pace.
        let account = UsagePoolForecast.Account(id: "codex", displayName: "Codex",
            weekly: RateWindow(usedPercent: 2, windowMinutes: 11520,
                resetsAt: self.now.addingTimeInterval(192 * 3600 - 60), resetDescription: nil), isActive: true)
        let result = try UsagePoolForecast.forecast(provider: .codex, accounts: [account], now: self.now, credits: credits)
        #expect(result.assumptions.pace == nil)
        #expect(result.redemptions.isEmpty)
        #expect(result.comingUp.count == 1)
        #expect(result.comingUp.first?.kind == .creditExpiry)
        #expect(result.comingUp.first?.creditID == "invented-young-reset")
        #expect(result.unplannedCreditCount == 1)
        #expect(UsagePoolForecast.pacePosition(results: [result], now: self.now).delta == nil)
        #expect(throws: UsagePoolForecast.ForecastError.invalidInput) {
            try UsagePoolForecast.forecast(provider: .codex, accounts: [account], now: self.now, kappa: .nan)
        }
        let weekly = UsagePoolForecast.Account(id: "codex", displayName: "Codex",
            weekly: self.window(2, "2026-11-13T09:49:00Z"), isActive: true)
        let standard = try UsagePoolForecast.forecast(provider: .codex, accounts: [weekly], now: self.now, credits: credits)
        #expect(standard.assumptions.pace == nil)
        #expect(standard.comingUp.map(\.kind) == [.creditExpiry, .topUp])
    }

    @Test func expiredCreditsAreKnownRatherThanUnplanned() throws {
        let credits = try self.credits("""
        {"available_count":3,"credits":[
          {"id":"invented-expired","status":"available","expires_at":"2026-11-06T09:50:00Z"},
          {"id":"invented-usable","status":"available"}]}
        """)
        let account = UsagePoolForecast.Account(
            id: "codex", displayName: "Codex", weekly: self.window(100, nil), isActive: true)
        let result = try UsagePoolForecast.forecast(
            provider: .codex, accounts: [account], now: self.now,
            pace: .init(unitsPerDay: 24, assumption: "invented one point/hour"), credits: credits, continuationDays: 7)
        #expect(result.unplannedCreditCount == 1)
        #expect(result.redemptions.map(\.creditID) == ["invented-usable"])
    }

    @Test func simultaneousTopUpAndRunOutHasNoGapOrRedemption() throws {
        let account = UsagePoolForecast.Account(
            id: "codex", displayName: "Codex", weekly: self.window(90, "2026-11-06T10:50:00Z"), isActive: true)
        let credits = try self.credits("""
        {"credits":[{"id":"invented-boundary","status":"available","expires_at":"2026-11-06T10:55:00Z"}]}
        """)
        let result = try UsagePoolForecast.forecast(
            provider: .codex, accounts: [account], now: self.now,
            pace: .init(unitsPerDay: 240, assumption: "invented ten points/hour"), credits: credits, continuationDays: 7)
        #expect(result.ownRunwayUntil == self.now.addingTimeInterval(11 * 3600))
        #expect(result.actingRunwayUntil == result.ownRunwayUntil)
        #expect(result.comingUp.first?.kind == .topUp)
        #expect(result.comingUp.first?.unusedPercent == 0)
        #expect(result.redemptions.isEmpty)
    }

    @Test func creditCanExpireDuringSessionBlockedRunOut() throws {
        let account = UsagePoolForecast.Account(
            id: "codex", displayName: "Codex", weekly: self.window(0, nil),
            session: self.window(100, "2026-11-06T12:50:00Z", minutes: 300), isActive: true)
        let credits = try self.credits("""
        {"credits":[{"id":"invented-blocked","status":"available","expires_at":"2026-11-06T10:50:00Z"}]}
        """)
        let result = try self.withinTimeout {
            try UsagePoolForecast.forecast(
                provider: .codex, accounts: [account], now: self.now,
                pace: .init(unitsPerDay: 24, assumption: "invented one point/hour"), credits: credits, continuationDays: 7)
        }
        #expect(result.actingRunwayUntil == self.now)
        #expect(result.unmetDemand == 68)
        #expect(result.redemptions.isEmpty)
        #expect(result.comingUp.first?.kind == .creditExpiry)
        #expect(result.comingUp.first?.at == self.now.addingTimeInterval(3600))
        #expect(result.wasteByAccount["codex"] == 100)
    }
}
