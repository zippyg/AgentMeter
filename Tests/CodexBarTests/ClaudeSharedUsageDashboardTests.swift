import AppKit
import CodexBarCore
import Testing
@testable import AgentMeter

@MainActor
@Suite(.serialized)
struct ClaudeSharedUsageDashboardTests {
    @Test func twoSeatsHaveOneSharedDashboardAfterBothCards() throws {
        try self.checkMenu(accountCount: 2, hasCostData: true, expectedIDs: [
            "menuCard-0", "menuCard-1", "sharedUsageDashboard-claude",
        ])
    }

    @Test func oneAccountAlsoShowsMachineTotals() throws {
        try self.checkMenu(accountCount: 1, hasCostData: true, expectedIDs: [
            "menuCard-0", "sharedUsageDashboard-claude",
        ])
    }

    @Test func noFeedKeepsTheLiveCardAndItsDashboard() throws {
        // With no feed the live Claude card is emitted as a usage item plus a cost item.
        try self.checkMenu(
            accountCount: nil,
            hasCostData: true,
            expectedIDs: ["menuCardUsage", "menuCardCost"])
    }

    @Test func missingCostDataOmitsTheSharedDashboard() throws {
        try self.checkMenu(accountCount: 2, hasCostData: false, expectedIDs: ["menuCard-0", "menuCard-1"])
    }

    private func checkMenu(accountCount: Int?, hasCostData: Bool, expectedIDs: [String]) throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let suite = "ClaudeSharedUsageDashboardTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        settings.setProviderEnabled(provider: .claude, metadata: ProviderDefaults.metadata[.claude]!, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        if let accountCount {
            let accounts = try ClaudeSwapUsage.parse(Data(#"""
            {"schemaVersion":1,"accounts":[
              {"number":1,"usageStatus":"ok","usage":{"fiveHour":{"pct":10}}},
              {"number":2,"usageStatus":"ok","usage":{"fiveHour":{"pct":20}}}
            ]}
            """#.utf8))
            store.claudeSwapAccounts = Array(accounts.prefix(accountCount))
        }
        if hasCostData {
            store.tokenSnapshots[.claude] = CostUsageTokenSnapshot(
                sessionTokens: 150,
                sessionCostUSD: 0.12,
                last30DaysTokens: 150,
                last30DaysCostUSD: 0.12,
                daily: [.init(
                    date: "2023-11-14",
                    inputTokens: 100,
                    outputTokens: 50,
                    totalTokens: 150,
                    costUSD: 0.12,
                    modelsUsed: ["claude-sonnet-4"],
                    modelBreakdowns: [.init(modelName: "claude-sonnet-4", costUSD: 0.12, totalTokens: 150)])],
                updatedAt: Date())
        }
        store.overviewTokenSnapshots[.claude] = store.tokenSnapshots[.claude]
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .claude)
        controller.populateMenu(menu, provider: .claude)
        let cards = menu.items.filter {
            let id = $0.representedObject as? String ?? ""
            return id.hasPrefix("menuCard") || id == "sharedUsageDashboard-claude"
        }
        #expect(cards.compactMap { $0.representedObject as? String } == expectedIDs)
        #expect(controller.claudeSwapMenuCardModels().allSatisfy { $0.inlineUsageDashboard == nil })
        let liveDashboard = controller.menuCardModel(for: .claude)?.inlineUsageDashboard
        #expect((liveDashboard != nil) == hasCostData)
        if let shared = cards.first(where: { $0.representedObject as? String == "sharedUsageDashboard-claude" }) {
            #expect(shared.title == L("This Mac · Claude"))
            let dashboard = try #require(liveDashboard)
            #expect(dashboard.kpis.count == 4)
            #expect(dashboard.points.count == 1)
            #expect(dashboard.detailLines.contains("Top model: claude-sonnet-4"))
            #expect(dashboard.detailLines.contains { $0.contains("Estimated from local Claude logs") })
        }
    }
}
