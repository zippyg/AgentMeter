import Foundation
import Testing
@testable import CodexBarCore
@testable import AgentMeter

@MainActor
struct CostUsageOverflowTests {
    @Test func sharedConfigLoaderHonorsEnvironmentAndExplicitURL() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let config = env.root.appendingPathComponent("codex-overflow.json")
        let home = env.root.appendingPathComponent("invented-overflow")
        let environment = ["CODEX_OVERFLOW_CONFIG": config.path]
        #expect(CodexOverflowConfiguration.configurationURL(environment: [:]) == CodexOverflowConfiguration.defaultURL)
        #expect(CodexOverflowConfiguration.load(environment: environment) == nil)
        try JSONSerialization.data(withJSONObject: ["home": home.path, "account_email": "invented@example.invalid"])
            .write(to: config)
        #expect(CodexOverflowConfiguration.configurationURL(environment: environment) == config)
        #expect(CodexOverflowConfiguration.load(environment: environment)?.homeURL.path == home.path)
        #expect(CodexOverflowConfiguration.load(environment: environment)?.accountEmail == "invented@example.invalid")
        #expect(CodexOverflowConfiguration.load(from: config,
            environment: ["CODEX_OVERFLOW_CONFIG": env.root.appendingPathComponent("missing.json").path])?.homeURL.path == home.path)
    }

    @Test func configuredOverflowCountsOnceInAnalyticsAndFeedUntilConfigRemoval() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 11, day: 10)
        let settings = TokenCostTestSupport.makeCodexOnlySettings(historyDays: 1)
        let managed = ManagedCodexAccount(id: UUID(), email: "invented@example.invalid",
            managedHomePath: env.root.appendingPathComponent("managed-codex-homes/invented").path,
            createdAt: 1, updatedAt: 1, lastAuthenticatedAt: 1)
        try FileManager.default.createDirectory(atPath: managed.managedHomePath, withIntermediateDirectories: true)
        settings._test_activeManagedCodexAccount = managed
        settings._test_activeManagedCodexRemoteHomePath = managed.managedHomePath
        defer {
            settings._test_activeManagedCodexAccount = nil
            settings._test_activeManagedCodexRemoteHomePath = nil
        }
        let store = UsageStore(fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0), settings: settings,
            startupBehavior: .testing, environmentBase: [:])
        let systemScope = store.tokenCostScope(for: .codex)
        settings.codexActiveSource = .managedAccount(id: managed.id)
        let scope = store.tokenCostScope(for: .codex)
        #expect(scope == systemScope)
        let overflow = env.root.appendingPathComponent(".codex-invented-overflow")
        let sessions = overflow.appendingPathComponent("sessions/2026/11/10")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let configURL = env.root.appendingPathComponent("codex-overflow.json")
        func session(_ id: String, input: Int, cached: Int, output: Int) throws -> String {
            try env.jsonl([
                ["type": "session_meta", "payload": ["id": id]],
                ["type": "turn_context", "payload": ["model": "gpt-5"]],
                ["type": "event_msg", "timestamp": env.isoString(for: day), "payload": [
                    "type": "token_count", "info": ["total_token_usage": [
                        "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                    ]],
                ]],
            ])
        }
        let original = try env.writeCodexSessionFile(day: day, filename: "main.jsonl",
            contents: session("invented-main", input: 100, cached: 20, output: 10))
        let systemSessions = env.root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: systemSessions, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original, to: systemSessions.appendingPathComponent("main.jsonl"))
        try FileManager.default.copyItem(at: original, to: sessions.appendingPathComponent("copied.jsonl"))
        try session("invented-overflow", input: 200, cached: 50, output: 30)
            .write(to: sessions.appendingPathComponent("overflow.jsonl"), atomically: true, encoding: .utf8)
        let managedSessions = URL(fileURLWithPath: managed.managedHomePath).appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: managedSessions, withIntermediateDirectories: true)
        try session("invented-managed", input: 400, cached: 100, output: 40)
            .write(to: managedSessions.appendingPathComponent("managed.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: original, to: managedSessions.appendingPathComponent("copied.jsonl"))
        var options = CostUsageScanner.Options(codexSessionsRoot: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        options.codexOverflowConfigURL = configURL
        let piOptions = PiSessionCostScanner.Options(piSessionsRoot: env.piSessionsRoot, cacheRoot: env.cacheRoot)
        func scan(historyDays: Int = 1) async throws -> CostUsageTokenSnapshot {
            let homes = try settings.codexCostHomePaths(environment: [
                "CODEX_HOME": env.codexHomeRoot.path, "CODEX_OVERFLOW_CONFIG": configURL.path,
            ], homeDirectory: env.root)
            #expect(homes.contains(managed.managedHomePath))
            return try await CostUsageFetcher.loadTokenSnapshot(provider: .codex, now: day,
                historyDays: historyDays, refreshPricing: false, scannerOptions: options,
                piScannerOptions: piOptions, codexHomePaths: homes)
        }
        #expect(try await scan().last30DaysTokens == 550)
        for (until, enabled) in [("2026-12-10", true), ("2026-01-01", true), ("invalid", false)] {
            try JSONSerialization.data(withJSONObject: ["home": overflow.path, "until": until, "enabled": enabled])
                .write(to: configURL)
            for _ in 0..<2 {
                let snapshot = try await scan()
                let mainRoots = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).roots
                let overview = try await scan(historyDays: 30)
                #expect(CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).roots == mainRoots)
                store.overviewTokenSnapshots[.codex] = overview
                let publishedSource = try #require(store.allAccountsUsageSources(now: day).first)
                #expect(snapshot.last30DaysTokens == overview.last30DaysTokens)
                #expect(snapshot.last30DaysTokens == 780)
                #expect(snapshot.daily.first?.inputTokens == 700)
                #expect(snapshot.daily.first?.cacheReadTokens == 170)
                #expect(snapshot.daily.first?.outputTokens == 80)
                let shared = SharedCostUsage(user: "invented-local", engines: [publishedSource.usage])
                let feed = env.root.appendingPathComponent("shared/usage-invented-local.json")
                try shared.write(to: feed)
                let read = try SharedCostUsage.read(at: feed)
                let source = SharedCostUsage.Source(user: read.user, usage: try #require(read.engines.first), stale: false)
                let model = try #require(AllAccountsDashboardModel.make(sources: [source], scope: .codex, now: day))
                let export = AgentMeterUsageExport.Scope(model)
                #expect(model.tokens == 780 && export.tokens == 780)
                #expect(export.dailyTokens.count == 30 && export.dailyTokens.reduce(0, +) == 780)
                #expect(export.tokenTypes.reduce(0) { $0 + $1.tokens } == 780)
                #expect(export.costUSD == snapshot.last30DaysCostUSD)
            }
        }
        try FileManager.default.removeItem(at: configURL)
        #expect(try await scan().last30DaysTokens == 550)
        try Data("invalid".utf8).write(to: configURL)
        #expect(try await scan().last30DaysTokens == 550)
    }

    #if canImport(SQLite3)
    @Test func overflowPriorityCostsRefreshWhenItsTraceDatabaseAppears() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 11, day: 10)
        let overflow = env.root.appendingPathComponent(".codex-invented-overflow")
        let sessions = overflow.appendingPathComponent("sessions/2026/11/10")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let config = env.root.appendingPathComponent("codex-overflow.json")
        try JSONSerialization.data(withJSONObject: ["home": overflow.path, "until": "2020-01-01", "enabled": false])
            .write(to: config)
        let timestamp = env.isoString(for: day)
        let entries: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "invented-priority-session"]],
            ["type": "turn_context", "payload": ["model": "gpt-5.5"]],
            ["type": "event_msg", "timestamp": timestamp,
             "payload": ["type": "task_started", "turn_id": "invented-priority-turn"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": ["type": "token_count", "info": [
                "total_token_usage": ["input_tokens": 100, "cached_input_tokens": 20, "output_tokens": 10],
            ]]],
        ]
        try env.jsonl(entries).write(to: sessions.appendingPathComponent("priority.jsonl"), atomically: true, encoding: .utf8)
        var options = CostUsageScanner.Options(codexSessionsRoot: env.codexSessionsRoot, cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-main.sqlite"))
        options.codexOverflowConfigURL = config
        let standard = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        let standardCost = (80.0 * 5e-6) + (20.0 * 5e-7) + (10.0 * 3e-5)
        #expect(standard.summary?.totalCostUSD == standardCost)
        let database = overflow.appendingPathComponent("logs_2.sqlite")
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: database)
        try CostUsageScannerCodexPriorityTests.insertTestLog(dbURL: database, timestamp: timestamp,
            body: "thread_id=invented-thread turn.id=invented-priority-turn websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        let priority = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day,
            now: day.addingTimeInterval(1), options: options)
        let priorityCost = (80.0 * 1.25e-5) + (20.0 * 1.25e-6) + (10.0 * 7.5e-5)
        #expect(priority.summary?.totalCostUSD == priorityCost)
        #expect(priority.data.first?.modelBreakdowns?.first?.priorityTokens == 110)
        try FileManager.default.removeItem(at: config)
        let retired = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day,
            now: day.addingTimeInterval(2), options: options)
        #expect(retired.data.isEmpty)
    }
    #endif

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AGENTMETER_COST_USAGE_PROBE"] == "1"))
    func realMacTodayReadOnlyProbe() async throws {
        let temporary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TMPDIR"]))
            .appendingPathComponent("agentmeter-cost-probe-\(UUID().uuidString)")
        let env = try CostUsageTestEnvironment(root: temporary)
        defer { env.cleanup() }
        let now = Date()
        let window = ProcessInfo.processInfo.environment["AGENTMETER_COST_USAGE_PROBE_WINDOW"] ?? "today"
        let days = window == "today" ? 1 : 30
        let since = Calendar.current.date(byAdding: .day, value: -(days - 1), to: now)!
        let todayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: now)
        let home = FileManager.default.homeDirectoryForCurrentUser
        var homes = [home.appendingPathComponent(".codex")]
        homes.append(try #require(CodexOverflowConfiguration.load()).homeURL)
        let metadata = FileManagedCodexAccountStore.defaultURL()
        if FileManager.default.fileExists(atPath: metadata.path) {
            let accounts = try JSONDecoder().decode(ManagedCodexAccountSet.self, from: Data(contentsOf: metadata))
            homes += accounts.accounts.map { URL(fileURLWithPath: $0.managedHomePath) }
        }
        homes = Array(Set(homes)).sorted { $0.path < $1.path }
        try #require(homes.allSatisfy { $0.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") })
        var options = CostUsageScanner.Options(codexSessionsRoot: homes[0].appendingPathComponent("sessions"),
            cacheRoot: env.cacheRoot, codexTraceDatabaseURL: env.root.appendingPathComponent("no-trace.sqlite"))
        options.codexAdditionalSessionsRoots = homes.dropFirst().map { $0.appendingPathComponent("sessions") }
        options.codexOverflowConfigURL = env.root.appendingPathComponent("no-overflow.json")
        let scanOptions = options
        let report = try await CostUsageScanExecutor.run { checkCancellation in
            try CostUsageScanner.loadDailyReportCancellable(provider: .codex,
                since: since, until: now, now: now, options: scanOptions, checkCancellation: checkCancellation)
        }
        let tokens = report.data.filter { $0.date == todayKey }.reduce(0) { $0 + ($1.totalTokens ?? 0) }
        print("COST_USAGE_PROBE window=\(window) today_tokens=\(tokens)")
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        for root in (cache.roots ?? [:]).keys.sorted() {
            let files = cache.files.filter { $0.key.hasPrefix(root + "/") }
            let today = files.values.reduce(0) { total, file in
                total + (file.days[todayKey]?.values.reduce(0) { $0 + $1[0] + $1[2] } ?? 0)
            }
            print("COST_USAGE_PROBE_ROOT window=\(window) root=\(root) files=\(files.count) today_tokens=\(today)")
        }
        #expect(tokens > 0)
    }

    @Test func sourceDetectionFindsOverflowWithExpiredDisabledConfig() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let config = env.root.appendingPathComponent("codex-overflow.json")
        let home = env.root.appendingPathComponent(".codex-invented-overflow")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sessions.appendingPathComponent("session.jsonl"))
        let environment = ["CODEX_HOME": env.codexHomeRoot.path, "CODEX_OVERFLOW_CONFIG": config.path,
                           "CLAUDE_CONFIG_DIR": env.claudeProjectsRoot.path]
        #expect(!SettingsStore.hasAnyTokenCostUsageSources(env: environment))
        try JSONSerialization.data(withJSONObject: ["home": home.path, "until": "2020-01-01", "enabled": false])
            .write(to: config)
        #expect(SettingsStore.hasAnyTokenCostUsageSources(env: environment))
        try FileManager.default.removeItem(at: config)
        #expect(!SettingsStore.hasAnyTokenCostUsageSources(env: environment))
    }
}
