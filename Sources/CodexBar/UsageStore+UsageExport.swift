import CodexBarCore
import Foundation

/// `agentmeter-usage.json`: This Mac's token and cost analytics for other local tools. Limits stay
/// in `agentmeter-summary.json`; this file holds the 30-day totals the Claude and Codex tabs show.
/// Daily counters and display names only, written private (0600) like the summary.
struct AgentMeterUsageExport: Codable, Equatable {
    struct Row: Codable, Equatable {
        let label: String
        let tokens: Int
        let costUSD: Double

        private enum CodingKeys: String, CodingKey {
            case label, tokens, costUSD
        }

        func encode(to encoder: any Encoder) throws {
            let sensitive = self.label.contains("@")
                || self.label.range(
                    of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
                    options: [.regularExpression, .caseInsensitive]) != nil
                || AgentMeterSnapshotSecurity.containsSensitiveMaterial(Data(self.label.utf8))
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sensitive ? "Redacted" : self.label, forKey: .label)
            try container.encode(self.tokens, forKey: .tokens)
            try container.encode(self.costUSD, forKey: .costUSD)
        }
    }

    struct Scope: Codable, Equatable {
        let tokens: Int
        let costUSD: Double
        let todayTokens: Int
        let todayCostUSD: Double
        let byUser: [Row]
        let bySubscription: [Row]
        let topModels: [Row]
        let tokenTypes: [Row]
        /// Oldest first, one value per day, summed across users.
        let dailyTokens: [Int]

        init(_ model: AllAccountsDashboardModel) {
            func rows(_ rows: [AllAccountsDashboardModel.Row]) -> [Row] {
                rows.map { Row(label: $0.label, tokens: $0.tokens, costUSD: $0.cost) }
            }
            self.tokens = model.tokens
            self.costUSD = model.cost
            self.todayTokens = model.todayTokens
            self.todayCostUSD = model.todayCost
            self.byUser = rows(model.sources.filter { !$0.id.hasPrefix("failed-") })
            self.bySubscription = rows(model.subscriptions)
            self.topModels = rows(model.models)
            self.tokenTypes = rows(model.tokenTypes)
            self.dailyTokens = model.days.map { $0.values.reduce(0, +) }
        }
    }

    static let schemaVersion = 1
    static let filename = "agentmeter-usage.json"

    let schemaVersion: Int
    let generatedAt: Date
    let windowDays: Int
    let all: Scope?
    let claude: Scope?
    let codex: Scope?

    static func defaultURL() -> URL {
        AgentMeterSnapshotStore.defaultURL().deletingLastPathComponent()
            .appendingPathComponent(self.filename, isDirectory: false)
    }

    func write(to url: URL = Self.defaultURL()) throws {
        try AgentMeterFileSecurity.ensurePrivateDirectory(url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        guard !AgentMeterSnapshotSecurity.containsSensitiveMaterial(data) else {
            throw AgentMeterSnapshotStoreError.sensitiveMaterialDetected
        }
        try data.write(to: url, options: [.atomic])
        try AgentMeterFileSecurity.applyPrivateFilePermissions(url)
    }
}

enum AgentMeterUsageExportWriter {
    private static let queue = DispatchQueue(label: "com.zain.agentmeter.usage-export", qos: .utility)

    static func enqueue(_ write: @escaping @Sendable () -> Void) {
        self.queue.async(execute: write)
    }
}

extension UsageStore {
    /// This user's own snapshots plus every other user's shared daily counters.
    func allAccountsUsageSources(now: Date) -> [SharedCostUsage.Source] {
        [UsageProvider.claude, .codex].compactMap { provider -> SharedCostUsage.Source? in
            guard let snapshot = self.overviewTokenSnapshots[provider] else { return nil }
            return .init(
                user: NSUserName(),
                usage: .init(provider: provider, snapshot: snapshot),
                stale: now.timeIntervalSince(snapshot.updatedAt) > SharedCostUsage.maxAge)
        } + self.importedCostSources
    }

    /// Attribution key -> subscription name ("work-1", "Personal"), from the claude-swap cards.
    func claudeSubscriptionLabels() -> [String: String] {
        let keys = ClaudeSwapUsage.accountKeys()
        var labels: [String: String] = [:]
        for account in self.claudeSwapAccounts ?? [] {
            guard let number = account.accountID.flatMap({ Int($0.replacingOccurrences(of: "cswap:", with: "")) })
            else { continue }
            let hint = account.accountDisplayHint ?? account.accountLabel ?? "Account \(number)"
            let label = hint.components(separatedBy: " · ").last ?? hint
            for key in keys[number] ?? ["slot:\(number)"] {
                labels[key] = label
            }
        }
        return labels
    }

    func makeUsageExport(now: Date = Date()) -> AgentMeterUsageExport {
        let sources = self.allAccountsUsageSources(now: now)
        let labels = self.claudeSubscriptionLabels()
        let keyGroups = Array(ClaudeSwapUsage.accountKeys().values)
        func scope(_ scope: AllAccountsDashboardModel.Scope) -> AgentMeterUsageExport.Scope? {
            AllAccountsDashboardModel.make(
                sources: sources, scope: scope, exportFailures: self.sharedCostExportFailures,
                accountLabels: labels, accountKeyGroups: keyGroups, now: now).map(AgentMeterUsageExport.Scope.init)
        }
        return AgentMeterUsageExport(
            schemaVersion: AgentMeterUsageExport.schemaVersion, generatedAt: now, windowDays: 30,
            all: scope(.overview), claude: scope(.claude), codex: scope(.codex))
    }

    func persistUsageExport() {
        guard self.settings.costUsageEnabled else { return }
        let export = self.makeUsageExport()
        AgentMeterUsageExportWriter.enqueue {
            try? export.write()
        }
    }
}
