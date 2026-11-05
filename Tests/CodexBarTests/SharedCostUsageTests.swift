import Foundation
import Testing
@testable import CodexBarCore

struct SharedCostUsageTests {
    private let now = Date(timeIntervalSince1970: 1_793_577_600)

    private func snapshot(at date: Date, day: String = "2026-11-02") -> CostUsageTokenSnapshot {
        .init(sessionTokens: 100, sessionCostUSD: 2, last30DaysTokens: 100, last30DaysCostUSD: 2,
              daily: [.init(date: day, inputTokens: 10, outputTokens: 20, cacheReadTokens: 30,
                            cacheCreationTokens: 40, totalTokens: 100, requestCount: 1, costUSD: 2,
                            modelsUsed: ["test-model"], modelBreakdowns: [
                                .init(modelName: "test-model", costUSD: 2, totalTokens: 100),
                            ])], updatedAt: date)
    }

    @Test func sharedDirectoryPermissionsAreExplicitAndRepairRestrictiveMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try SharedCostUsage.prepareDirectory(directory, shared: true)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o1777)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try SharedCostUsage.prepareDirectory(directory, shared: true)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o1777)
    }

    @Test func ignoresFilesNamingAnotherOwnerOrUnknownUser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for user in [NSUserName(), "root", "agentmeter-nonexistent-user"] {
            try SharedCostUsage(user: user, engines: [
                .init(provider: .codex, snapshot: self.snapshot(at: self.now)),
            ], generatedAt: self.now).write(to: SharedCostUsage.defaultURL(user: user, directory: directory))
        }
        let sources = SharedCostUsage.importedSources(directory: directory, ownUser: "other", now: self.now)
        #expect(sources.count == 1)
        #expect(sources.first?.user == NSUserName())
    }

    @Test func roundTripAndAtomicReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = SharedCostUsage.defaultURL(user: NSUserName(), directory: directory)
        let aggregate = SharedCostUsage(user: NSUserName(), engines: [
            .init(provider: .claude, snapshot: self.snapshot(at: self.now)),
            .init(provider: .codex, snapshot: self.snapshot(at: self.now)),
        ], generatedAt: self.now)
        try aggregate.write(to: url)
        try aggregate.write(to: url)
        let decoded = try SharedCostUsage.read(at: url)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.user == NSUserName())
        #expect(decoded.engines[0].report.data[0].cacheCreationTokens == 40)
        #expect(decoded.engines[0].report.data[0].requestCount == 1)
        #expect(decoded.engines[0].report.data[0].modelBreakdowns?.first?.totalTokens == 100)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(json.keys) == ["schemaVersion", "generatedAt", "user", "engines"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o644)
    }

    @Test func excludesOwnUserUnknownSchemaAndMalformedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for user in ["work", NSUserName(), "future"] {
            try SharedCostUsage(user: user, engines: [
                .init(provider: .claude, snapshot: self.snapshot(at: self.now)),
            ], generatedAt: self.now).write(to: SharedCostUsage.defaultURL(user: user, directory: directory))
        }
        let future = SharedCostUsage.defaultURL(user: "future", directory: directory)
        let json = try String(contentsOf: future, encoding: .utf8).replacingOccurrences(
            of: "\"schemaVersion\":1", with: "\"schemaVersion\":99")
        try Data(json.utf8).write(to: future)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("usage-bad.json"))
        let sources = SharedCostUsage.importedSources(directory: directory, ownUser: "work", now: self.now)
        #expect(sources.count == 1)
        #expect(sources.first?.user == NSUserName())
    }

    @Test func staleSourcesRemainVisibleButDoNotContribute() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = self.now.addingTimeInterval(-SharedCostUsage.maxAge - 1)
        try SharedCostUsage(user: NSUserName(), engines: [
            .init(provider: .claude, snapshot: self.snapshot(at: old)),
            .init(provider: .codex, snapshot: self.snapshot(at: self.now)),
        ], generatedAt: self.now).write(to: SharedCostUsage.defaultURL(user: NSUserName(), directory: directory))
        let sources = SharedCostUsage.importedSources(directory: directory, ownUser: "work", now: self.now)
        #expect(sources.count == 2)
        #expect(sources[0].stale)
        #expect(!sources[1].stale)
        #expect(SharedCostUsage.mergedReport(sources: sources, now: self.now).summary?.totalTokens == 100)
        let allStale = SharedCostUsage.importedSources(
            directory: directory, ownUser: "work", now: self.now.addingTimeInterval(SharedCostUsage.maxAge + 1))
        #expect(allStale.allSatisfy { $0.stale })
        #expect(SharedCostUsage.mergedReport(sources: allStale, now: self.now).data.isEmpty)
    }

    @Test func mergesEnginesAndUsersWithinThirtyDays() {
        let sources = ["work", "personal"].flatMap { user in
            [UsageProvider.claude, .codex].map {
                SharedCostUsage.Source(user: user, usage: .init(provider: $0, snapshot: self.snapshot(at: self.now)),
                                       stale: false)
            }
        }
        let report = SharedCostUsage.mergedReport(sources: sources, now: self.now)
        #expect(report.summary?.totalTokens == 400)
        #expect(report.summary?.totalCostUSD == 8)
        #expect(report.summary?.cacheReadTokens == 120)
        #expect(report.summary?.cacheCreationTokens == 160)
        #expect(report.data.first?.requestCount == 4)
        let old = SharedCostUsage.Source(
            user: "old", usage: .init(provider: .claude, snapshot: self.snapshot(at: self.now, day: "2026-09-01")),
            stale: false)
        #expect(SharedCostUsage.mergedReport(sources: [old], now: self.now).data.isEmpty)
    }

    @Test func publishingDropsDisabledEngines() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exchange = SharedCostUsageExchange()
        _ = try await exchange.publish(provider: .claude, snapshot: self.snapshot(at: self.now),
                                       directory: directory, now: self.now)
        _ = try await exchange.publish(provider: .codex, snapshot: self.snapshot(at: self.now),
                                       directory: directory, now: self.now, enabledProviders: [.codex])
        let aggregate = try SharedCostUsage.read(at: SharedCostUsage.defaultURL(directory: directory))
        #expect(aggregate.engines.map(\.engine) == ["codex"])
    }

    @Test func publishingPreservesOtherEngineFreshness() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let exchange = SharedCostUsageExchange()
        let old = self.now.addingTimeInterval(-SharedCostUsage.maxAge - 1)
        _ = try await exchange.publish(provider: .claude, snapshot: self.snapshot(at: old),
                                       user: NSUserName(), directory: directory, now: old)
        _ = try await exchange.publish(provider: .codex, snapshot: self.snapshot(at: self.now),
                                       user: NSUserName(), directory: directory, now: self.now)
        let sources = SharedCostUsage.importedSources(directory: directory, ownUser: "work", now: self.now)
        #expect(sources.count == 2)
        #expect(sources.first { $0.usage.engine == "claude" }?.stale == true)
        #expect(sources.first { $0.usage.engine == "codex" }?.stale == false)
    }
}
