import Foundation

enum AgentMeterUsageRange: String, CaseIterable, Identifiable, Sendable {
    case currentSession
    case daily
    case weekly
    case all
    case fullTime

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .currentSession:
            "Current session"
        case .daily:
            "Daily"
        case .weekly:
            "Weekly"
        case .all:
            "All known"
        case .fullTime:
            "Full time"
        }
    }

    var shortTitle: String {
        switch self {
        case .currentSession:
            "Session"
        case .daily:
            "Daily"
        case .weekly:
            "Weekly"
        case .all:
            "All"
        case .fullTime:
            "Lifetime"
        }
    }
}

struct AgentMeterRangeUsage: Equatable, Sendable {
    var title: String
    var tokens: Int?
    var costUSD: Double?
    var usedPercent: Double?
    var window: AgentMeterPhoneUsageWindow?
}

struct AgentMeterRangeTotals: Equatable, Sendable {
    var tokens: Int?
    var costUSD: Double?
    var peakUsage: AgentMeterPhoneInsights.ProviderUsage?
}

struct AgentMeterPaceProjection: Equatable, Sendable {
    var projectedAt: Date
    var resetAt: Date
    var markerPercent: Double
    var emptiesBeforeReset: Bool

    var label: String {
        if self.emptiesBeforeReset {
            "Projected empty \(AgentMeterFormat.relative(self.projectedAt))"
        } else {
            "Pace survives reset"
        }
    }
}

struct AgentMeterPhoneInsights: Equatable, Sendable {
    struct ProviderUsage: Equatable, Sendable {
        var providerID: String
        var displayName: String
        var usedPercent: Double
    }

    struct Reset: Equatable, Sendable {
        var providerID: String
        var displayName: String
        var windowTitle: String
        var resetsAt: Date?
        var resetDescription: String?
    }

    var providerCount: Int
    var attentionProviderCount: Int
    var totalSessionTokens: Int?
    var totalSessionCostUSD: Double?
    var currencyCode: String
    var peakSessionUsage: ProviderUsage?
    var nextReset: Reset?
    var combinedDailyUsage: [AgentMeterPhoneDailyUsagePoint]
    var totalsByRange: [AgentMeterUsageRange: AgentMeterRangeTotals]

    init(snapshot: AgentMeterPhoneSnapshot) {
        self.providerCount = snapshot.providers.count
        self.attentionProviderCount = snapshot.providers.filter { $0.status != .ok }.count
        self.currencyCode = snapshot.providers.compactMap(\.tokenUsage?.currencyCode).first ?? "USD"

        let sessionTokens = snapshot.providers.compactMap(\.tokenUsage?.sessionTokens)
        self.totalSessionTokens = sessionTokens.isEmpty ? nil : sessionTokens.reduce(0, +)

        let sessionCosts = snapshot.providers.compactMap(\.tokenUsage?.sessionCostUSD)
        self.totalSessionCostUSD = sessionCosts.isEmpty ? nil : sessionCosts.reduce(0, +)

        self.peakSessionUsage = snapshot.providers
            .compactMap { provider -> ProviderUsage? in
                guard let usedPercent = provider.primaryWindow?.usedPercent else { return nil }
                return ProviderUsage(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    usedPercent: usedPercent)
            }
            .max { $0.usedPercent < $1.usedPercent }

        self.nextReset = snapshot.providers
            .flatMap { provider in
                provider.windows.compactMap { window -> Reset? in
                    guard window.resetsAt != nil || window.resetDescription != nil else { return nil }
                    return Reset(
                        providerID: provider.id,
                        displayName: provider.displayName,
                        windowTitle: window.title,
                        resetsAt: window.resetsAt,
                        resetDescription: window.resetDescription)
                }
            }
            .sorted { lhs, rhs in
                switch (lhs.resetsAt, rhs.resetsAt) {
                case let (lhsDate?, rhsDate?):
                    lhsDate < rhsDate
                case (_?, nil):
                    true
                case (nil, _?):
                    false
                case (nil, nil):
                    lhs.displayName < rhs.displayName
                }
            }
            .first

        self.combinedDailyUsage = Self.aggregateDailyUsage(snapshot.providers.flatMap(\.dailyUsage))
        self.totalsByRange = Dictionary(uniqueKeysWithValues: AgentMeterUsageRange.allCases.map { range in
            let usages = snapshot.providers.map { $0.usage(for: range, generatedAt: snapshot.generatedAt) }
            let tokens = usages.compactMap(\.tokens)
            let costs = usages.compactMap(\.costUSD)
            let peaks = zip(snapshot.providers, usages).compactMap { provider, usage -> ProviderUsage? in
                guard let usedPercent = usage.usedPercent else { return nil }
                return ProviderUsage(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    usedPercent: usedPercent)
            }
            return (range, AgentMeterRangeTotals(
                tokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
                costUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                peakUsage: peaks.max { $0.usedPercent < $1.usedPercent }))
        })
    }

    func totals(for range: AgentMeterUsageRange) -> AgentMeterRangeTotals {
        self.totalsByRange[range] ?? AgentMeterRangeTotals(tokens: nil, costUSD: nil, peakUsage: nil)
    }

    private static func aggregateDailyUsage(
        _ points: [AgentMeterPhoneDailyUsagePoint])
        -> [AgentMeterPhoneDailyUsagePoint]
    {
        let grouped = Dictionary(grouping: points, by: \.dayKey)
        return grouped.keys.sorted().map { dayKey in
            let dayPoints = grouped[dayKey] ?? []
            let tokens = dayPoints.compactMap(\.totalTokens)
            let costs = dayPoints.compactMap(\.costUSD)
            return AgentMeterPhoneDailyUsagePoint(
                dayKey: dayKey,
                totalTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
                costUSD: costs.isEmpty ? nil : costs.reduce(0, +))
        }
    }
}

extension AgentMeterPhoneProvider {
    func usage(for range: AgentMeterUsageRange, generatedAt: Date) -> AgentMeterRangeUsage {
        switch range {
        case .currentSession:
            let window = self.primaryWindow
            return AgentMeterRangeUsage(
                title: range.title,
                tokens: self.tokenUsage?.sessionTokens,
                costUSD: self.tokenUsage?.sessionCostUSD,
                usedPercent: window?.usedPercent,
                window: window)
        case .daily:
            let latestDay = self.dailyUsage.sorted { $0.dayKey < $1.dayKey }.last
            let window = self.window(id: "daily")
            return AgentMeterRangeUsage(
                title: range.title,
                tokens: latestDay?.totalTokens,
                costUSD: latestDay?.costUSD,
                usedPercent: window?.usedPercent,
                window: window)
        case .weekly:
            let latestSeven = self.dailyUsage.sorted { $0.dayKey < $1.dayKey }.suffix(7)
            let tokens = latestSeven.compactMap(\.totalTokens)
            let costs = latestSeven.compactMap(\.costUSD)
            let window = self.weeklyWindow
            return AgentMeterRangeUsage(
                title: range.title,
                tokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
                costUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                usedPercent: window?.usedPercent,
                window: window)
        case .all:
            let window = self.window(id: "all") ?? self.window(id: "last30Days")
            return AgentMeterRangeUsage(
                title: range.title,
                tokens: self.tokenUsage?.last30DaysTokens,
                costUSD: self.tokenUsage?.last30DaysCostUSD,
                usedPercent: window?.usedPercent,
                window: window)
        case .fullTime:
            let window = self.window(id: "fullTime") ?? self.window(id: "lifetime")
            return AgentMeterRangeUsage(
                title: range.title,
                tokens: nil,
                costUSD: nil,
                usedPercent: window?.usedPercent,
                window: window)
        }
    }
}

extension AgentMeterPhoneUsageWindow {
    func paceProjection(generatedAt: Date) -> AgentMeterPaceProjection? {
        guard let usedPercent, usedPercent > 0,
              let resetsAt,
              let windowMinutes,
              windowMinutes > 0
        else {
            return nil
        }

        let windowDuration = TimeInterval(windowMinutes * 60)
        let start = resetsAt.addingTimeInterval(-windowDuration)
        let elapsed = generatedAt.timeIntervalSince(start)
        guard elapsed > 0 else { return nil }

        let projectedDuration = elapsed / (usedPercent / 100)
        guard projectedDuration.isFinite, projectedDuration > 0 else { return nil }

        let projectedAt = start.addingTimeInterval(projectedDuration)
        return AgentMeterPaceProjection(
            projectedAt: projectedAt,
            resetAt: resetsAt,
            markerPercent: min(max(projectedDuration / windowDuration, 0), 1),
            emptiesBeforeReset: projectedAt < resetsAt)
    }
}
