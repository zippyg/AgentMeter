import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import AgentMeter

/// Checks the usage export from a synthetic Claude tab. With AGENTMETER_RENDER_DIR=/path it also
/// writes PNGs of the tab's cards for visual review. Synthetic data only.
@MainActor
struct AgentMeterRenderTests {
    @Test(arguments: [
        "Example Org user@example.invalid 12345678-1234-1234-1234-123456789abc",
        "Bearer synthetic",
    ])
    func `usage export sanitizes every label before writing`(label: String) throws {
        let now = Date()
        let row = AllAccountsDashboardModel.Row(id: "test", label: label, tokens: 10, cost: 1)
        let model = AllAccountsDashboardModel(
            scope: .claude, tokens: 10, cost: 1, todayTokens: 10, todayCost: 1, days: [],
            sources: [row], engines: [], tokenTypes: [row], models: [row], subscriptions: [row])
        let scope = AgentMeterUsageExport.Scope(model)
        let export = AgentMeterUsageExport(
            schemaVersion: 1, generatedAt: now, windowDays: 30, all: scope, claude: scope, codex: scope)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        try export.write(to: url)
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("@"))
        #expect(!text.contains("12345678-1234-1234-1234-123456789abc"))
        #expect(!AgentMeterSnapshotSecurity.containsSensitiveMaterial(data))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AgentMeterUsageExport.self, from: data)
        #expect(decoded.claude?.tokens == 10)
        #expect(decoded.claude?.bySubscription.count == 1)
    }

    @Test
    nonisolated func `usage export writes preserve submission order`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        let older = AgentMeterUsageExport(
            schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 1), windowDays: 30,
            all: nil, claude: nil, codex: nil)
        let newer = AgentMeterUsageExport(
            schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 2), windowDays: 30,
            all: nil, claude: nil, codex: nil)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let writes = DispatchGroup()
        writes.enter()
        AgentMeterUsageExportWriter.enqueue {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            try? older.write(to: url)
            writes.leave()
        }
        #expect(started.wait(timeout: .now() + 5) == .success)
        writes.enter()
        AgentMeterUsageExportWriter.enqueue {
            try? newer.write(to: url)
            secondFinished.signal()
            writes.leave()
        }
        _ = secondFinished.wait(timeout: .now() + 0.1)
        release.signal()
        #expect(writes.wait(timeout: .now() + 5) == .success)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(AgentMeterUsageExport.self, from: Data(contentsOf: url)) == newer)
    }

    @Test
    func `claude tab cards render and the usage export carries no identities`() throws {
        let dir = ProcessInfo.processInfo.environment["AGENTMETER_RENDER_DIR"]
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }
        let suite = "AgentMeterRenderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(
            userDefaults: defaults, configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(), syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        try settings.setProviderEnabled(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]), browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings, startupBehavior: .testing, environmentBase: [:])
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let iso = ISO8601DateFormatter()
        func at(_ hours: Double) -> String {
            iso.string(from: now.addingTimeInterval(hours * 3600))
        }
        store.claudeSwapAccounts = try ClaudeSwapUsage.parse(Data("""
        {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
         {"number":1,"alias":"personal-max","organizationName":"a@b.c","usageStatus":"ok","usageAgeSeconds":60,
          "usage":{"sevenDay":{"pct":54,"resetsAt":"\(at(130))"}}},
         {"number":2,"alias":"work-1","organizationName":"Example Org","usageStatus":"ok","usageAgeSeconds":60,
          "usage":{"fiveHour":{"pct":50,"resetsAt":"\(at(3))"},"sevenDay":{"pct":25,"resetsAt":"\(at(100))"}}},
         {"number":3,"alias":"work-2","organizationName":"Example Org","usageStatus":"unavailable","usage":null,
          "usageError":"http-429","usageRetryAt":"\(at(0.5))","lastGoodFetchedAt":"\(at(-50))",
          "lastGoodUsage":{"fiveHour":{"pct":30,"resetsAt":"\(at(-45))"},"sevenDay":{"pct":95,"resetsAt":"\(at(-10))"}}}
        ]}
        """.utf8), now: now)
        func day(_ offset: Int, _ tokens: Int) -> CostUsageDailyReport.Entry {
            let date = AllAccountsDashboardModel.dayKey(from: Calendar.current.date(
                byAdding: .day,
                value: -offset,
                to: now)!)
            return .init(
                date: date, inputTokens: tokens / 100, outputTokens: tokens / 50,
                cacheReadTokens: tokens * 9 / 10, cacheCreationTokens: tokens / 20, totalTokens: tokens,
                costUSD: Double(tokens) / 4_000_000, modelsUsed: ["claude-opus-5-5"],
                modelBreakdowns: [.init(
                    modelName: "claude-opus-5-5",
                    costUSD: Double(tokens) / 4_000_000,
                    totalTokens: tokens)],
                accountBreakdowns: [
                    .init(modelName: "slot:1", costUSD: Double(tokens) / 16_000_000, totalTokens: tokens / 4),
                    .init(modelName: "slot:2", costUSD: Double(tokens) / 8_000_000, totalTokens: tokens / 2),
                    .init(modelName: "slot:3", costUSD: Double(tokens) / 16_000_000, totalTokens: tokens / 4),
                ])
        }
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1, sessionCostUSD: 1, last30DaysTokens: 1, last30DaysCostUSD: 1,
            daily: (0..<30).map { day($0, 1_000_000_000 + ($0 % 7) * 300_000_000) }, updatedAt: now)
        store.tokenSnapshots[.claude] = snapshot
        store.overviewTokenSnapshots[.claude] = snapshot
        let controller = StatusItemController(
            store: store, settings: settings, account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(), preferencesSelection: PreferencesSelection(), statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let accountModels = controller.claudeSwapMenuCardModels()
        #expect(accountModels.filter { $0.seatIsLive == true }.map(\.seatName) == ["Example Org · work-1"])
        #expect(accountModels.allSatisfy { $0.seatName?.contains("CLI active") != true })
        let export = store.makeUsageExport(now: now)
        #expect(export.claude?.bySubscription.map(\.label).sorted() == ["personal-max", "work-1", "work-2"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(export)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(AgentMeterUsageExport.self, from: data) == export)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("@") && !text.contains("acct:") && !text.contains("slot:"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-export-\(UUID().uuidString)/agentmeter-usage.json")
        try export.write(to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())

        guard let dir else { return }
        let width: CGFloat = 320
        var views: [AnyView] = controller.claudeSwapMenuCardModels().map {
            AnyView(UsageMenuCardView(model: $0, width: width))
        }
        if let dashboard = AllAccountsDashboardModel.make(
            sources: store.allAccountsUsageSources(now: now), scope: .claude,
            accountLabels: store.claudeSubscriptionLabels(),
            accountKeyGroups: Array(ClaudeSwapUsage.accountKeys().values), now: now)
        {
            views.append(AnyView(AllAccountsUsageCard(model: dashboard, width: width)))
        }
        let stack = VStack(spacing: 0) {
            ForEach(Array(views.enumerated()), id: \.offset) { _, view in view; Divider() }
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        for scheme in [ColorScheme.dark, .light] {
            let renderer = ImageRenderer(content: stack.environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("claude-tab-\(scheme).png"))
        }
    }
}
