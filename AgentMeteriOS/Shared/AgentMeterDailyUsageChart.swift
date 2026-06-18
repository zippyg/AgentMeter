import Foundation

struct AgentMeterDailyUsageChartModel: Equatable, Sendable {
    struct Point: Equatable, Identifiable, Sendable {
        var id: String { self.dayKey }

        var dayKey: String
        var shortLabel: String
        var totalTokens: Int?
        var costUSD: Double?
        var normalizedHeight: Double
    }

    var points: [Point]
    var totalTokens: Int?
    var totalCostUSD: Double?

    var hasData: Bool {
        !self.points.isEmpty
    }

    init(dailyUsage: [AgentMeterPhoneDailyUsagePoint], maxPoints: Int = 7) {
        let limited = dailyUsage
            .sorted { $0.dayKey < $1.dayKey }
            .suffix(max(1, maxPoints))

        let maxTokens = limited.compactMap(\.totalTokens).max() ?? 0
        let maxCost = limited.compactMap(\.costUSD).max() ?? 0
        let totalTokens = limited.compactMap(\.totalTokens).reduce(0, +)
        let totalCost = limited.compactMap(\.costUSD).reduce(0, +)
        let hasTokens = limited.contains { $0.totalTokens != nil }
        let hasCost = limited.contains { $0.costUSD != nil }

        self.points = limited.map { point in
            let rawHeight: Double
            if let tokens = point.totalTokens, maxTokens > 0 {
                rawHeight = Double(tokens) / Double(maxTokens)
            } else if let cost = point.costUSD, maxCost > 0 {
                rawHeight = cost / maxCost
            } else {
                rawHeight = 0
            }
            return Point(
                dayKey: point.dayKey,
                shortLabel: Self.shortLabel(dayKey: point.dayKey),
                totalTokens: point.totalTokens,
                costUSD: point.costUSD,
                normalizedHeight: min(max(rawHeight, 0), 1))
        }
        self.totalTokens = hasTokens ? totalTokens : nil
        self.totalCostUSD = hasCost ? totalCost : nil
    }

    private static func shortLabel(dayKey: String) -> String {
        let suffix = dayKey.suffix(2)
        return suffix.isEmpty ? dayKey : String(suffix)
    }
}
