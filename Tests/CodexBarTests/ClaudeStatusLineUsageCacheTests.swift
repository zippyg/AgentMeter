import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeStatusLineUsageCacheTests {
    @Test
    func `fresh status line cache maps usage windows`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeStatusLineUsageCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("usage.json")
        let data = Data("""
        {
          "five_hour": {"utilization": 34.0, "resets_at": "2026-06-15T12:00:00.000000+00:00"},
          "seven_day": {"utilization": 31.0, "resets_at": "2026-06-16T12:00:00.000000+00:00"},
          "seven_day_sonnet": {"utilization": 7.0, "resets_at": "2026-06-17T12:00:00.000000+00:00"},
          "extra_usage": {"is_enabled": false}
        }
        """.utf8)
        FileManager.default.createFile(atPath: cache.path, contents: data)
        let now = Date(timeIntervalSince1970: 1_781_520_000)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: cache.path)

        let snapshot = try ClaudeStatusLineUsageCache.load(
            environment: [
                "AGENTMETER_CLAUDE_STATUSLINE_CACHE": cache.path,
            ],
            now: now)

        #expect(snapshot.primary.usedPercent == 34)
        #expect(snapshot.secondary?.usedPercent == 31)
        #expect(snapshot.opus?.usedPercent == 7)
        #expect(snapshot.loginMethod == "Claude status-line cache")
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `stale status line cache is not fresh`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeStatusLineUsageCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("usage.json")
        FileManager.default.createFile(
            atPath: cache.path,
            contents: Data("{\"five_hour\":{\"utilization\":1}}".utf8))
        let now = Date(timeIntervalSince1970: 1_781_520_000)
        let modifiedAt = now.addingTimeInterval(-(ClaudeStatusLineUsageCache.maxAge + 1))
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: cache.path)

        #expect(!ClaudeStatusLineUsageCache.isFresh(
            environment: [
                "AGENTMETER_CLAUDE_STATUSLINE_CACHE": cache.path,
            ],
            now: now))
    }
}
