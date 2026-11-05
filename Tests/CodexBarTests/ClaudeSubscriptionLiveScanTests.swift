import Foundation
import Testing
@testable import CodexBarCore

/// Opt-in check against this user's real Claude logs: AGENTMETER_LIVE_SCAN=1 swift test --filter LiveScan.
/// Prints only account keys, token counts and the unattributed share. Uses a throwaway cache.
struct ClaudeSubscriptionLiveScanTests {
    private static func hasAttributedUsage(_ totals: [String: Int]) -> Bool {
        totals.contains { $0.key != "unknown" && $0.value > 0 }
    }

    @Test
    func `zero attributed share fails the live scan criterion`() {
        #expect(!Self.hasAttributedUsage([:]))
        #expect(!Self.hasAttributedUsage(["unknown": 100]))
        #expect(!Self.hasAttributedUsage(["unknown": 100, "slot:1": 0]))
        #expect(Self.hasAttributedUsage(["unknown": 100, "slot:1": 1]))
    }

    @Test
    func `live logs attribute usage to accounts`() throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_LIVE_SCAN"] == "1" else { return }
        var options = CostUsageScanner.Options()
        options.cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-live-\(UUID().uuidString)")
        options.forceRescan = true
        let now = Date()
        let report = try CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: #require(Calendar.current.date(byAdding: .day, value: -29, to: now)),
            until: now, now: now, options: options)
        var totals: [String: Int] = [:]
        for entry in report.data {
            for account in entry.accountBreakdowns ?? [] {
                totals[account.modelName, default: 0] += account.totalTokens ?? 0
            }
        }
        let all = max(1, totals.values.reduce(0, +))
        let keys = ClaudeSwapUsage.accountKeys()
        let named = Dictionary(uniqueKeysWithValues: keys.flatMap { number, list in list.map { ($0, number) } })
        for (key, tokens) in totals.sorted(by: { $0.value > $1.value }) {
            let slot = named[key].map { "slot \($0)" } ?? "unmatched"
            print("LIVE \(key.prefix(12)) \(slot) tokens=\(tokens) share=\(tokens * 100 / all)%")
        }
        print("LIVE total=\(all) days=\(report.data.count) summary=\(report.summary?.totalTokens ?? 0)")
        #expect(totals.values.reduce(0, +) == (report.summary?.totalTokens ?? 0))
        #expect(Self.hasAttributedUsage(totals), "Live logs must contain some attributed usage")
    }
}

struct ClaudeSwapLiveFeedTests {
    @Test
    func `live claude-swap feed parses with the trimmed environment`() async throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_LIVE_SCAN"] == "1" else { return }
        let accounts = try #require(try await ClaudeSwapUsage.fetch())
        for account in accounts {
            print("LIVEFEED \(account.accountID ?? "?") \(account.status) " +
                "\(account.windows.map { "\($0.id)=\(Int($0.usedPercent ?? -1))" }.joined(separator: " ")) " +
                "| \(account.lastError ?? "fresh")")
        }
        #expect(!accounts.isEmpty)
    }

    @Test
    func `child environment drops everything but the basics`() {
        let env = ClaudeSwapUsage.childEnvironment([
            "PATH": "/bin",
            "HOME": "/h",
            "OPENAI_API_KEY": "x",
            "GH_TOKEN": "y",
        ])
        #expect(env == ["PATH": "/bin", "HOME": "/h"])
    }
}
