import Foundation
import Testing
@testable import AgentMeter
@testable import CodexBarCore

@MainActor
struct UsagePoolAnalyticsCoverageTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")!

    static func source(_ engine: String, _ entries: [CostUsageDailyReport.Entry]) throws -> SharedCostUsage.Source {
        let json: [String: Any] = [
            "engine": engine, "generatedAt": "2026-11-07T11:00:00Z",
            "daily": entries.map { entry -> [String: Any] in
                var day: [String: Any] = ["date": entry.date, "models": (entry.modelBreakdowns ?? []).map { model in
                    var row: [String: Any] = ["name": model.modelName, "tokens": model.totalTokens ?? 0]
                    if let cost = model.costUSD { row["costUSD"] = cost }
                    return row
                }]
                day["inputTokens"] = entry.inputTokens
                day["outputTokens"] = entry.outputTokens
                day["cacheReadTokens"] = entry.cacheReadTokens
                day["cacheWriteTokens"] = entry.cacheCreationTokens
                day["tokens"] = entry.totalTokens
                day["costUSD"] = entry.costUSD
                return day.compactMapValues { $0 }
            },
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let engineData = try decoder.decode(
            SharedCostUsage.Engine.self,
            from: JSONSerialization.data(withJSONObject: json))
        return .init(user: NSUserName(), usage: engineData, stale: false)
    }

    @Test func tokenSplitTakesCodexCachedInputOutOfInputAndFlagsUnpricedModels() throws {
        let claude = try Self.source("claude", [.init(
            date: "2026-11-07", inputTokens: 10, outputTokens: 40, cacheReadTokens: 900, cacheCreationTokens: 50,
            totalTokens: 1000, costUSD: 5, modelsUsed: nil,
            modelBreakdowns: [.init(modelName: "claude-invented", costUSD: 5, totalTokens: 1000)])])
        // Codex input includes its cached part: 1,000 input of which 800 cached, plus 20 output.
        let codex = try Self.source("codex", [.init(
            date: "2026-11-07", inputTokens: 1000, outputTokens: 20, cacheReadTokens: 800,
            totalTokens: 1020, costUSD: 1, modelsUsed: nil,
            modelBreakdowns: [
                .init(modelName: "gpt-invented", costUSD: 1, totalTokens: 1000),
                .init(modelName: "review-invented", costUSD: nil, totalTokens: 20),
            ])])
        let model = try #require(AllAccountsDashboardModel.make(sources: [claude, codex], now: Self.now))
        let split = Dictionary(uniqueKeysWithValues: model.tokenTypes.map { ($0.id, $0.tokens) })
        #expect(split == ["input": 210, "read": 1700, "write": 50, "output": 60])
        // The split adds back up to the processed-token headline.
        #expect(split.values.reduce(0, +) == model.tokens)
        let rate = try #require(model.cacheHitRate)
        #expect(abs(rate - 1700.0 / 1960.0) < 0.000001)
        #expect(model.unpriced.map(\.label) == ["review-invented"])
        #expect(model.unpricedTokens == 20)

        let priced = try #require(AllAccountsDashboardModel.make(sources: [claude], now: Self.now))
        #expect(priced.unpriced.isEmpty)
    }

    @Test func noPromptTokensMeansNoCacheHitRate() throws {
        let empty = try Self.source("claude", [])
        let model = try #require(AllAccountsDashboardModel.make(sources: [empty], now: Self.now))
        #expect(model.cacheHitRate == nil)
    }

    @Test func scanStatusCountsReadCompressedPendingUnreadAndSkippedLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/11/06", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let scannedAt = Self.now.addingTimeInterval(-600)
        func file(_ name: String, modified: Date) throws -> String {
            let url = day.appendingPathComponent(name)
            try Data("{}\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url.path
        }
        let read = try file("a.jsonl", modified: scannedAt.addingTimeInterval(-60))
        let compressed = try file("b.jsonl.zst", modified: scannedAt.addingTimeInterval(-60))
        _ = try file("c.jsonl", modified: scannedAt.addingTimeInterval(60))
        _ = try file("d.jsonl.zst", modified: scannedAt.addingTimeInterval(-60))
        _ = try file("e.jsonl.gz", modified: scannedAt.addingTimeInterval(-60))
        _ = try file("old.jsonl", modified: Self.now.addingTimeInterval(-40 * 86400))
        _ = try file("notes.txt", modified: scannedAt)
        let record = CostUsageScanStatus.Record(
            roots: [root],
            files: [read: Self.cachedEntry(read), compressed: Self.cachedEntry(compressed)],
            scannedAt: scannedAt)
        let since = Self.now.addingTimeInterval(-30 * 86400)

        let codex = CostUsageScanStatus.compare(.codex, record: record, since: since)
        #expect(codex == .init(
            provider: .codex,
            found: 4,
            read: 2,
            compressedRead: 1,
            pending: 1,
            unread: 1,
            skipped: 1,
            scannedAt: scannedAt))
        #expect(UsagePoolPresentation.scanStatusText(codex)
            == "Codex logs, 30 days: 4 found, 2 read (1 compressed), 1 changed since the last scan, 1 not counted, "
            + "1 skipped, format not read")

        // Claude never writes compressed logs, so a .jsonl.zst there is skipped, not unread.
        let claude = CostUsageScanStatus.compare(.claude, record: record, since: since)
        #expect(claude.found == 2)
        #expect(claude.skipped == 3)
    }

    /// The cache's view of a log as it is on disk now.
    static func cachedEntry(_ path: String, parsedBytes: Int64? = nil) -> CostUsageScanStatus.CachedFile {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return .init(
            mtimeUnixMs: Int64(modified.timeIntervalSince1970 * 1000), size: size, parsedBytes: parsedBytes ?? size)
    }

    @Test func appendedCachedLogsArePendingAndUnreadableOnesAreNotCounted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scannedAt = Self.now.addingTimeInterval(-600)
        let appended = root.appendingPathComponent("appended.jsonl")
        let unreadable = root.appendingPathComponent("unreadable.jsonl")
        for url in [appended, unreadable] {
            try Data("{}\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: scannedAt.addingTimeInterval(-60)], ofItemAtPath: url.path)
        }
        let appendedEntry = Self.cachedEntry(appended.path)
        // Cached as empty although it has bytes, as the scanner does when a log cannot be opened.
        let unreadableEntry = Self.cachedEntry(unreadable.path, parsedBytes: 0)
        // Appended before the scan's clock but after this file's own cached reading.
        let handle = try FileHandle(forWritingTo: appended)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: scannedAt.addingTimeInterval(-30)], ofItemAtPath: appended.path)

        let status = CostUsageScanStatus.compare(
            .claude,
            record: .init(
                roots: [root],
                files: [appended.path: appendedEntry, unreadable.path: unreadableEntry],
                scannedAt: scannedAt),
            since: Self.now.addingTimeInterval(-30 * 86400))
        #expect(status.found == 2)
        #expect(status.read == 0)
        #expect(status.pending == 1)
        #expect(status.unread == 1)
    }

    @Test func piCodexInputIsTakenOutOnceAfterTheFetcherMerge() throws {
        // Codex counts its cached input inside input; Pi reports it apart.
        let codex = CostUsageDailyReport(data: [.init(
            date: "2026-11-07", inputTokens: 100, outputTokens: 10, cacheReadTokens: 0,
            totalTokens: 110, costUSD: 1, modelsUsed: nil,
            modelBreakdowns: [.init(modelName: "gpt-invented", costUSD: 1, totalTokens: 110)])], summary: nil)
        let pi = CostUsageDailyReport(data: [.init(
            date: "2026-11-07", inputTokens: 40, outputTokens: 5, cacheReadTokens: 10,
            totalTokens: 55, costUSD: 0.5, modelsUsed: nil,
            modelBreakdowns: [.init(modelName: "pi-invented", costUSD: 0.5, totalTokens: 55)])], summary: nil)
        let merged = CostUsageDailyReport.merged([codex, CostUsageFetcher.inCodexInputConvention(pi)])
        let source = try Self.source("codex", merged.data)
        let model = try #require(AllAccountsDashboardModel.make(sources: [source], now: Self.now))
        let split = Dictionary(uniqueKeysWithValues: model.tokenTypes.map { ($0.id, $0.tokens) })
        #expect(model.tokens == 165)
        #expect(split == ["input": 140, "read": 10, "write": 0, "output": 15])
        #expect(split.values.reduce(0, +) == model.tokens)
        let rate = try #require(model.cacheHitRate)
        #expect(abs(rate - 10.0 / 150.0) < 0.000001)
    }

    @Test func partiallyUnpricedModelsStayVisibleAcrossSources() throws {
        func source(_ user: String, cost: Double?) throws -> SharedCostUsage.Source {
            let base = try Self.source("codex", [.init(
                date: "2026-11-07", inputTokens: 50, outputTokens: 0, totalTokens: 50, costUSD: cost,
                modelsUsed: nil, modelBreakdowns: [.init(
                    modelName: "shared-invented",
                    costUSD: cost,
                    totalTokens: 50)])])
            return .init(user: user, usage: base.usage, stale: false)
        }
        // The same model priced in one source and unpriced in the other merges to a priced row.
        let model = try #require(AllAccountsDashboardModel.make(
            sources: [source("user-a", cost: 2), source("user-b", cost: nil)], now: Self.now))
        #expect(model.unpriced.map(\.label) == ["shared-invented"])
        #expect(model.unpricedTokens == 50)
    }
}
