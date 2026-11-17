import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import AgentMeter

@MainActor
struct UsagePoolPresentationAcceptanceTests {
    @Test func popoverSourcesContainNoBannedPresentationPhrases() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "UsagePoolPopoverView.swift", "UsagePoolAccountRowView.swift", "UsagePoolPaceGauge.swift",
            "UsagePoolViewModel.swift", "UsagePoolFleet.swift", "UsagePoolPresentation.swift", "AllAccountsUsageCard.swift",
        ]
        let banned = ["vs pace", "pts", "points ahead", "where you should be", "left out", "most room"]
        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/CodexBar/" + file), encoding: .utf8)
            for line in source.components(separatedBy: .newlines) {
                let code = String(line.components(separatedBy: "//").first ?? "")
                guard code.contains("\"") else { continue }
                for phrase in banned {
                    #expect(!code.localizedCaseInsensitiveContains(phrase), "\(file): \(phrase)")
                }
            }
        }
    }

    @Test func resetCellsUseAbsoluteTimesAndFitTheirColumn() {
        let now = Date(timeIntervalSince1970: 1794052800)
        for offset in [3600.0, 86400.0, 432000.0, 864000.0] {
            let window = UsagePoolFleet.window("Week", .init(usedPercent: 40, windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(offset), resetDescription: nil), stale: false, now: now)
            let text = UsagePoolAccountRowView.topUp(window, now: now)
            #expect(!text.contains("in "))
            #expect(!text.contains("…"))
            let width = (text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]).width
            #expect(width * 0.75 <= 90)
        }
        let reset = UsagePoolFleet.window("Week", .init(usedPercent: 40, windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(-3600), resetDescription: nil), stale: true, now: now)
        #expect(UsagePoolAccountRowView.topUp(reset, now: now) == "reset, unread")
    }

    @Test func deltasUseBareIntegersAndStateColours() {
        #expect([-86, 0, 6].map(UsagePoolPaceGauge.signed) == ["−86", "0", "+6"])
        #expect(UsagePoolPaceGauge.color(.onPace) == .green)
        #expect(UsagePoolPaceGauge.color(.ahead) == .orange)
        #expect(UsagePoolPaceGauge.color(.behind) == .blue)
    }
}
