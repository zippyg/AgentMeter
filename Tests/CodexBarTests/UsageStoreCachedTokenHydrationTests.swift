import Foundation
import Observation
import Testing
@testable import AgentMeter
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreCachedTokenHydrationTests {
    @Test func refreshCountsAllMacHomesWithManagedCodexEnvironment() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date()
        let main = env.root.appendingPathComponent(".codex")
        let overflow = env.root.appendingPathComponent(".codex-invented-overflow")
        let managed = env.root.appendingPathComponent("managed-codex-homes/invented")
        for (home, tokens) in [(main, 100), (overflow, 200), (managed, 400)] {
            try Self.writeCodexSessionFile(homeRoot: home, env: env, day: now,
                filename: "\(tokens).jsonl", tokens: tokens)
        }
        let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let partition = String(format: "%04d/%02d/%02d", components.year!, components.month!, components.day!)
        let original = main.appendingPathComponent("sessions/\(partition)/100.jsonl")
        let metadata = try env.jsonl([["type": "session_meta", "payload": ["id": "invented-main"]]])
        let contents = try String(contentsOf: original, encoding: .utf8)
        try (metadata + contents).write(to: original, atomically: true, encoding: .utf8)
        for home in [overflow, managed] {
            try FileManager.default.copyItem(at: original,
                to: home.appendingPathComponent("sessions/\(partition)/copied.jsonl"))
        }
        let config = env.root.appendingPathComponent("codex-overflow.json")
        try JSONSerialization.data(withJSONObject: ["home": overflow.path, "enabled": true])
            .write(to: config)
        let older = try #require(Calendar.current.date(byAdding: .day, value: -10, to: now))
        try Self.writeCodexSessionFile(homeRoot: main, env: env, day: older,
            filename: "older.jsonl", tokens: 50)
        let settings = TokenCostTestSupport.makeCodexOnlySettings(historyDays: 30)
        let account = ManagedCodexAccount(id: UUID(), email: "invented@example.invalid",
            managedHomePath: managed.path, createdAt: 1, updatedAt: 1, lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = account
        settings.codexActiveSource = .managedAccount(id: account.id)
        defer { settings._test_activeManagedCodexAccount = nil }
        let store = UsageStore(fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(cacheRoot: env.cacheRoot),
            settings: settings, startupBehavior: .testing,
            environmentBase: ["CODEX_HOME": managed.path, "CODEX_OVERFLOW_CONFIG": config.path])

        let exports = env.root.appendingPathComponent("exports")
        await confirmation("Today publishes before the history backfill") { published in
            withObservationTracking {
                _ = store.tokenSnapshots[.codex]
            } onChange: {
                MainActor.assumeIsolated {
                    #expect(store.overviewTokenSnapshots[.codex] == nil)
                    #expect(!FileManager.default.fileExists(atPath: SharedCostUsage.defaultURL(directory: exports).path))
                }
                published()
            }
            await store.refreshTokenUsage(.codex, force: false, homeDirectory: env.root, exportDirectory: exports)
        }

        #expect(store.tokenError(for: .codex) == nil)
        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 700)
        #expect(store.overviewTokenSnapshots[.codex]?.sessionTokens == 700)
        #expect(store.overviewTokenSnapshots[.codex]?.historyDays == 30)
        #expect(store.overviewTokenSnapshots[.codex]?.last30DaysTokens == 750)
        #expect(store.makeUsageExport(now: now).codex?.todayTokens == 700)
        let published = try SharedCostUsage.read(at: SharedCostUsage.defaultURL(directory: exports))
        #expect(published.engines.first?.report.data.reduce(0) { $0 + ($1.totalTokens ?? 0) } == 750)
        let exportURL = exports.appendingPathComponent(AgentMeterUsageExport.filename)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: exportURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let feed = try decoder.decode(AgentMeterUsageExport.self, from: Data(contentsOf: exportURL))
        #expect(feed.codex?.todayTokens == 700)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let roots = try #require(cache.roots)
        #expect(roots.count == 6)
        for home in [main, overflow, managed] {
            #expect(roots[home.appendingPathComponent("sessions").path] != nil)
        }
    }

    @Test(arguments: [1, 30])
    func coldScanTimeoutCoversTodayAndBackfill(hangingDays: Int) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let settings = TokenCostTestSupport.makeCodexOnlySettings(historyDays: 30)
        let store = UsageStore(fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0), settings: settings,
            startupBehavior: .testing, environmentBase: [:])
        store._test_tokenFetchTimeout = 0.02
        var calls: [Int] = []
        store._test_tokenSnapshotLoad = { days in
            calls.append(days)
            if days == hangingDays { try await Task.sleep(for: .seconds(0.2)) }
            return Self.testSnapshot(historyDays: days)
        }
        await store.refreshTokenUsage(.codex, force: true, homeDirectory: env.root, exportDirectory: env.root)
        #expect(store.tokenError(for: .codex)?.contains("timed out") == true)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.overviewTokenSnapshots[.codex] == nil)
        #expect(!FileManager.default.fileExists(atPath: SharedCostUsage.defaultURL(directory: env.root).path))
        if hangingDays == 1 { #expect(calls == [1]) }
        calls = []
        store._test_tokenSnapshotLoad = { days in
            calls.append(days)
            return Self.testSnapshot(historyDays: days)
        }
        await store.refreshTokenUsage(.codex, force: true, homeDirectory: env.root, exportDirectory: env.root)
        #expect(calls == [1, 30])
        #expect(store.tokenError(for: .codex) == nil)
        #expect(store.overviewTokenSnapshots[.codex]?.historyDays == 30)
    }

    @Test func failedBackfillKeepsCachedHistoryThatArrivedMidScan() async throws {
        struct BackfillFailure: Error {}
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let settings = TokenCostTestSupport.makeCodexOnlySettings(historyDays: 30)
        let store = UsageStore(fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0), settings: settings,
            startupBehavior: .testing, environmentBase: [:])
        store._test_tokenSnapshotLoad = { days in
            if days == 1 {
                // The cache hydration task lands full history while today is still scanning.
                store.tokenSnapshots[.codex] = Self.testSnapshot(historyDays: 30)
                return Self.testSnapshot(historyDays: 1)
            }
            throw BackfillFailure()
        }
        await store.refreshTokenUsage(.codex, force: true, homeDirectory: env.root, exportDirectory: env.root)
        #expect(store.tokenSnapshot(for: .codex)?.historyDays == 30)
    }

    @Test func failedBackfillKeepsPriorSharedHistory() async throws {
        struct BackfillFailure: Error {}
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let previous = SharedCostUsage(engines: [.init(provider: .codex, snapshot: Self.testSnapshot(historyDays: 30))])
        let url = SharedCostUsage.defaultURL(directory: env.root)
        try previous.write(to: url)
        let priorData = try Data(contentsOf: url)
        let settings = TokenCostTestSupport.makeCodexOnlySettings(historyDays: 30)
        let store = UsageStore(fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0), settings: settings,
            startupBehavior: .testing, environmentBase: [:])
        store._test_tokenSnapshotLoad = { days in
            if days == 1 { return Self.testSnapshot(historyDays: 1) }
            #expect(store.tokenSnapshot(for: .codex)?.historyDays == 1)
            #expect(store.overviewTokenSnapshots[.codex] == nil)
            #expect(try Data(contentsOf: url) == priorData)
            throw BackfillFailure()
        }
        await store.refreshTokenUsage(.codex, force: true, homeDirectory: env.root, exportDirectory: env.root)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.overviewTokenSnapshots[.codex] == nil)
        #expect(store.tokenError(for: .codex) != nil)
        #expect(try Data(contentsOf: url) == priorData)
    }

    private static func testSnapshot(historyDays: Int) -> CostUsageTokenSnapshot {
        let day = CostUsageScanner.CostUsageDayRange.dayKey(from: Date())
        return .init(sessionTokens: 10, sessionCostUSD: 1, last30DaysTokens: 10, last30DaysCostUSD: 1, historyDays: historyDays,
            daily: [.init(date: day, inputTokens: 10, outputTokens: 0, totalTokens: 10,
                          costUSD: 1, modelsUsed: nil, modelBreakdowns: nil)], updatedAt: Date())
    }

    @Test func ownClaudeCountersHydrateBeforeScanAndFreshResultsReplaceThem() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 11, day: 6)
        let entry = CostUsageDailyReport.Entry(date: "2026-11-06", inputTokens: 42, outputTokens: 0,
            totalTokens: 42, costUSD: 1, modelsUsed: nil, modelBreakdowns: nil,
            accountBreakdowns: [.init(modelName: "slot:2", costUSD: 1, totalTokens: 42)])
        let cached = CostUsageTokenSnapshot(sessionTokens: 42, sessionCostUSD: 1,
            last30DaysTokens: 42, last30DaysCostUSD: 1, daily: [entry], updatedAt: day)
        try SharedCostUsage(engines: [.init(provider: .claude, snapshot: cached)], generatedAt: day)
            .write(to: SharedCostUsage.defaultURL(directory: env.root))
        let settings = TokenCostTestSupport.makeCodexOnlySettings(historyDays: 1)
        settings.setProviderEnabled(provider: .codex, metadata: ProviderRegistry.shared.metadata[.codex]!, enabled: false)
        settings.setProviderEnabled(provider: .claude, metadata: ProviderRegistry.shared.metadata[.claude]!, enabled: true)
        let store = UsageStore(fetcher: UsageFetcher(), browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings, startupBehavior: .testing, environmentBase: [:])
        try await confirmation("Hydration updates an already open pool") { changed in
            withObservationTracking {
                _ = store.menuObservationToken
            } onChange: { changed() }
            store.hydrateCachedTokenSnapshots(now: day, directory: env.root)
            for _ in 0..<100 where store.cachedOwnCostSources.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let sources = store.allAccountsUsageSources(now: day)
        #expect(sources.count == 1)
        #expect(sources.first?.usage.engine == "claude")
        #expect(sources.first?.stale == false)
        #expect(sources.first?.usage.report.data.first?.accountBreakdowns?.first?.modelName == "slot:2")
        #expect(store.overviewTokenSnapshots.isEmpty)
        store.overviewTokenSnapshots[.claude] = .init(sessionTokens: 84, sessionCostUSD: 2,
            last30DaysTokens: 84, last30DaysCostUSD: 2,
            daily: [.init(date: "2026-11-06", inputTokens: 84, outputTokens: 0,
                          totalTokens: 84, costUSD: 2, modelsUsed: nil, modelBreakdowns: nil)], updatedAt: day)
        #expect(store.allAccountsUsageSources(now: day).count == 1)
        #expect(store.allAccountsUsageSources(now: day).first?.usage.report.data.first?.totalTokens == 84)
        settings.setProviderEnabled(provider: .claude, metadata: ProviderRegistry.shared.metadata[.claude]!, enabled: false)
        #expect(store.allAccountsUsageSources(now: day).isEmpty)
    }

    @Test func ownClaudeCountersKeepAgeAndRejectWrongUser() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = Date()
        let old = now.addingTimeInterval(-SharedCostUsage.maxAge - 1)
        let snapshot = CostUsageTokenSnapshot(sessionTokens: 42, sessionCostUSD: 1,
            last30DaysTokens: 42, last30DaysCostUSD: 1, daily: [], updatedAt: old)
        let url = SharedCostUsage.defaultURL(directory: env.root)
        try SharedCostUsage(engines: [.init(provider: .claude, snapshot: snapshot)], generatedAt: now).write(to: url)
        #expect(UsageStore.readOwnCostSources(directory: env.root, now: now).first?.stale == true)
        try SharedCostUsage(user: "invented-other-user", engines: [.init(provider: .claude, snapshot: snapshot)])
            .write(to: url)
        #expect(UsageStore.readOwnCostSources(directory: env.root, now: now).isEmpty)
    }

    @Test
    func `cached codex token hydration populates startup token snapshot`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            scannerOptions: options)

        let settings = TokenCostTestSupport.makeCodexOnlySettings(historyDays: 1)
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: options),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        await store.hydrateCachedTokenSnapshots(now: day, codexHomePaths: [env.codexHomeRoot.path])?.value

        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 42)
        #expect(store.tokenSnapshot(for: .codex)?.daily.map(\.date) == ["2026-04-08"])
        #expect(store.tokenError(for: .codex) == nil)
    }

    @Test
    func `cached codex token hydration preserves local history with a managed login`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 8)
        try Self.writeCodexSessionFile(
            homeRoot: env.codexHomeRoot,
            env: env,
            day: day,
            filename: "cached.jsonl",
            tokens: 42)

        let managedHome = env.root.appendingPathComponent("managed-codex-homes/invented")
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.codexAdditionalSessionsRoots = [managedHome.appendingPathComponent("sessions")]
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            historyDays: 1,
            scannerOptions: options)

        let settings = TokenCostTestSupport.makeCodexOnlySettings(historyDays: 1)
        let managedAccount = ManagedCodexAccount(
            id: UUID(),
            email: "invented@example.invalid",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        settings._test_activeManagedCodexAccount = managedAccount
        settings.codexActiveSource = .managedAccount(id: managedAccount.id)
        defer { settings._test_activeManagedCodexAccount = nil }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            costUsageFetcher: CostUsageFetcher(scannerOptions: options),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        await store.hydrateCachedTokenSnapshots(now: day, codexHomePaths: [env.codexHomeRoot.path, managedHome.path])?.value

        #expect(store.tokenSnapshot(for: .codex)?.sessionTokens == 42)
        #expect(store.tokenSnapshot(for: .codex)?.daily.map(\.date) == ["2026-04-08"])
        #expect(store.tokenError(for: .codex) == nil)
    }

    private static func writeCodexSessionFile(
        homeRoot: URL,
        env: CostUsageTestEnvironment,
        day: Date,
        filename: String,
        tokens: Int) throws
    {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dir = homeRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = "openai/gpt-5.4"
        let url = dir.appendingPathComponent(filename, isDirectory: false)
        try env.jsonl([
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: day),
                "payload": ["model": model],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": tokens,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]).write(to: url, atomically: true, encoding: .utf8)
    }
}

@MainActor
enum TokenCostTestSupport {
    static func makeCodexOnlySettings(historyDays: Int) -> SettingsStore {
        let suite = "UsageStoreCachedTokenHydrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings._test_managedCodexAccountStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = true
        settings.costUsageHistoryDays = historyDays
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
        return settings
    }
}
