import Foundation

enum AgentMeterSampleData {
    static func emptySnapshot(now: Date = Date()) -> AgentMeterPhoneSnapshot {
        AgentMeterPhoneSnapshot(generatedAt: now, providers: [])
    }

    static func snapshot(now: Date = Date(), fallback: Bool = false) -> AgentMeterPhoneSnapshot {
        let generatedAt = fallback ? now.addingTimeInterval(-60 * 60) : now
        let status: AgentMeterPhoneProviderStatus = fallback ? .unavailable : .ok
        let source = AgentMeterPhoneSource(
            confidence: .unknown,
            label: fallback ? "Sample data" : "Local fixture",
            detail: fallback ? "No Mac snapshot has been imported or synced yet." : "Static fixture.")
        let staleAfter = fallback ? generatedAt : now.addingTimeInterval(15 * 60)

        return AgentMeterPhoneSnapshot(
            generatedAt: generatedAt,
            providers: [
                AgentMeterPhoneProvider(
                    id: "claude",
                    displayName: "Claude",
                    accountLabel: "Personal",
                    plan: "Max",
                    windows: [
                        AgentMeterPhoneUsageWindow(
                            id: "session",
                            title: "Session",
                            usedPercent: 42,
                            remainingPercent: 58,
                            resetsAt: now.addingTimeInterval(54 * 60),
                            resetDescription: "54m",
                            windowMinutes: 300),
                        AgentMeterPhoneUsageWindow(
                            id: "weekly",
                            title: "Weekly",
                            usedPercent: 63,
                            remainingPercent: 37,
                            resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
                            resetDescription: "2d",
                            windowMinutes: 7 * 24 * 60),
                    ],
                    tokenUsage: AgentMeterPhoneTokenUsage(
                        sessionCostUSD: 4.82,
                        sessionTokens: 418_000,
                        last30DaysCostUSD: 91.40,
                        last30DaysTokens: 8_900_000,
                        currencyCode: "USD",
                        sessionLabel: "Today",
                        last30DaysLabel: "30d"),
                    dailyUsage: [
                        AgentMeterPhoneDailyUsagePoint(dayKey: "2026-06-12", totalTokens: 310_000, costUSD: 3.64),
                        AgentMeterPhoneDailyUsagePoint(dayKey: "2026-06-13", totalTokens: 382_000, costUSD: 4.22),
                        AgentMeterPhoneDailyUsagePoint(dayKey: "2026-06-14", totalTokens: 418_000, costUSD: 4.82),
                    ],
                    source: AgentMeterPhoneSource(
                        confidence: source.confidence,
                        label: source.label,
                        detail: source.detail),
                    status: status,
                    updatedAt: generatedAt,
                    staleAfter: staleAfter),
                AgentMeterPhoneProvider(
                    id: "codex",
                    displayName: "Codex",
                    accountLabel: "Personal",
                    plan: "Plus",
                    windows: [
                        AgentMeterPhoneUsageWindow(
                            id: "session",
                            title: "Session",
                            usedPercent: 24,
                            remainingPercent: 76,
                            resetsAt: now.addingTimeInterval(3 * 60 * 60),
                            resetDescription: "3h",
                            windowMinutes: 300),
                        AgentMeterPhoneUsageWindow(
                            id: "weekly",
                            title: "Weekly",
                            usedPercent: 51,
                            remainingPercent: 49,
                            resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60),
                            resetDescription: "5d",
                            windowMinutes: 7 * 24 * 60),
                    ],
                    tokenUsage: AgentMeterPhoneTokenUsage(
                        sessionCostUSD: 2.16,
                        sessionTokens: 252_000,
                        last30DaysCostUSD: 37.20,
                        last30DaysTokens: 4_600_000,
                        currencyCode: "USD",
                        sessionLabel: "Today",
                        last30DaysLabel: "30d"),
                    dailyUsage: [
                        AgentMeterPhoneDailyUsagePoint(dayKey: "2026-06-12", totalTokens: 148_000, costUSD: 1.21),
                        AgentMeterPhoneDailyUsagePoint(dayKey: "2026-06-13", totalTokens: 210_000, costUSD: 1.88),
                        AgentMeterPhoneDailyUsagePoint(dayKey: "2026-06-14", totalTokens: 252_000, costUSD: 2.16),
                    ],
                    source: AgentMeterPhoneSource(
                        confidence: source.confidence,
                        label: source.label,
                        detail: source.detail),
                    status: status,
                    updatedAt: generatedAt,
                    staleAfter: staleAfter),
            ])
    }

    static var jsonData: Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(Self.snapshot(now: Date(timeIntervalSince1970: 1_812_998_400)))) ?? Data()
    }
}
