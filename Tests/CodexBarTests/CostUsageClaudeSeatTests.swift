import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeSeatTests {
    @Test func discoversSeatProjects() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let seat = home.appendingPathComponent(".claude-swap-backup/sessions/work-1/projects")
        try FileManager.default.createDirectory(at: seat, withIntermediateDirectories: true)
        let roots = CostUsageScanner.defaultClaudeProjectsRoots(options: .init(), home: home, environment: [:])
        let rootPaths = roots.map { $0.resolvingSymlinksInPath().path }
        #expect(rootPaths.contains(seat.resolvingSymlinksInPath().path))
        #expect(rootPaths.contains(home.appendingPathComponent(".claude/projects").resolvingSymlinksInPath().path))
        let configured = home.appendingPathComponent("custom")
        let configuredRoots = CostUsageScanner.defaultClaudeProjectsRoots(
            options: .init(), home: home, environment: ["CLAUDE_CONFIG_DIR": configured.path])
        let configuredPaths = configuredRoots.map { $0.resolvingSymlinksInPath().path }
        #expect(configuredPaths.contains(configured.appendingPathComponent("projects").resolvingSymlinksInPath().path))
        #expect(configuredPaths.contains(seat.resolvingSymlinksInPath().path))
        #expect(CostUsageScanner.defaultClaudeProjectsRoots(
            options: .init(claudeProjectsRoots: [configured]), home: home, environment: [:]) == [configured])
    }

    @Test(arguments: ["request", "message", "file", "distinctRequests"])
    func duplicateRootsCountOnce(identity: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = root.appendingPathComponent("live/projects")
        let seat = root.appendingPathComponent("seat/projects")
        for directory in [live, seat] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let now = Date()
        var row: [String: Any] = [
            "type": "assistant", "sessionId": "test-session",
            "timestamp": ISO8601DateFormatter().string(from: now),
            "message": ["id": "test-message", "model": "claude-sonnet-4-20250514",
                        "usage": ["input_tokens": 10, "output_tokens": 5]],
        ]
        if identity == "request" || identity == "distinctRequests" { row["request_id"] = "test-request" }
        if identity == "file", var message = row["message"] as? [String: Any] {
            message.removeValue(forKey: "id")
            row["message"] = message
        }
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        // The scanner's fast filter expects compact JSON.
        data.append(0x0A)
        try data.write(to: live.appendingPathComponent("session.jsonl"))
        // Copies can lose the request ID while retaining session/message identity.
        row.removeValue(forKey: "request_id")
        if identity == "distinctRequests" { row["request_id"] = "other-request" }
        var copy = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        copy.append(0x0A)
        if identity != "file" { try copy.write(to: seat.appendingPathComponent("copy.jsonl")) }
        try FileManager.default.linkItem(
            at: live.appendingPathComponent("session.jsonl"), to: seat.appendingPathComponent("hardlink.jsonl"))
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [live, seat], cacheRoot: root.appendingPathComponent("cache"))
        options.refreshMinIntervalSeconds = 0
        for _ in 0..<2 {
            let report = CostUsageScanner.loadDailyReport(
                provider: .claude, since: now, until: now, now: now, options: options)
            #expect(report.data.reduce(0) { $0 + ($1.totalTokens ?? 0) } == (identity == "distinctRequests" ? 30 : 15))
            #expect(report.data.count == 1)
        }
    }
}
