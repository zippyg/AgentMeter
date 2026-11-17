import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import AgentMeter

struct AllAccountsDashboardTests {
    private let now = Date(timeIntervalSince1970: 1_793_577_600)

    private func source(user: String, provider: UsageProvider, stale: Bool = false) -> SharedCostUsage.Source {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 100, sessionCostUSD: 4, last30DaysTokens: 100, last30DaysCostUSD: 4,
            daily: [.init(date: "2026-11-02", inputTokens: 10, outputTokens: 20,
                          cacheReadTokens: 30, cacheCreationTokens: 40, totalTokens: 100,
                          costUSD: 4, modelsUsed: nil, modelBreakdowns: [
                            .init(modelName: "model-a", costUSD: 1, totalTokens: 10),
                            .init(modelName: "model-b", costUSD: 2, totalTokens: 20),
                            .init(modelName: "model-c", costUSD: 0.75, totalTokens: 30),
                            .init(modelName: "model-d", costUSD: 0.25, totalTokens: 40),
                          ])], updatedAt: self.now)
        return .init(user: user, usage: .init(provider: provider, snapshot: snapshot), stale: stale)
    }

    private func accountSource(user: String, keys: [String]) -> SharedCostUsage.Source {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 0, sessionCostUSD: 0, last30DaysTokens: nil, last30DaysCostUSD: nil,
            daily: [.init(
                date: "2026-11-02", inputTokens: 0, outputTokens: 0,
                totalTokens: keys.count * 10, costUSD: Double(keys.count),
                modelsUsed: nil, modelBreakdowns: nil,
                accountBreakdowns: keys.map { .init(modelName: $0, costUSD: 1, totalTokens: 10) })],
            updatedAt: self.now)
        return .init(user: user, usage: .init(provider: .claude, snapshot: snapshot), stale: false)
    }

    @Test func foreignSlotsNeverBorrowLocalLabels() throws {
        let model = try #require(AllAccountsDashboardModel.make(sources: [
            self.accountSource(user: NSUserName(), keys: ["slot:1"]),
            self.accountSource(user: "other", keys: ["slot:1", "acct:shared"]),
        ], accountLabels: ["slot:1": "Local", "acct:shared": "Shared"], now: self.now))
        #expect(model.subscriptions.count == 3)
        #expect(model.subscriptions.first { $0.label == "Local" }?.tokens == 10)
        #expect(model.subscriptions.first { $0.label == "other slot 1" }?.tokens == 10)
        #expect(model.subscriptions.first { $0.label == "Shared" }?.tokens == 10)
    }

    @Test func duplicateLabelsPreserveDistinctSubscriptionIdentities() throws {
        let keys = ["slot:1", "acct:first", "slot:2", "acct:second"]
        let model = try #require(AllAccountsDashboardModel.make(
            sources: [self.accountSource(user: NSUserName(), keys: keys)],
            accountLabels: Dictionary(uniqueKeysWithValues: keys.map { ($0, "Team") }),
            accountKeyGroups: [["slot:1", "acct:first"], ["slot:2", "acct:second"]],
            now: self.now))
        #expect(model.subscriptions.count == 2)
        #expect(Set(model.subscriptions.map(\.label)) == ["Team", "Team (2)"])
        #expect(model.subscriptions.allSatisfy { $0.tokens == 20 })
        #expect(Set(model.subscriptions.map(\.id)).count == 2)
    }

    @Test func failedExportRemainsVisibleOnCard() throws {
        let model = try #require(UsageMenuCardView.Model.allAccountsDashboard(
            sources: [self.source(user: NSUserName(), provider: .codex)],
            exportFailures: [.codex], now: self.now))
        #expect(model.sources.contains { $0.label == "\(NSUserName()) Codex" && $0.status == "export failed" })
        #expect(model.tokens == 100)
        #expect(UsageMenuCardView.Model.allAccountsDashboard(
            sources: [], exportFailures: [.claude], now: self.now) == nil)
    }

    @Test func combinesUsersEnginesTokenTypesAndAllModels() throws {
        let sources = ["work", "personal"].flatMap { user in
            [UsageProvider.claude, .codex].map { self.source(user: user, provider: $0) }
        }
        let model = try #require(UsageMenuCardView.Model.allAccountsDashboard(sources: sources, now: self.now))
        #expect(model.tokens == 400)
        #expect(model.cost == 16)
        #expect(model.days.count == 30)
        #expect(model.days.last?.values == [100, 100, 100, 100])
        // Chart hover reads each series' cost for the day alongside its tokens.
        #expect(model.days.last?.costs == [4, 4, 4, 4])
        #expect(model.days.first?.costs == [0, 0, 0, 0])
        #expect(model.chartDomain == model.days.map(\.id))
        #expect(model.chartDomain == model.chartDomain.sorted() && Set(model.chartDomain).count == 30)
        #expect(model.sources.contains { $0.label == "work Claude" })
        #expect(model.sources.contains { $0.label == "personal Codex" })
        // Codex input includes its cached part, so the shared fixture's 10 input under 30 cached adds no uncached input.
        #expect(model.tokenTypes.map(\.tokens) == [20, 80, 120, 160])
        #expect(model.models.first?.label == "model-b")
        #expect(model.models.count == 4)
        #expect(model.models.contains { $0.label == "model-d" })
    }

    @Test func staleSourceIsVisibleAndExcludedFromTotals() throws {
        let sources = [self.source(user: "work", provider: .claude),
                       self.source(user: "personal", provider: .codex, stale: true)]
        let model = try #require(UsageMenuCardView.Model.allAccountsDashboard(sources: sources, now: self.now))
        #expect(model.tokens == 100)
        #expect(model.sources.contains { $0.label == "personal Codex" && $0.status == "stale, excluded" })
        #expect(UsageMenuCardView.Model.allAccountsDashboard(sources: [], now: self.now) == nil)
    }

    @Test func todayDoesNotUseYesterdaysCost() throws {
        let yesterday = self.now.addingTimeInterval(-24 * 60 * 60)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 0, sessionCostUSD: 0, last30DaysTokens: 100, last30DaysCostUSD: 4,
            daily: [.init(date: "2026-11-01", inputTokens: 100, outputTokens: 0, totalTokens: 100,
                          costUSD: 4, modelsUsed: nil, modelBreakdowns: nil)], updatedAt: yesterday)
        let source = SharedCostUsage.Source(
            user: "work", usage: .init(provider: .claude, snapshot: snapshot), stale: false)
        let model = try #require(UsageMenuCardView.Model.allAccountsDashboard(sources: [source], now: self.now))
        #expect(model.todayCost == 0)
        #expect(model.todayTokens == 0)
        #expect(model.cost == 4)
    }

    @Test func scopesFilterTotalsSourcesFailuresAndModels() throws {
        let sources = [self.source(user: "alice", provider: .claude),
                       self.source(user: "bob", provider: .codex)]
        for scope in [AllAccountsDashboardModel.Scope.claude, .codex] {
            let model = try #require(UsageMenuCardView.Model.allAccountsDashboard(
                sources: sources, scope: scope, exportFailures: [.claude, .codex], now: self.now))
            #expect(model.tokens == 100)
            #expect(model.cost == 4)
            #expect(model.todayTokens == 100)
            #expect(model.sources.allSatisfy { $0.engine == scope.rawValue })
            #expect(model.engines.count == 1)
            #expect(model.days.last?.values == [100])
            #expect(model.models.first?.tokens == 20)
        }
        #expect(UsageMenuCardView.Model.allAccountsDashboard(
            sources: [sources[0]], scope: .codex, now: self.now) == nil)
    }

    @Test func chartPadsMissingDaysAndDropsOutOfWindowData() throws {
        let model = try #require(UsageMenuCardView.Model.allAccountsDashboard(
            sources: [self.source(user: "alice", provider: .claude)],
            now: Calendar.current.date(byAdding: .day, value: 30, to: self.now)!))
        #expect(model.tokens == 0)
        #expect(model.days.count == 30)
        #expect(model.days.allSatisfy { $0.values == [0] })
        #expect(model.models.isEmpty)
    }

    @Test func hierarchyPartitionsProviderUserAccountAndModelTotals() throws {
        let sources = ["invented-user-1", "invented-user-2"].flatMap { user in
            [UsageProvider.claude, .codex].map { self.source(user: user, provider: $0) }
        } + [self.source(user: "invented-stale", provider: .claude, stale: true)]
        for window in AllAccountsDashboardModel.Window.allCases {
            let model = try #require(AllAccountsDashboardModel.make(sources: sources, window: window, now: self.now))
            #expect(model.providers.reduce(0) { $0 + $1.row.tokens } == model.tokens)
            #expect(abs(model.providers.reduce(0) { $0 + $1.row.cost } - model.cost) < 0.000001)
            for provider in model.providers {
                #expect(provider.users.reduce(0) { $0 + $1.row.tokens } == provider.row.tokens)
                #expect(abs(provider.users.reduce(0) { $0 + $1.row.cost } - provider.row.cost) < 0.000001)
                #expect(provider.models.reduce(0) { $0 + $1.tokens } == provider.row.tokens)
                #expect(abs(provider.models.reduce(0) { $0 + $1.cost } - provider.row.cost) < 0.000001)
                for user in provider.users {
                    #expect(user.accounts.reduce(0) { $0 + $1.tokens } == user.row.tokens)
                    #expect(abs(user.accounts.reduce(0) { $0 + $1.cost } - user.row.cost) < 0.000001)
                    #expect(user.accounts.allSatisfy { $0.engine == provider.id })
                    for account in user.accounts {
                        let models = try #require(user.accountModels[account.id])
                        #expect(models.reduce(0) { $0 + $1.tokens } == account.tokens)
                        #expect(abs(models.reduce(0) { $0 + $1.cost } - account.cost) < 0.000001)
                    }
                }
            }
        }
    }

    @MainActor
    @Test func hierarchyKeepsAccountKeysAndPrivacyStableAcrossPeriodsAndViews() throws {
        for window in AllAccountsDashboardModel.Window.allCases {
            let model = try #require(AllAccountsDashboardModel.make(sources: [
                self.accountSource(user: NSUserName(), keys: ["slot:1", "acct:first", "slot:2"]),
                self.accountSource(user: "invented-other", keys: ["slot:1"]),
            ], accountLabels: ["slot:1": "invented-login-1", "acct:first": "invented-login-1", "slot:2": "invented-login-2"],
                accountKeyGroups: [["slot:1", "acct:first"]],
                privateAccountLabels: ["slot:1": "Login 1", "acct:first": "Login 1", "slot:2": "Login 2"],
                window: window, now: self.now))
            let provider = try #require(model.providers.first)
            let local = try #require(provider.users.first { $0.row.label == NSUserName() })
            #expect(local.accounts.count == 2)
            #expect(local.accounts.reduce(0) { $0 + $1.tokens } == local.row.tokens)
            #expect(Set(local.accounts.compactMap(\.privateLabel)) == ["Login 1", "Login 2"])
            let view = AllAccountsUsageCard(model: model, width: 348, showsDetails: true, hideNames: true)
            #expect(local.accounts.map { view.displayLabel($0) }.sorted() == ["Login 1", "Login 2"])
            for user in provider.users {
                #expect(view.displayLabel(user.row).hasPrefix("User "))
            }
            #expect(model.sources.map { view.displayLabel($0) }.allSatisfy { $0.hasPrefix("User ") })
        }
    }

    @MainActor
    @Test func hierarchyUsesRecordedCodexAccountCountersWithoutInventingAttribution() throws {
        let source = self.accountSource(user: NSUserName(), keys: ["acct:invented-first", "acct:invented-second"])
        let snapshot = CostUsageTokenSnapshot(sessionTokens: nil, sessionCostUSD: nil,
            last30DaysTokens: nil, last30DaysCostUSD: nil, daily: source.usage.report.data, updatedAt: self.now)
        let model = try #require(AllAccountsDashboardModel.make(sources: [
            .init(user: NSUserName(), usage: .init(provider: .codex, snapshot: snapshot), stale: false),
        ], now: self.now))
        let user = try #require(model.providers.first { $0.id == "codex" }?.users.first)
        #expect(user.accounts.count == 2)
        #expect(user.accounts.reduce(0) { $0 + $1.tokens } == user.row.tokens)
        #expect(user.accounts.reduce(0) { $0 + $1.cost } == user.row.cost)
        let missing = try #require(AllAccountsDashboardModel.make(
            sources: [self.source(user: NSUserName(), provider: .codex)], now: self.now))
        let unattributed = try #require(missing.providers.first { $0.id == "codex" }?.users.first?.accounts.first)
        #expect(unattributed.label == "Codex account")
        #expect(unattributed.status == nil)
        #expect(unattributed.tokens == missing.tokens)
        let unknown = self.accountSource(user: NSUserName(), keys: ["unknown"])
        let unknownSnapshot = CostUsageTokenSnapshot(sessionTokens: nil, sessionCostUSD: nil,
            last30DaysTokens: nil, last30DaysCostUSD: nil, daily: unknown.usage.report.data, updatedAt: self.now)
        let single = try #require(AllAccountsDashboardModel.make(sources: [
            .init(user: NSUserName(), usage: .init(provider: .codex, snapshot: unknownSnapshot), stale: false),
        ], now: self.now))
        let singleAccount = try #require(single.providers.first { $0.id == "codex" }?.users.first?.accounts.first)
        #expect(singleAccount.label == "Codex account")
        let hidden = AllAccountsUsageCard(model: single, width: 348, showsDetails: true, hideNames: true)
        #expect(hidden.displayLabel(singleAccount) == "Codex account")
    }

    @MainActor
    @Test func accountModelsSurviveExportMergeAndStayUnderTheirOwnLogin() throws {
        let entry = CostUsageDailyReport.Entry(date: "2026-11-02", inputTokens: 100, outputTokens: 0,
            totalTokens: 100, costUSD: 10, modelsUsed: nil, modelBreakdowns: [
                .init(modelName: "invented-model-a", costUSD: 6, totalTokens: 60),
                .init(modelName: "invented-model-b", costUSD: 4, totalTokens: 40),
            ], accountBreakdowns: [
                .init(modelName: "slot:1", costUSD: 3, totalTokens: 30, modelBreakdowns: [
                    .init(modelName: "invented-model-a", costUSD: 1, totalTokens: 10),
                    .init(modelName: "invented-model-b", costUSD: 2, totalTokens: 20),
                ]),
                .init(modelName: "acct:invented-second", costUSD: 7, totalTokens: 70, modelBreakdowns: [
                    .init(modelName: "invented-model-a", costUSD: 5, totalTokens: 50),
                    .init(modelName: "invented-model-b", costUSD: 2, totalTokens: 20),
                ]),
            ])
        let snapshot = CostUsageTokenSnapshot(sessionTokens: nil, sessionCostUSD: nil, last30DaysTokens: nil,
            last30DaysCostUSD: nil, daily: [entry, entry], updatedAt: self.now)
        let export = SharedCostUsage(engines: [.init(provider: .claude, snapshot: snapshot)], generatedAt: self.now)
        let decoded = try JSONDecoder().decode(SharedCostUsage.self, from: JSONEncoder().encode(export))
        let model = try #require(AllAccountsDashboardModel.make(sources: [
            .init(user: NSUserName(), usage: decoded.engines[0], stale: false),
            self.source(user: "invented-codex-user", provider: .codex),
        ], accountLabels: ["slot:1": "Invented first", "acct:invented-second": "Invented second"], now: self.now))
        let user = try #require(model.providers.first { $0.id == "claude" }?.users.first)
        #expect(user.row.tokens == 200)
        #expect(user.accounts.count == 2)
        for (label, expected) in [("Invented first", [20, 40]), ("Invented second", [100, 40])] {
            let account = try #require(user.accounts.first { $0.label == label })
            let models = try #require(user.accountModels[account.id])
            #expect(models.sorted { $0.label < $1.label }.map(\.tokens) == expected)
            #expect(models.reduce(0) { $0 + $1.tokens } == account.tokens)
            #expect(models.reduce(0) { $0 + $1.cost } == account.cost)
        }
        let codex = try #require(model.providers.first { $0.id == "codex" }?.users.first)
        let account = try #require(codex.accounts.first)
        #expect(account.label == "Codex account")
        #expect(account.status == nil)
        #expect(codex.accountModels[account.id]?.count == 4)
        #expect(codex.accountModels[account.id]?.reduce(0) { $0 + $1.tokens } == 100)
        if let directory = ProcessInfo.processInfo.environment["AGENTMETER_UI_REVIEW_DIR"] {
            for (scheme, name) in [(ColorScheme.dark, "dark"), (.light, "light")] {
                let view = AllAccountsUsageCard(model: model, width: 348, showsDetails: true)
                    .padding(16).background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("analytics-account-models-\(name).png"))
            }
        }
    }

    @MainActor
    @Test func renderCards() throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTMETER_RENDER_DIR"] else { return }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sources = self.renderSources()
        for (scope, scheme, name) in [
            (AllAccountsDashboardModel.Scope.overview, ColorScheme.dark, "overview-dark"),
            (.claude, .dark, "claude-dark"), (.codex, .dark, "codex-dark"),
            (.overview, .light, "overview-light"),
        ] {
            let model = try #require(UsageMenuCardView.Model.allAccountsDashboard(
                sources: sources, scope: scope, now: self.now))
            #expect(model.days.count == 30)
            let view = AllAccountsUsageCard(model: model, width: 340)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.97))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == 680)
            #expect(image.height < (scope == .overview ? 560 : 1000))
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: destination.appendingPathComponent("card-\(name).png"))
        }
    }

    private func renderSources() -> [SharedCostUsage.Source] {
        ["alice", "bob"].enumerated().flatMap { userIndex, user in
            [UsageProvider.claude, .codex].enumerated().map { engineIndex, provider in
                let daily = (-29...0).map { offset -> CostUsageDailyReport.Entry in
                    let date = Calendar.current.date(byAdding: .day, value: offset, to: self.now)!
                    let input = (30 + offset) * 12345 * (userIndex + 1)
                    let output = input / 3
                    let read = input * (engineIndex + 2)
                    let write = input / 2
                    let total = input + output + read + write
                    let cost = Double(total) / 1_000_000 * 3.5
                    return .init(
                        date: AllAccountsDashboardModel.dayKey(from: date),
                        inputTokens: input, outputTokens: output, cacheReadTokens: read,
                        cacheCreationTokens: write, totalTokens: total, costUSD: cost,
                        modelsUsed: nil, modelBreakdowns: [
                            .init(modelName: provider == .claude ? "claude-opus-4-1" : "gpt-5-codex",
                                  costUSD: cost * 0.6, totalTokens: total * 6 / 10),
                            .init(modelName: provider == .claude ? "claude-sonnet-4-5" : "gpt-5-mini",
                                  costUSD: cost * 0.3, totalTokens: total * 3 / 10),
                            .init(modelName: provider == .claude ? "claude-haiku-4-5" : "gpt-5",
                                  costUSD: cost * 0.1, totalTokens: total / 10),
                        ])
                }
                let snapshot = CostUsageTokenSnapshot(
                    sessionTokens: 0, sessionCostUSD: 0, last30DaysTokens: nil, last30DaysCostUSD: nil,
                    daily: daily, updatedAt: self.now)
                return SharedCostUsage.Source(
                    user: user, usage: .init(provider: provider, snapshot: snapshot), stale: false)
            }
        }
    }
}
