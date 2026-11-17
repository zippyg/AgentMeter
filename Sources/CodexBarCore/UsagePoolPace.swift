import Foundation

extension UsagePoolForecast {
    /// Signed fraction of capacity: positive is ahead, negative is behind steady use.
    public struct PacePosition: Sendable {
        public struct Contribution: Sendable {
            public let accountID: String
            public let displayName: String
            public let deltaPoints: Double
            public let capacity: Double
            public let estimated: Bool
        }

        public let delta: Double?
        public let contributions: [Contribution]
        public let excludedAccountIDs: [String]
        public var driver: Contribution? {
            Dictionary(grouping: self.contributions, by: \.accountID).values.map { group in
                let size = group.reduce(0) { $0 + $1.capacity }
                return Contribution(
                    accountID: group[0].accountID,
                    displayName: group[0].displayName,
                    deltaPoints: group.reduce(0) { $0 + $1.deltaPoints * $1.capacity } / size,
                    capacity: size, estimated: group.contains(where: \.estimated))
            }.sorted { $0.accountID < $1.accountID }.max {
                abs($0.deltaPoints * $0.capacity) < abs($1.deltaPoints * $1.capacity)
            }
        }
    }

    /// Steady means used percent equals the elapsed fraction of each login's current window.
    /// Banked Codex resets are extra capacity, not usage, so they never move pace.
    /// Unreadable logins count from their last reading, marked estimated: before their recorded top-up
    /// they keep the last reported usage, after it they count as full (nothing used since the top-up).
    /// Only logins with no weekly reading or clock at all are excluded, never treated as on pace.
    public static func pacePosition(results: [Result], now: Date) -> PacePosition {
        var values: [PacePosition.Contribution] = []
        var excluded: [String] = []
        for result in results {
            guard result.assumptions.pace != nil else { continue }
            let pool = self.accountContributions(result.accounts, scenarios: result.assumptions.scenarios, now: now)
            values += pool.values
            excluded += pool.excluded
        }
        let capacity = values.reduce(0) { $0 + $1.capacity * 100 }
        return PacePosition(
            delta: capacity > 0 ? values.reduce(0) { $0 + $1.capacity * $1.deltaPoints } / capacity : nil,
            contributions: values, excludedAccountIDs: excluded)
    }

    /// Pool pace from readings and clocks alone, with no demand estimate. The gauge uses this for both
    /// providers, so last-reading logins count even when no login is readable and the forecast cannot run.
    public static func poolPacePosition(accounts: [Account], scenarios: [String: Scenario] = [:], now: Date) -> PacePosition {
        let pool = self.accountContributions(accounts, scenarios: scenarios, now: now)
        let capacity = pool.values.reduce(0) { $0 + $1.capacity * 100 }
        return PacePosition(
            delta: capacity > 0 ? pool.values.reduce(0) { $0 + $1.capacity * $1.deltaPoints } / capacity : nil,
            contributions: pool.values, excludedAccountIDs: pool.excluded)
    }

    private static func accountContributions(
        _ accounts: [Account], scenarios: [String: Scenario], now: Date) -> (values: [PacePosition.Contribution], excluded: [String])
    {
        var values: [PacePosition.Contribution] = []
        var excluded: [String] = []
        for account in accounts {
            let unreadable = account.refusedSince != nil
            let scenario = scenarios[account.id] ?? self.defaultScenario(for: account, now: now)
            guard let window = account.weekly, let reset = window.resetsAt, unreadable || scenario != .dead else {
                excluded.append(account.id)
                continue
            }
            let duration = Double(window.windowMinutes ?? 10080) * 60
            guard duration > 0 else { excluded.append(account.id); continue }
            let remaining = reset.timeIntervalSince(now)
            let nextReset = remaining > 0 ? reset : reset.addingTimeInterval(
                (floor(-remaining / duration) + 1) * duration)
            let ideal = 100 * min(1, max(0, 1 - nextReset.timeIntervalSince(now) / duration))
            let used: Double = if reset <= now {
                0
            } else if !unreadable, scenario == .fullAfterPassedTopUp {
                0
            } else {
                window.usedPercent
            }
            values.append(.init(
                accountID: account.id, displayName: account.displayName,
                deltaPoints: used - ideal, capacity: account.capacity,
                estimated: unreadable || account.sizeEstimated || scenario != .measured))
        }
        return (values, excluded)
    }
}
