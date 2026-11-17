import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerTests {
    @Test func resumedRolloutsPreserveTodayAcrossScanWindows() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let today = try env.makeLocalNoon(year: 2026, month: 11, day: 11)
        let older = try env.makeLocalNoon(year: 2026, month: 10, day: 22)
        func contents(_ day: Date, total: Int, last: Int) throws -> String {
            try env.jsonl([
                ["type": "session_meta", "payload": ["id": "invented-resumed-session", "timestamp": env.isoString(for: day)]],
                ["type": "turn_context", "payload": ["model": "gpt-5"]],
                ["type": "event_msg", "timestamp": env.isoString(for: day), "payload": [
                    "type": "token_count", "info": [
                        "total_token_usage": ["input_tokens": total, "output_tokens": 0],
                        "last_token_usage": ["input_tokens": last, "output_tokens": 0],
                    ],
                ]],
            ])
        }
        let oldFile = try env.writeCodexSessionFile(day: older, filename: "old.jsonl",
            contents: contents(older, total: 100, last: 100))
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: oldFile.path)
        let resumed = try env.writeCodexSessionFile(day: today, filename: "resumed.jsonl",
            contents: contents(today, total: 150, last: 50))
        let other = env.root.appendingPathComponent("other/sessions")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: resumed, to: other.appendingPathComponent("copy.jsonl"))
        var options = CostUsageScanner.Options(codexSessionsRoot: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        options.codexAdditionalSessionsRoots = [other]
        options.refreshMinIntervalSeconds = 0
        let since = Calendar.current.date(byAdding: .day, value: -29, to: today)!
        for days in [30, 1, 30, 30] {
            let report = CostUsageScanner.loadDailyReport(provider: .codex,
                since: days == 1 ? today : since, until: today, now: today, options: options)
            #expect(report.data.first { $0.date == "2026-11-11" }?.totalTokens == 50)
            if days == 30 { #expect(report.summary?.totalTokens == 150) }
        }
    }

    @Test
    func `codex file metadata detects append truncation and replacement`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-codex-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("session.jsonl")
        try Data("abc".utf8).write(to: fileURL)

        let initial = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(initial.size == 3)
        #expect(initial.fileId != nil)
        let linkURL = root.appendingPathComponent("linked-session.jsonl")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: fileURL)
        let linked = CostUsageScanner.codexFileMetadata(fileURL: linkURL)
        #expect(linked.size == initial.size)
        #expect(linked.fileId == initial.fileId)

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("def".utf8))
        try handle.close()
        let appended = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(appended.size == 6)
        #expect(appended.fileId == initial.fileId)

        let truncateHandle = try FileHandle(forWritingTo: fileURL)
        try truncateHandle.truncate(atOffset: 2)
        try truncateHandle.close()
        let truncated = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(truncated.size == 2)
        #expect(truncated.fileId == initial.fileId)

        try FileManager.default.removeItem(at: fileURL)
        try Data("replacement".utf8).write(to: fileURL)
        let replaced = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(replaced.size == 11)
        #expect(replaced.fileId != initial.fileId)
    }

    @Test
    func `vertex daily report filters claude logs`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)

        let vertexEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "metadata": [
                "provider": "vertexai",
                "projectId": "vertex-project",
                "location": "us-central1",
            ],
            "message": [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 5,
                ],
            ],
        ]
        let claudeEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "metadata": [
                "provider": "anthropic",
            ],
            "message": [
                "model": "claude-sonnet-4-20250514",
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 100,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([vertexEntry, claudeEntry]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .vertexai,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 10)
        #expect(report.data[0].outputTokens == 5)
        #expect(report.data[0].totalTokens == 15)
    }

    @Test
    func `vertex daily report detects by vrtx id prefix`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        // Vertex AI entries have "_vrtx_" in message.id and requestId
        let vertexEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "requestId": "req_vrtx_011CWjK86SWeFuXqZKUtgB1H",
            "message": [
                "id": "msg_vrtx_0154LUXjFVzQGUca3yK2RUeo",
                "model": "claude-opus-4-5-20251101",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 50,
                ],
            ],
        ]
        // Anthropic API entries have regular IDs without "_vrtx_"
        let claudeEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "requestId": "req_011CW7BFSFkbK9qJrV8kiptH",
            "message": [
                "id": "msg_0152zX6DsQYcwH1qiXi4B3y2",
                "model": "claude-opus-4-5-20251101",
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 100,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([vertexEntry, claudeEntry]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        // Vertex AI report should only include entries with _vrtx_ prefix
        let vertexReport = CostUsageScanner.loadDailyReport(
            provider: .vertexai,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(vertexReport.data.count == 1)
        #expect(vertexReport.data[0].inputTokens == 100)
        #expect(vertexReport.data[0].outputTokens == 50)
        #expect(vertexReport.data[0].totalTokens == 150)

        // Claude report with excludeVertexAI should only include non-vrtx entries
        var claudeOptions = options
        claudeOptions.claudeLogProviderFilter = .excludeVertexAI
        let claudeReport = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: claudeOptions)

        #expect(claudeReport.data.count == 1)
        #expect(claudeReport.data[0].inputTokens == 200)
        #expect(claudeReport.data[0].outputTokens == 100)
        #expect(claudeReport.data[0].totalTokens == 300)
    }

    @Test
    func `claude report preserves per-request threshold pricing`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 9)
        let first = env.isoString(for: day)
        let second = env.isoString(for: day.addingTimeInterval(1))
        let model = "claude-sonnet-4-5"
        let firstEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": first,
            "requestId": "req_one",
            "message": [
                "id": "msg_one",
                "model": model,
                "usage": [
                    "input_tokens": 150_000,
                    "output_tokens": 0,
                ],
            ],
        ]
        let secondEntry: [String: Any] = [
            "type": "assistant",
            "timestamp": second,
            "requestId": "req_two",
            "message": [
                "id": "msg_two",
                "model": model,
                "usage": [
                    "input_tokens": 150_000,
                    "output_tokens": 0,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/threshold.jsonl",
            contents: env.jsonl([firstEntry, secondEntry]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        let expectedRequestCost = CostUsagePricing.claudeCostUSD(
            model: model,
            inputTokens: 150_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        let aggregateCost = CostUsagePricing.claudeCostUSD(
            model: model,
            inputTokens: 300_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCacheRoot: env.cacheRoot) ?? 0
        let expectedCost = expectedRequestCost * 2

        #expect(report.data.count == 1)
        #expect(report.data.first?.inputTokens == 300_000)
        #expect(abs((report.data.first?.costUSD ?? 0) - expectedCost) < 0.000001)
        #expect(abs((report.data.first?.costUSD ?? 0) - aggregateCost) > 0.000001)
        #expect(abs((report.data.first?.modelBreakdowns?.first?.costUSD ?? 0) - expectedCost) < 0.000001)
    }

    @Test
    func `claude parses large lines with usage at tail`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 28)
        let iso0 = env.isoString(for: day)
        let largeText = String(repeating: "a", count: 70000)

        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": "claude-sonnet-4-20250514",
                "content": [
                    ["type": "text", "text": largeText],
                ],
                "usage": [
                    "input_tokens": 3714,
                    "output_tokens": 1,
                ],
            ],
        ]
        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/large-line.jsonl",
            contents: env.jsonl([assistant]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 3714)
        #expect(report.data[0].outputTokens == 1)
        #expect(report.data[0].totalTokens == 3715)
    }

    @Test
    func `claude daily report refreshes when file changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let first: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 80,
                ],
            ],
        ]
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([first]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let firstReport = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(firstReport.data.first?.totalTokens == 355)

        let second: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 40,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 20,
                ],
            ],
        ]
        try env.jsonl([first, second]).write(to: fileURL, atomically: true, encoding: .utf8)

        let secondReport = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)
        #expect(secondReport.data.first?.totalTokens == 430)
    }

    /// Codex compresses logs older than about a week to .jsonl.zst. They must count, once, even when an
    /// uncompressed copy of the same session is still around.
    @Test(.enabled(if: CostUsageLogFile.systemZstdPath != nil, "needs the system zstd binary"))
    func `codex daily report reads compressed session logs once`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-session-2026-10-15.jsonl.zst")
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 15)
        let compressed = try env.writeCodexSessionFile(
            day: day, filename: "rollout-2026-10-15T12-00-00-invented-zst-session-0001.jsonl.zst", contents: "")
        try FileManager.default.removeItem(at: compressed)
        try FileManager.default.copyItem(at: fixture, to: compressed)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot, claudeProjectsRoots: nil, cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        // Cumulative totals end at 160 input (40 cached) and 16 output.
        #expect(report.data.map(\.totalTokens) == [176])
        #expect(report.data.first?.modelsUsed == ["gpt-5.5"])

        let plain = Process()
        plain.executableURL = URL(fileURLWithPath: try #require(CostUsageLogFile.systemZstdPath))
        plain.arguments = ["-dcq", "--", fixture.path]
        let pipe = Pipe()
        plain.standardOutput = pipe
        try plain.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        plain.waitUntilExit()
        _ = try env.writeCodexArchivedSessionFile(
            filename: "rollout-2026-10-15T12-00-00-invented-zst-session-0001.jsonl",
            contents: String(decoding: bytes, as: UTF8.self))
        let deduped = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        #expect(deduped.data.map(\.totalTokens) == [176])
    }

    private static func zstd(_ input: Data, arguments: [String] = ["-q", "-c"]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(CostUsageLogFile.systemZstdPath))
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return output
    }

    private static func codexTokenLines(_ totals: [Int], session: String) throws -> [String] {
        let meta = #"{"type":"session_meta","timestamp":"2026-10-15T12:00:00Z","payload":{"id":"\#(session)"}}"#
        let turn = #"{"type":"turn_context","timestamp":"2026-10-15T12:00:01Z","payload":{"model":"gpt-5.5"}}"#
        return [meta, turn] + totals.enumerated().map { index, total in
            #"{"type":"event_msg","timestamp":"2026-10-15T12:00:\#(String(format: "%02d", index + 2))Z","payload":"#
                + #"{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"#
                + #""cached_input_tokens":0,"output_tokens":0},"model":"gpt-5.5"}}}"#
        }
    }

    /// A compressed log whose second frame is cut short decompresses 100 tokens and then fails. That
    /// partial result must not be cached or claim its session, so the healthy 300-token copy counts.
    @Test(.enabled(if: CostUsageLogFile.systemZstdPath != nil, "needs the system zstd binary"))
    func `codex truncated compressed log is not cached and does not hide a healthy copy`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 15)
        let lines = try Self.codexTokenLines([100, 300], session: "invented-truncated-session")
        let first = try Self.zstd(Data((lines[0...2].joined(separator: "\n") + "\n").utf8))
        let second = try Self.zstd(Data((lines[3] + "\n").utf8))
        let compressed = try env.writeCodexSessionFile(
            day: day, filename: "rollout-2026-10-15T12-00-00-invented-truncated-session.jsonl.zst", contents: "")
        try (first + second.prefix(second.count / 2)).write(to: compressed)
        // The healthy copy sits in a later day folder, so the compressed log is scanned first.
        let nextDay = day.addingTimeInterval(86400)
        _ = try env.writeCodexSessionFile(
            day: nextDay, filename: "rollout-2026-10-16T12-00-00-invented-truncated-session.jsonl",
            contents: lines.joined(separator: "\n") + "\n")

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot, claudeProjectsRoots: nil, cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        for _ in 0..<2 {
            let report = CostUsageScanner.loadDailyReport(
                provider: .codex, since: day, until: nextDay, now: nextDay, options: options)
            #expect(report.data.map(\.totalTokens) == [300])
            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            #expect(cache.files[compressed.path] == nil)
        }
    }

    /// Without a working zstd, compressed logs are skipped (missing) or fail to launch (broken path);
    /// either way nothing from them is cached and plain logs still count.
    @Test(.enabled(if: CostUsageLogFile.systemZstdPath != nil, "needs the system zstd binary"))
    func `codex compressed logs are skipped without a working zstd`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 15)
        let compressed = try env.writeCodexSessionFile(
            day: day, filename: "rollout-2026-10-15T12-00-00-invented-zst-only.jsonl.zst", contents: "")
        let zstLines = try Self.codexTokenLines([500], session: "invented-zst-only")
        try Self.zstd(Data((zstLines.joined(separator: "\n") + "\n").utf8)).write(to: compressed)
        _ = try env.writeCodexSessionFile(
            day: day, filename: "rollout-2026-10-15T12-00-00-invented-plain.jsonl",
            contents: try Self.codexTokenLines([40], session: "invented-plain").joined(separator: "\n") + "\n")

        for path in [nil, "/nonexistent/invented/zstd"] as [String?] {
            try? FileManager.default.removeItem(at: env.cacheRoot)
            var options = CostUsageScanner.Options(
                codexSessionsRoot: env.codexSessionsRoot, claudeProjectsRoots: nil, cacheRoot: env.cacheRoot)
            options.refreshMinIntervalSeconds = 0
            let report = CostUsageLogFile.$zstdPath.withValue(path) {
                CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
            }
            #expect(report.data.map(\.totalTokens) == [40], "zstd path \(path ?? "missing")")
            #expect(CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot).files[compressed.path] == nil)
        }
    }

    @Test(.enabled(if: CostUsageLogFile.systemZstdPath != nil, "needs the system zstd binary"))
    func `cancelling mid decompression stops the read`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-zst-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("session.jsonl.zst")
        let line = #"{"type":"event_msg","payload":{"type":"noise"}}"# + "\n"
        try Self.zstd(Data(String(repeating: line, count: 40000).utf8)).write(to: url)
        var checks = 0
        var lines = 0
        #expect(throws: CancellationError.self) {
            try CostUsageJsonl.scan(
                fileURL: url, maxLineBytes: 1024, prefixBytes: 1024,
                checkCancellation: {
                    checks += 1
                    if checks > 2 { throw CancellationError() }
                },
                onLine: { _ in lines += 1 })
        }
        #expect(lines > 0 && lines < 40000)
    }

    @Test
    func `codex incremental parsing uses previous totals`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "openai/gpt-5.2-codex"
        let normalized = CostUsagePricing.normalizeCodexModel(model)
        #expect(normalized == "gpt-5.2-codex")
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
            ],
        ]
        let firstTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                    "model": model,
                ],
            ],
        ]

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "session.jsonl",
            contents: env.jsonl([turnContext, firstTokenCount]))

        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let first = CostUsageScanner.parseCodexFile(fileURL: fileURL, range: range)
        #expect(first.parsedBytes > 0)
        #expect(first.lastTotals?.input == 100)
        #expect(first.lastTotals?.cached == 20)
        #expect(first.lastTotals?.output == 10)

        let secondTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso2,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 160,
                        "cached_input_tokens": 40,
                        "output_tokens": 16,
                    ],
                    "model": model,
                ],
            ],
        ]
        try env.jsonl([turnContext, firstTokenCount, secondTokenCount])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let delta = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: range,
            startOffset: first.parsedBytes,
            initialModel: first.lastModel,
            initialTotals: first.lastTotals)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = delta.days[dayKey]?[normalized] ?? []
        #expect(packed.count >= 3)
        #expect(packed[0] == 60)
        #expect(packed[1] == 20)
        #expect(packed[2] == 6)
    }

    @Test
    func `codex incremental parsing keeps current turn id`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))
        let iso3 = env.isoString(for: day.addingTimeInterval(3))

        let model = "openai/gpt-5.5"
        let turnID = "22222222-2222-2222-2222-222222222222"
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": iso0,
            "payload": [
                "model": model,
            ],
        ]
        let taskStarted: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso1,
            "payload": [
                "type": "task_started",
                "id": turnID,
            ],
        ]
        let firstTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso2,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]

        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "priority-session.jsonl",
            contents: env.jsonl([turnContext, taskStarted, firstTokenCount]))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)

        let first = CostUsageScanner.parseCodexFile(fileURL: fileURL, range: range)
        #expect(first.lastCodexTurnID == turnID)
        #expect(first.rows.map(\.turnID) == [turnID])

        let secondTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": iso3,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 160,
                        "cached_input_tokens": 40,
                        "output_tokens": 16,
                    ],
                ],
            ],
        ]
        try env.jsonl([turnContext, taskStarted, firstTokenCount, secondTokenCount])
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let delta = CostUsageScanner.parseCodexFile(
            fileURL: fileURL,
            range: range,
            startOffset: first.parsedBytes,
            initialModel: first.lastModel,
            initialTotals: first.lastTotals,
            initialCodexTurnID: first.lastCodexTurnID)

        #expect(delta.lastCodexTurnID == turnID)
        #expect(delta.rows.map(\.turnID) == [turnID])
        #expect(delta.rows.first?.input == 60)
        #expect(delta.rows.first?.cached == 20)
        #expect(delta.rows.first?.output == 6)
    }

    @Test
    func `codex fast parser does not trap on overflowing token integers`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let hugeInteger = String(repeating: "9", count: 100)
        let line = """
        {"type":"event_msg","timestamp":"\(
            iso)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(
            hugeInteger),"cached_input_tokens":0,"output_tokens":5},"model":"openai/gpt-5.5"}}}
        """
        let fileURL = try env.writeCodexSessionFile(day: day, filename: "overflow.jsonl", contents: line + "\n")
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)

        let parsed = CostUsageScanner.parseCodexFile(fileURL: fileURL, range: range)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = parsed.days[dayKey]?["gpt-5.5"] ?? []

        #expect(packed.count >= 3)
        #expect(packed[0] == 0)
        #expect(packed[1] == 0)
        #expect(packed[2] == 5)
    }

    @Test
    func `claude incremental parsing reads appended lines only`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let normalized = CostUsagePricing.normalizeClaudeModel(model)
        let first: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 80,
                ],
            ],
        ]
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([first]))

        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let firstParse = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: range,
            providerFilter: .all)
        #expect(firstParse.parsedBytes > 0)

        let second: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 40,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 5,
                    "output_tokens": 20,
                ],
            ],
        ]
        try env.jsonl([first, second]).write(to: fileURL, atomically: true, encoding: .utf8)

        let delta = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: range,
            providerFilter: .all,
            startOffset: firstParse.parsedBytes)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let packed = delta.days[dayKey]?[normalized] ?? []
        #expect(packed.count >= 4)
        #expect(packed[0] == 40)
        #expect(packed[1] == 5)
        #expect(packed[2] == 10)
        #expect(packed[3] == 20)
    }

    @Test
    func `day key from timestamp matches ISO parsing`() {
        let timestamps = [
            "2025-12-20T23:59:59Z",
            "2025-12-20T23:59:59+02:00",
        ]

        for ts in timestamps {
            let expected = CostUsageScanner.dayKeyFromParsedISO(ts)
            let fast = CostUsageScanner.dayKeyFromTimestamp(ts)
            #expect(fast == expected)
        }
    }

    @Test
    func `claude deduplicates streaming chunks`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))
        let iso2 = env.isoString(for: day.addingTimeInterval(2))

        let model = "claude-sonnet-4-20250514"
        let messageId = "msg_01ABC123"
        let requestId = "req_01XYZ789"

        // Streaming emits multiple chunks with same message.id + requestId.
        // Each chunk has cumulative usage, not delta.
        let chunk1: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "requestId": requestId,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 10,
                ],
            ],
        ]
        let chunk2: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "requestId": requestId,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 10,
                ],
            ],
        ]
        let chunk3: [String: Any] = [
            "type": "assistant",
            "timestamp": iso2,
            "requestId": requestId,
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 50,
                    "cache_read_input_tokens": 25,
                    "output_tokens": 10,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([chunk1, chunk2, chunk3]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        // Should only count once, not 3x.
        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 100)
        #expect(report.data[0].cacheCreationTokens == 50)
        #expect(report.data[0].cacheReadTokens == 25)
        #expect(report.data[0].outputTokens == 10)
        #expect(report.data[0].totalTokens == 185)
    }

    @Test
    func `claude counts entries without ids as separate`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"

        // Entries without message.id or requestId should still be counted
        // (fallback for older log formats).
        let entry1: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 50,
                ],
            ],
        ]
        let entry2: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 200,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 100,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([entry1, entry2]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        // Both entries should be counted since no IDs to dedupe.
        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 300)
        #expect(report.data[0].outputTokens == 150)
        #expect(report.data[0].totalTokens == 450)
    }

    @Test
    func `claude counts different request ids separately`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2025, month: 12, day: 20)
        let iso0 = env.isoString(for: day)
        let iso1 = env.isoString(for: day.addingTimeInterval(1))

        let model = "claude-sonnet-4-20250514"
        let messageId = "msg_01ABC123"

        let entry1: [String: Any] = [
            "type": "assistant",
            "timestamp": iso0,
            "requestId": "req_01AAA",
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 5,
                ],
            ],
        ]
        let entry2: [String: Any] = [
            "type": "assistant",
            "timestamp": iso1,
            "requestId": "req_01BBB",
            "message": [
                "id": messageId,
                "model": model,
                "usage": [
                    "input_tokens": 20,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 10,
                ],
            ],
        ]

        _ = try env.writeClaudeProjectFile(
            relativePath: "project-a/session-a.jsonl",
            contents: env.jsonl([entry1, entry2]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: nil,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.data.count == 1)
        #expect(report.data[0].inputTokens == 30)
        #expect(report.data[0].outputTokens == 15)
        #expect(report.data[0].totalTokens == 45)
    }
}

struct CostUsageTestEnvironment {
    let root: URL
    let cacheRoot: URL
    let codexHomeRoot: URL
    let codexSessionsRoot: URL
    let codexArchivedSessionsRoot: URL
    let claudeProjectsRoot: URL
    let piSessionsRoot: URL

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "codexbar-cost-usage-\(UUID().uuidString)", isDirectory: true)) throws
    {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        self.codexHomeRoot = root.appendingPathComponent("codex-home", isDirectory: true)
        self.codexSessionsRoot = self.codexHomeRoot.appendingPathComponent("sessions", isDirectory: true)
        self.codexArchivedSessionsRoot = self.codexHomeRoot
            .appendingPathComponent("archived_sessions", isDirectory: true)
        self.claudeProjectsRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        self.piSessionsRoot = root.appendingPathComponent("pi-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: self.cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.codexSessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.codexArchivedSessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.claudeProjectsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.piSessionsRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: self.root)
    }

    func makeLocalNoon(year: Int, month: Int, day: Int) throws -> Date {
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        comps.minute = 0
        comps.second = 0
        guard let date = comps.date else { throw NSError(domain: "CostUsageTestEnvironment", code: 1) }
        return date
    }

    func isoString(for date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: date)
    }

    func writeCodexSessionFile(day: Date, filename: String, contents: String) throws -> URL {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let y = String(format: "%04d", comps.year ?? 1970)
        let m = String(format: "%02d", comps.month ?? 1)
        let d = String(format: "%02d", comps.day ?? 1)

        let dir = self.codexSessionsRoot
            .appendingPathComponent(y, isDirectory: true)
            .appendingPathComponent(m, isDirectory: true)
            .appendingPathComponent(d, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeClaudeProjectFile(relativePath: String, contents: String) throws -> URL {
        let url = self.claudeProjectsRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writeCodexArchivedSessionFile(filename: String, contents: String) throws -> URL {
        let url = self.codexArchivedSessionsRoot.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func writePiSessionFile(relativePath: String, contents: String) throws -> URL {
        let url = self.piSessionsRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func jsonl(_ objects: [Any]) throws -> String {
        let lines = try objects.map { obj in
            let data = try JSONSerialization.data(withJSONObject: obj)
            guard let text = String(bytes: data, encoding: .utf8) else {
                throw NSError(domain: "CostUsageTestEnvironment", code: 2)
            }
            return text
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
