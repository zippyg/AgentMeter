import AppKit
import SwiftUI
import Testing
@testable import AgentMeter

@MainActor
struct MenuCardNumericTypographyTests {
    @Test
    func `equal length percentages retain their width`() {
        #expect(abs(self.rowWidth(title: "Session", percent: 11) - self.rowWidth(title: "Session", percent: 88)) < 0.1)
    }

    @Test
    func `digits in metric titles keep proportional typography`() {
        #expect(self.rowWidth(title: "Model 888888", percent: 50) > self.rowWidth(title: "Model 111111", percent: 50) + 1)
    }

    @Test
    func `countdown digits retain width`() {
        let narrow = self.rowWidth(title: "Session", percent: 50, reset: "Resets in 11h 11m")
        let wide = self.rowWidth(title: "Session", percent: 50, reset: "Resets in 88h 88m")
        #expect(abs(narrow - wide) < 0.1)
    }

    private func rowWidth(title: String, percent: Double, reset: String? = nil) -> CGFloat {
        let metric = UsageMenuCardView.Model.Metric(
            id: "primary", title: title, percent: percent, percentStyle: .used,
            resetText: reset, detailText: nil, detailLeftText: nil, detailRightText: nil,
            pacePercent: nil, paceOnTop: true)
        let row = MetricRow(metric: metric, title: title, progressColor: .blue)
        return NSHostingController(rootView: row.fixedSize())
            .sizeThatFits(in: CGSize(width: 10000, height: 10000)).width
    }
}
