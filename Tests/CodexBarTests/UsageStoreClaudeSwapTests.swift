import Foundation
import Testing
@testable import AgentMeter
@testable import CodexBarCore

@MainActor
struct UsageStoreClaudeSwapTests {
    @Test func absentFeedPreservesSingleAccountState() async throws {
        let store = try self.makeStore()
        let original = UsageSnapshot(
            primary: RateWindow(usedPercent: 15, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(original, provider: .claude)
        store._test_claudeSwapFetch = { nil }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil) == false)
        #expect(store.claudeSwapAccounts == nil)
        #expect(store.snapshot(for: .claude)?.primary == original.primary)
    }

    @Test func utilisationHistoryIsRecordedPerSeatAndNeverMerged() async throws {
        let store = try self.makeStore()
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
          {"number":1,"usageStatus":"ok","organizationName":"Contoso Work",
           "usage":{"fiveHour":{"pct":85},"sevenDay":{"pct":85}}},
          {"number":2,"active":true,"usageStatus":"ok","organizationName":"a@b.invalid Org",
           "usage":{"fiveHour":{"pct":11},"sevenDay":{"pct":11}}}
        ]}
        """#.utf8))
        store._test_claudeSwapFetch = { accounts }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil))

        let live = try #require(store.claudeSwapAccounts)
        #expect(live.count == 2)

        // Each seat gets its own series. Before this, both wrote into one provider bucket and the
        // chart showed whichever refreshed last, matching neither card.
        let first = store.claudeSwapPlanUtilizationHistories(for: live[0])
        let second = store.claudeSwapPlanUtilizationHistories(for: live[1])
        #expect(!first.isEmpty)
        #expect(!second.isEmpty)

        func latestPercent(_ histories: [PlanUtilizationSeriesHistory]) -> Double? {
            histories.first?.entries.last?.usedPercent
        }
        #expect(latestPercent(first) == 85)
        #expect(latestPercent(second) == 11)
        #expect(latestPercent(first) != latestPercent(second))

        // The menu's default selection follows the seat the CLI is logged into.
        let selection = store.planUtilizationHistorySelection(for: .claude)
        #expect(selection.accountKey == live[1].accountID)
        #expect(latestPercent(selection.histories) == 11)
    }

    @Test func utilisationHistorySurvivesASeatLeavingTheFeed() async throws {
        let store = try self.makeStore()
        let both = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"activeAccountNumber":1,"accounts":[
          {"number":1,"active":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":40},"sevenDay":{"pct":40}}},
          {"number":2,"usageStatus":"ok","usage":{"fiveHour":{"pct":70},"sevenDay":{"pct":70}}}
        ]}
        """#.utf8))
        store._test_claudeSwapFetch = { both }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil))
        let departing = try #require(store.claudeSwapAccounts?[1])
        #expect(!store.claudeSwapPlanUtilizationHistories(for: departing).isEmpty)

        // Second seat disappears. Its recorded history must not be destroyed.
        let onlyOne = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"activeAccountNumber":1,"accounts":[
          {"number":1,"active":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":41},"sevenDay":{"pct":41}}}]}
        """#.utf8))
        store._test_claudeSwapFetch = { onlyOne }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil))
        #expect(store.claudeSwapAccounts?.count == 1)
        #expect(!store.claudeSwapPlanUtilizationHistories(for: departing).isEmpty)
    }

    @Test func feedFailureKeepsAccountIsolationAndClearsActiveMarker() async throws {
        let store = try self.makeStore()
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
          {"number":1,"usageStatus":"ok","usage":{"fiveHour":{"pct":10}}},
          {"number":2,"usageStatus":"ok","usage":{"fiveHour":{"pct":90}}}
        ]}
        """#.utf8))
        store._test_claudeSwapFetch = { accounts }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil))
        #expect(store.claudeSwapAccounts?.count == 2)
        #expect(store.agentMeterLiveSnapshot().providers.count(where: { $0.usageProviderID == "claude" }) == 2)
        #expect(store.snapshot(for: .claude)?.primary?.usedPercent == 90)
        store._test_claudeSwapFetch = { throw ClaudeSwapUsage.FeedError.invalidFeed }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil))
        #expect(store.claudeSwapAccounts?.allSatisfy { $0.status == .stale && $0.isActiveCLI == nil } == true)
        #expect(store.claudeSwapAccounts?.first?.windows.first?.usedPercent == 10)
        #expect(store.snapshot(for: .claude) == nil)
        store._test_claudeSwapFetch = { nil }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil) == false)
        #expect(store.claudeSwapAccounts == nil)
        await store.widgetSnapshotPersistTask?.value
    }

    @Test func bothSnapshotWritersKeepAllAccountsAndCodex() async throws {
        let store = try self.makeStore()
        let now = Date()
        store._setSnapshotForTesting(UsageSnapshot(primary: nil, secondary: nil, updatedAt: now), provider: .codex)
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
          {"number":1,"usageStatus":"ok","usage":{"fiveHour":{"pct":10}}},
          {"number":2,"usageStatus":"ok","usage":{"fiveHour":{"pct":90}}}
        ]}
        """#.utf8))
        var summary: AgentMeterSnapshot?
        var phone: AgentMeterPhoneSnapshot?
        store._test_agentMeterSnapshotSaveOverride = { summary = $0 }
        store._test_agentMeterPhoneSnapshotSaveOverride = { phone = $0 }
        store._test_claudeSwapFetch = { accounts }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil))
        await store.widgetSnapshotPersistTask?.value
        #expect(summary?.providers.map(\.id) == ["codex", "claude:cswap:1", "claude:cswap:2"])
        #expect(phone?.providers.map(\.id) == summary?.providers.map(\.id))
        #expect(phone?.providers.last?.isActiveCLI == true)
        #expect(phone?.providers.last?.tokenUsage == nil)
    }

    @Test func disabledMidSessionAndEmptyFeedRemoveLegacyOwnership() async throws {
        let store = try self.makeStore()
        for disabled in [false, true] {
            let accounts = try ClaudeSwapUsage.parse(Data("""
            {"schemaVersion":1,"activeAccountNumber":1,"accounts":[{"number":1,
              "disabled":\(disabled),"usageStatus":"ok","usage":{"fiveHour":{"pct":10}}}]}
            """.utf8))
            store._test_claudeSwapFetch = { accounts }
            #expect(await store.refreshClaudeSwapAccounts(generation: nil))
            #expect((store.snapshot(for: .claude) == nil) == disabled)
            #expect(store.claudeSwapAccounts?.first?.status == (disabled ? .unavailable : .ok))
        }
        store._test_claudeSwapFetch = { [] }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil) == false)
        #expect(store.claudeSwapAccounts == nil)
        #expect(store.snapshot(for: .claude) == nil)
        await store.widgetSnapshotPersistTask?.value
    }

    @Test func legacyPaceUsesOnlyFreshActiveFeedWindow() async throws {
        let store = try self.makeStore()
        let accounts = try ClaudeSwapUsage.parse(Data(#"""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
          {"number":1,"usageStatus":"ok","usage":{"sevenDay":{"pct":10,"expectedPct":20,"aheadOfPace":false}}},
          {"number":2,"usageStatus":"ok","usage":{"sevenDay":{"pct":50,"expectedPct":70,"aheadOfPace":false}}}]}
        """#.utf8))
        store._test_claudeSwapFetch = { accounts }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil))
        let active = try #require(accounts[1].claudeSwapUsageSnapshot.secondary)
        let inactive = try #require(accounts[0].claudeSwapUsageSnapshot.secondary)
        #expect(store.weeklyPace(provider: .claude, window: active)?.expectedUsedPercent == 70)
        #expect(store.weeklyPace(provider: .claude, window: inactive) == nil)
        #expect(store.weeklyPace(provider: .claude, window: active, now: Date().addingTimeInterval(1800)) == nil)
        store._test_claudeSwapFetch = { throw ClaudeSwapUsage.FeedError.invalidFeed }
        #expect(await store.refreshClaudeSwapAccounts(generation: nil))
        #expect(store.weeklyPace(provider: .claude, window: active) == nil)
        await store.widgetSnapshotPersistTask?.value
    }

    private func makeStore() throws -> UsageStore {
        let suite = "UsageStoreClaudeSwapTests-\(UUID().uuidString)"
        // Without its own directory this uses the real Application Support store, so samples
        // recorded by one test are read back by the next, and the suite writes into live data.
        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-utilization-\(UUID().uuidString)", isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.setProviderEnabled(provider: .claude, metadata: ProviderDefaults.metadata[.claude]!, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            planUtilizationHistoryStore: PlanUtilizationHistoryStore(directoryURL: historyDirectory))
        store._test_widgetSnapshotSaveOverride = { _ in }
        return store
    }
}
