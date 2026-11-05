import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeSubscriptionAttributionTests {
    private func assistant(_ id: String, at time: String, input: Int) -> [String: Any] {
        [
            "message": [
                "model": "claude-fable-5", "id": id, "type": "message", "role": "assistant",
                "usage": ["input_tokens": input, "output_tokens": 1],
            ],
            "requestId": "req-" + id, "type": "assistant", "timestamp": time, "sessionId": "s1",
        ]
    }

    @Test
    func `rows follow the latest account marker in the file`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let first = "11111111-2222-3333-4444-555555555555"
        let second = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/switch.jsonl",
            contents: env.jsonl([
                self.assistant("m0", at: "2026-06-09T11:00:00.000Z", input: 7),
                ["type": "bridge-session", "ownerAccountUuid": first],
                self.assistant("m1", at: "2026-06-09T12:00:00.000Z", input: 10),
                ["type": "history-suppression", "vetoedAgainstAccountUuid": second],
                self.assistant("m2", at: "2026-06-09T12:01:00.000Z", input: 20),
                ["type": "session-owner", "accountUuid": second],
                self.assistant("m3", at: "2026-06-09T12:02:00.000Z", input: 30),
            ]))

        let rows = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all).rows.sorted { ($0.messageId ?? "") < ($1.messageId ?? "") }

        let firstKey = CostUsageScanner.claudeAccountKey(uuid: first)
        let secondKey = CostUsageScanner.claudeAccountKey(uuid: second)
        #expect(rows.map(\.account) == [nil, firstKey, firstKey, secondKey])
        #expect(firstKey.hasPrefix("acct:") && !firstKey.contains("1111"))
        #expect(secondKey == CostUsageScanner.claudeAccountKey(uuid: second.lowercased()))
    }

    @Test
    func `an incremental parse inherits the account from earlier in the file`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let fileURL = try env.writeClaudeProjectFile(
            relativePath: "project-a/tail.jsonl",
            contents: env.jsonl([self.assistant("m9", at: "2026-06-09T12:00:00.000Z", input: 5)]))
        let rows = CostUsageScanner.parseClaudeFile(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all)
        #expect(rows.rows.first?.account == nil)
        let inherited = try CostUsageScanner.parseClaudeFileCancellable(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            providerFilter: .all,
            initialAccount: "acct:abc")
        #expect(inherited.rows.first?.account == "acct:abc")
    }

    @Test
    func `incremental scans preserve final marker independent of row order`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 6, day: 9)
        let first = "11111111-2222-3333-4444-555555555555"
        let second = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let file = try env.writeClaudeProjectFile(relativePath: "p/tail.jsonl", contents: env.jsonl([
            ["type": "session-owner", "accountUuid": first],
            self.assistant("z", at: "2026-06-09T12:00:00Z", input: 5),
            ["type": "session-owner", "accountUuid": second],
            self.assistant("a", at: "2026-06-09T12:01:00Z", input: 10),
        ]))
        var options = CostUsageScanner.Options(claudeProjectsRoots: [env.claudeProjectsRoot], cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        func scan(full: Bool = false) -> CostUsageDailyReport {
            var scanOptions = options
            scanOptions.forceRescan = full
            return CostUsageScanner.loadDailyReport(
                provider: .claude, since: day, until: day, now: day, options: scanOptions)
        }
        func append(_ objects: [Any]) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(env.jsonl(objects).utf8))
        }
        func encoded(_ report: CostUsageDailyReport) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(report.data.map(SharedCostUsage.Day.init))
        }
        _ = scan()
        try append([self.assistant("b", at: "2026-06-09T12:02:00Z", input: 20)])
        let incremental = scan()
        #expect(try encoded(incremental) == encoded(scan(full: true)))
        try append([["type": "session-owner", "accountUuid": "BBBBBBBB-1111-2222-3333-444444444444"]])
        _ = scan()
        try append([self.assistant("c", at: "2026-06-09T12:03:00Z", input: 30)])
        let afterTrailingMarker = scan()
        #expect(try encoded(afterTrailingMarker) == encoded(scan(full: true)))
        try append([
            ["type": "session-owner", "accountUuid": second],
            self.assistant("d", at: "2026-06-09T12:04:00Z", input: 40),
        ])
        let afterMarkerAndUsage = scan()
        #expect(try encoded(afterMarkerAndUsage) == encoded(scan(full: true)))
    }

    @Test
    func `a claude-swap home names its slot`() {
        let url = URL(fileURLWithPath:
            "/Users/x/.claude-swap-backup/sessions/3-someone_example.com/projects/p/a.jsonl")
        #expect(CostUsageScanner.claudeSwapSlotAccount(fileURL: url) == "slot:3")
        #expect(CostUsageScanner.claudeSwapSlotAccount(
            fileURL: URL(fileURLWithPath: "/Users/x/.claude/projects/p/a.jsonl")) == nil)
    }

    @Test
    func `account totals survive the shared export and merge`() throws {
        let entry = CostUsageDailyReport.Entry(
            date: "2026-06-09", inputTokens: 10, outputTokens: 1, totalTokens: 11, costUSD: 1,
            modelsUsed: ["m"], modelBreakdowns: [.init(modelName: "m", costUSD: 1, totalTokens: 11)],
            accountBreakdowns: [.init(modelName: "slot:2", costUSD: 1, totalTokens: 11)])
        let day = SharedCostUsage.Day(entry)
        let encoded = try JSONEncoder().encode(day)
        let decoded = try JSONDecoder().decode(SharedCostUsage.Day.self, from: encoded)
        #expect(decoded.entry.accountBreakdowns?.first?.modelName == "slot:2")
        let merged = CostUsageDailyReport.merged([
            CostUsageDailyReport(data: [decoded.entry], summary: nil),
            CostUsageDailyReport(data: [decoded.entry], summary: nil),
        ])
        #expect(merged.data.first?.accountBreakdowns?.first?.totalTokens == 22)
        // A file written before the field existed still decodes.
        let legacy = Data(#"{"date":"2026-06-09","tokens":5,"models":[]}"#.utf8)
        #expect(try JSONDecoder().decode(SharedCostUsage.Day.self, from: legacy).accounts == nil)
    }

    @Test
    func `stale claude-swap rows say why and drop windows that have since reset`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        let feed: [String: Any] = [
            "schemaVersion": 1, "activeAccountNumber": 1,
            "accounts": [[
                "number": 3, "usageStatus": "unavailable", "usage": NSNull(),
                "usageError": "http-429",
                "usageRetryAt": iso.string(from: now.addingTimeInterval(3600)),
                "lastGoodFetchedAt": iso.string(from: now.addingTimeInterval(-3 * 86400)),
                "lastGoodUsage": [
                    "fiveHour": ["pct": 40, "resetsAt": iso.string(from: now.addingTimeInterval(-86400))],
                    "sevenDay": ["pct": 95, "resetsAt": iso.string(from: now.addingTimeInterval(86400))],
                    "scoped": [
                        [
                            "name": "Sonnet",
                            "pct": 90,
                            "expectedPct": 40,
                            "resetsAt": iso.string(from: now.addingTimeInterval(-1)),
                        ],
                        [
                            "name": "Opus",
                            "pct": 20,
                            "expectedPct": 10,
                            "resetsAt": iso.string(from: now.addingTimeInterval(86400)),
                        ],
                    ],
                ],
            ]],
        ]
        let snapshot = try #require(try ClaudeSwapUsage.parse(
            JSONSerialization.data(withJSONObject: feed), now: now).first)
        let session = try #require(snapshot.windows.first { $0.id == "session" })
        let weekly = try #require(snapshot.windows.first { $0.id == "weekly" })
        #expect(session.usedPercent == 0 && session.resetsAt == nil)
        let passed = RateWindow(
            usedPercent: 0,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: session.resetDescription)
        #expect(UsageFormatter.resetLine(for: passed, style: .countdown, now: now) == "Reset since last reading")
        #expect(weekly.usedPercent == 95)
        let sonnet = try #require(snapshot.windows.first { $0.id == "model:sonnet" })
        #expect(sonnet.usedPercent == 0)
        #expect(sonnet.resetsAt == nil)
        #expect(sonnet.resetDescription == "Reset since last reading")
        #expect(sonnet.feedPace == nil)
        let opus = try #require(snapshot.windows.first { $0.id == "model:opus" })
        #expect(opus.usedPercent == 20 && opus.resetsAt != nil && opus.feedPace != nil)
        let reason = try #require(snapshot.lastError)
        #expect(reason.hasPrefix("Last reading 3d ago; Anthropic is rate-limiting the usage check; retry "))
        #expect(!reason.contains("http-429"))
    }
}

struct ClaudeSwapTimelineTests {
    @Test
    func `rotated switch logs extend only known history`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let directory = env.root.appendingPathComponent(".claude-swap-backup")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (suffix, line) in [
            ("", "2026-09-19 15:49:03,920 - INFO - Switched from account 2 to 4"),
            (".1", "2026-09-19 15:44:12,197 - INFO - Switched from account 1 to 2"),
            (".3", "2026-09-19 15:36:42,000 - INFO - Switched from account 5 to 1"),
        ] {
            try line.write(
                to: directory.appendingPathComponent("claude-swap.log" + suffix),
                atomically: true,
                encoding: .utf8)
        }
        let timeline = CostUsageScanner.claudeSwapTimeline(home: env.root)
        #expect(timeline.map(\.slot) == [1, 2, 4])
        #expect(CostUsageScanner.claudeSwapSlot(at: 0, timeline: timeline) == nil)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("claude-swap.log"))
        #expect(CostUsageScanner.claudeSwapTimeline(home: env.root).map(\.slot) == [1, 2])
    }

    @Test
    func `switch log gives the active slot at any moment`() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let timeline = CostUsageScanner.parseClaudeSwapTimeline("""
        2026-09-19 15:36:42,000 - INFO - Backed up account 1
        2026-09-19 15:44:12,197 - INFO - Switched from account 1 to 2
        garbage line
        2026-09-19 15:49:03,920 - INFO - Switched from account 2 to 4
        """, timeZone: utc)
        func ms(_ text: String) -> Int64 {
            let f = ISO8601DateFormatter()
            return Int64(f.date(from: text)!.timeIntervalSince1970 * 1000)
        }
        #expect(CostUsageScanner.claudeSwapSlot(at: ms("2026-09-19T10:00:00Z"), timeline: timeline) == nil)
        #expect(CostUsageScanner.claudeSwapSlot(at: ms("2026-09-19T15:45:00Z"), timeline: timeline) == "slot:2")
        #expect(CostUsageScanner.claudeSwapSlot(at: ms("2026-09-20T00:00:00Z"), timeline: timeline) == "slot:4")
        #expect(CostUsageScanner.claudeSwapSlot(at: 0, timeline: []) == nil)
    }
}
