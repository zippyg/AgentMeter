import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import AgentMeter

@MainActor
struct AgentMeterMenuSummaryTests {
    @Test
    func `summary orders claude then codex and formats core windows`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AgentMeterSnapshot(generatedAt: now, providers: [
            Self.provider(
                id: .codex,
                displayName: "Codex",
                sessionRemaining: 80,
                weeklyRemaining: 52,
                reset: now.addingTimeInterval(7200)),
            Self.provider(
                id: .claude,
                displayName: "Claude",
                sessionRemaining: 70,
                weeklyRemaining: 40,
                reset: now.addingTimeInterval(3600)),
        ])

        let model = AgentMeterMenuSummaryModel(snapshot: snapshot, now: now)

        #expect(model.rows.map(\.id) == [UsageProvider.claude, UsageProvider.codex])
        #expect(model.rows[0].sessionLine == "Session: 30% used")
        #expect(model.rows[0].weeklyLine == "Weekly: 60% used")
        #expect(model.rows[0].resetLine == "Session reset in 1h")
        #expect(model.rows[0].usedPercent == 60)
        #expect(model.rows[1].resetLine == "Session reset in 2h")
    }

    @Test
    func `summary marks stale snapshots and formats token burn`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AgentMeterSnapshot(generatedAt: now.addingTimeInterval(-900), providers: [
            Self.provider(
                id: .claude,
                displayName: "Claude",
                sessionRemaining: 90,
                weeklyRemaining: 75,
                reset: nil,
                staleAfter: now.addingTimeInterval(-1),
                tokenUsage: AgentMeterTokenUsageSummary(
                    sessionCostUSD: 1.25,
                    sessionTokens: 12500,
                    last30DaysCostUSD: 30,
                    last30DaysTokens: 400_000,
                    currencyCode: "USD",
                    sessionLabel: "Today",
                    last30DaysLabel: "30d")),
        ])

        let model = AgentMeterMenuSummaryModel(snapshot: snapshot, now: now)

        #expect(model.rows.count == 1)
        #expect(model.rows[0].status == .stale)
        #expect(model.rows[0].statusText == "stale")
        #expect(model.rows[0].tokenLine == "Today: $1.25, 12K tokens")
    }

    @Test
    func `summary view renders to stable menu width`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = AgentMeterSnapshot(generatedAt: now, providers: [
            Self.provider(
                id: .claude,
                displayName: "Claude",
                sessionRemaining: 70,
                weeklyRemaining: 40,
                reset: now.addingTimeInterval(3600)),
            Self.provider(
                id: .codex,
                displayName: "Codex",
                sessionRemaining: 80,
                weeklyRemaining: 52,
                reset: now.addingTimeInterval(7200)),
        ])
        let width: CGFloat = 310
        let model = AgentMeterMenuSummaryModel(snapshot: snapshot, now: now)
        let size = NSHostingController(rootView: AgentMeterMenuSummaryView(model: model, width: width))
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))

        #expect(size.width <= width + 1)
        #expect(size.height >= 120)
        #expect(size.height <= 280)
    }

    private static func provider(
        id: UsageProvider,
        displayName: String,
        sessionRemaining: Double,
        weeklyRemaining: Double,
        reset: Date?,
        staleAfter: Date? = nil,
        tokenUsage: AgentMeterTokenUsageSummary? = nil) -> AgentMeterProviderSnapshot
    {
        AgentMeterProviderSnapshot(
            id: id.rawValue,
            displayName: displayName,
            windows: [
                AgentMeterUsageWindow(
                    id: "session",
                    title: "Session",
                    usedPercent: 100 - sessionRemaining,
                    remainingPercent: sessionRemaining,
                    resetsAt: reset,
                    resetDescription: nil,
                    windowMinutes: nil),
                AgentMeterUsageWindow(
                    id: "weekly",
                    title: "Weekly",
                    usedPercent: 100 - weeklyRemaining,
                    remainingPercent: weeklyRemaining,
                    resetsAt: nil,
                    resetDescription: nil,
                    windowMinutes: nil),
            ],
            tokenUsage: tokenUsage,
            source: AgentMeterSourceDescriptor(confidence: .derived, label: "test"),
            status: .ok,
            updatedAt: reset ?? Date(timeIntervalSince1970: 1_700_000_000),
            staleAfter: staleAfter)
    }
}
