import Foundation
import Testing
@testable import AgentMeter
@testable import CodexBarCore

struct ClaudeSwapIntegrationTests {
    @Test func seatTypeUsesBooleanAndNeverOrganizationName() throws {
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"accounts":[
          {"number":1,"isOrganization":false,"organizationName":"private-name"},
          {"number":2,"isOrganization":true,"organizationName":"private-name"},
          {"number":3,"isOrganization":1}, {"number":4}]}
        """#.utf8))
        #expect(accounts.map(\.accountLabel) == [
            "Account 1 · Personal",
            "Account 2 · Organization",
            "Account 3",
            "Account 4",
        ])
        let summary = AgentMeterSnapshot(generatedAt: Date(), providers: accounts)
        let phone = AgentMeterPhoneSnapshot(agentMeterSnapshot: summary)
        #expect(try String(data: JSONEncoder().encode(summary), encoding: .utf8)?.contains("private-name") == false)
        #expect(try String(data: JSONEncoder().encode(phone), encoding: .utf8)?.contains("private-name") == false)
    }

    @Test func feedPaceRoundTripsAndOverridesSharedHistory() throws {
        let now = Date()
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"accounts":[{"number":1,"usageStatus":"ok","usage":{
          "sevenDay":{"pct":40,"expectedPct":10,"aheadOfPace":false,"willLastToReset":true},
          "scoped":[{"name":"Sonnet","pct":90,"expectedPct":20,"aheadOfPace":true,
                     "projectedExhaustionAt":"2027-01-01T00:00:00Z","willLastToReset":false}]}}]}
        """#.utf8), now: now)
        let account = try #require(accounts.first)
        let copy = try JSONDecoder().decode(AgentMeterProviderSnapshot.self, from: JSONEncoder().encode(account))
        #expect(copy == account)
        #expect(copy.windows[1].feedPace?.projectedExhaustionAt != nil)
        let model = try self.model(account, now: now)
        let weekly = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(weekly.pacePercent == 10)
        #expect(weekly.detailLeftText == "On pace")
        #expect(weekly.detailRightText == "Lasts until reset")
        let scoped = try #require(model.metrics.first { $0.id == "model:sonnet" })
        #expect(scoped.pacePercent == 20)
        #expect(scoped.title == "Sonnet (weekly)")
        #expect(scoped.detailLeftText?.contains("deficit") == true)
    }

    @Test func missingMalformedAndStalePaceNeverUsesSharedHistory() throws {
        for age in [0, 1800] {
            let account = try #require(ClaudeSwapUsage.parse(Data("""
            {"schemaVersion":1,"accounts":[{"number":1,"usageStatus":"ok","usageAgeSeconds":\(age),
              "usage":{"sevenDay":{"pct":40,"expectedPct":true,"aheadOfPace":1},
                "scoped":[{"name":"Opus","pct":60,"expectedPct":20,"aheadOfPace":true}]}}]}
            """.utf8)).first)
            let model = try self.model(account)
            #expect(model.metrics.first { $0.id == "secondary" }?.pacePercent == nil)
            if age > 0 {
                #expect(model.metrics.allSatisfy { $0.pacePercent == nil && $0.detailRightText == nil })
            }
        }
    }

    @Test func emptySingleAndMissingUsageFeeds() throws {
        #expect(try ClaudeSwapUsage.parse(Data(#"{"schemaVersion":1,"accounts":[]}"#.utf8)).isEmpty)
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"accounts":[{"number":1,"usageStatus":"ok","futureField":{}}]}
        """#.utf8))
        #expect(accounts.count == 1)
        #expect(accounts[0].status == .unavailable)
        #expect(accounts[0].windows.isEmpty)
    }

    @Test func rawErrorOverridesOKAndNeverEscapes() throws {
        let account = try #require(ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"accounts":[{"number":1,"usageStatus":"ok","usageError":"private-error",
          "usage":{"fiveHour":{"pct":50}}}]}
        """#.utf8)).first)
        #expect(account.status == .unavailable)
        #expect(account.windows.isEmpty)
        #expect(account.lastError?.contains("private-error") == false)
    }

    @Test func rejectsMalformedTruncatedOversizedAndExcessiveAccounts() throws {
        for text in ["{", "null", "[]", #"{"schemaVersion":1,"accounts":["#] {
            #expect(throws: ClaudeSwapUsage.FeedError.invalidFeed) {
                try ClaudeSwapUsage.parse(Data(text.utf8))
            }
        }
        #expect(throws: ClaudeSwapUsage.FeedError.invalidFeed) {
            try ClaudeSwapUsage.parse(Data(repeating: 32, count: 2 * 1024 * 1024 + 1))
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "accounts": (1...65).map { ["number": $0] },
        ])
        #expect(throws: ClaudeSwapUsage.FeedError.invalidFeed) { try ClaudeSwapUsage.parse(data) }
    }

    @Test func disabledAccountCannotOwnLegacyProvider() throws {
        let account = try #require(ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"activeAccountNumber":1,"accounts":[{"number":1,"disabled":true,"usageAgeSeconds":1800,
          "usageStatus":"ok","usage":{"fiveHour":{"pct":50}}}]}
        """#.utf8)).first)
        #expect(account.isActiveCLI == false)
        #expect(account.status == .unavailable)
        let summary = AgentMeterSnapshot(generatedAt: Date(), providers: [account])
        #expect(AgentMeterMenuSummaryModel(snapshot: summary).rows.first?.status == .unavailable)
    }

    @Test func nullErrorAndExtremeAgeStaySafe() throws {
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"error":null,"accounts":[
          {"number":1,"usageStatus":"ok","usageError":null,"usage":{"sevenDay":{"pct":1}}},
          {"number":2,"usageStatus":"ok","usageAgeSeconds":1e300,"usage":{"sevenDay":{"pct":1}}}]}
        """#.utf8))
        #expect(accounts[0].status == .ok)
        #expect(accounts[1].status == .stale)
        #expect(accounts[1].updatedAt.timeIntervalSince1970.isFinite)
        #expect(throws: Never.self) { _ = try JSONEncoder().encode(accounts) }
    }

    @Test func absentExecutableReturnsNil() async throws {
        #expect(try await ClaudeSwapUsage.fetch(binary: nil, timeout: 1) == nil)
    }

    @Test func hangingFeedIsBounded() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: script) }
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let start = Date()
        do {
            _ = try await ClaudeSwapUsage.fetch(binary: script.path, timeout: 0.2)
            Issue.record("Expected timeout")
        } catch let error as SubprocessRunnerError {
            guard case .timedOut = error else { Issue.record("Unexpected subprocess error"); return }
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    private func model(_ account: AgentMeterProviderSnapshot, now: Date = Date()) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            snapshot: account.claudeSwapUsageSnapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            weeklyPace: .historical(
                expectedUsedPercent: 99,
                actualUsedPercent: 1,
                etaSeconds: nil,
                willLastToReset: true,
                runOutProbability: nil),
            claudeSwapAccount: account,
            now: now))
    }
}
