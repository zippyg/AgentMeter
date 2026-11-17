import CodexBarCore
import SwiftUI

/// One login on one compact block: header, then a line per window with its bar, steady mark,
/// percent used, points ahead or behind, and top-up time.
struct UsagePoolAccountRowView: View {
    let row: UsagePoolAccountRow
    let tint: Color
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                UsagePoolAccountDot(status: self.row.status, hasReading: self.row.hasReading)
                Text(self.row.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(self.row.statusText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let headroom = self.row.headroom {
                    Text("\(Int(headroom.rounded())) left").font(.system(size: 12, weight: .semibold))
                }
            }
            if let session = self.row.session {
                self.line(session)
            }
            if let weekly = self.row.weekly {
                self.line(weekly)
            } else {
                self.missing("Week", "no reading")
            }
            ForEach(Array(self.row.scoped.enumerated()), id: \.offset) { _, window in self.line(window) }
            if let text = self.row.projectionText {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let runway = self.row.runway, !UsagePoolFleet.runwayText(runway, now: self.now).isEmpty {
                Text(UsagePoolFleet.runwayText(runway, now: self.now))
                    .font(.system(size: 12))
                    .foregroundStyle(runway.isShort ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func line(_ window: UsagePoolAccountRow.Window) -> some View {
        let stale = self.row.status == .stale
        return HStack(spacing: 6) {
            Text(window.title).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: 36, alignment: .leading)
            // The green line is where usage would sit at an even pace through this window.
            UsageProgressBar(
                percent: window.usedPercent ?? 0,
                tint: stale ? self.tint.opacity(0.45) : self.tint,
                accessibilityLabel: window.title,
                pacePercent: window.steadyPercent)
            Text(window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "?")
                .foregroundStyle(stale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(width: 34, alignment: .trailing)
            Text(window.pacePoints.map(UsagePoolPaceGauge.signed) ?? "–")
                .foregroundStyle(window.pacePoints.map {
                    AnyShapeStyle(UsagePoolPaceGauge.color(UsagePoolPaceGauge.state(Double($0) / 100)))
                } ?? AnyShapeStyle(.tertiary))
                .frame(width: 28, alignment: .trailing)
                .help("Usage against an even pace")
            Text(Self.topUp(window, now: self.now)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                .frame(width: 90, alignment: .trailing)
                .help(window.topUp.map { UsagePoolFleet.relativeText($0, now: self.now) } ?? "")
        }
        .font(.system(size: 12)).monospacedDigit()
    }

    static func topUp(_ window: UsagePoolAccountRow.Window, now: Date) -> String {
        if window.sharesWeeklyTopUp || !["5h", "Week"].contains(window.title) { return "" }
        if window.awaitingRead { return "reset, unread" }
        guard let date = window.topUp else { return window.usedPercent == 0 ? "starts on use" : "" }
        return UsagePoolViewModel.dateText(date, now: now)
    }

    private func missing(_ title: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            Text(text).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }.font(.system(size: 12))
    }
}

/// The Claude tab's header: how much of the week is left across readable logins, the pool's pace,
/// when they all run dry, and when the next one tops up. The one place to read Claude pace.
struct UsagePoolFleetStrip<Pace: View>: View {
    let fleet: UsagePoolFleet
    let total: Int
    let now: Date
    @ViewBuilder var pace: Pace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(self.fleet.displayedHeadroomPoints)").font(.system(size: 22, weight: .semibold))
                Text("of \(Int(self.fleet.capacityPoints)) left").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if self.fleet.readableCount < self.total {
                    Text("\(self.fleet.readableCount) of \(self.total) logins").font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            self.pace.padding(.vertical, 4)
            if !UsagePoolFleet.fleetRunwayText(self.fleet, now: self.now).isEmpty {
                Text(UsagePoolFleet.fleetRunwayText(self.fleet, now: self.now)).font(.subheadline)
                    .foregroundStyle(self.fleet.allExhausted != nil ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            if let next = self.fleet.nextTopUp {
                HStack(spacing: 4) {
                    Text("Next top-up").foregroundStyle(.secondary)
                    Text(next.name).fontWeight(.medium)
                    Spacer(minLength: 4)
                    Text(UsagePoolFleet.topUpText(next.at, now: self.now))
                        .help(UsagePoolFleet.relativeText(next.at, now: self.now))
                }.font(.subheadline).lineLimit(1)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

extension UsagePoolAccountRow.Runway {
    fileprivate var isShort: Bool {
        if case .runsOut = self { true } else { false }
    }
}
