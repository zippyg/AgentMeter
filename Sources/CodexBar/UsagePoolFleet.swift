import CodexBarCore
import Foundation

/// One compact row per login: a status dot, the 5-hour and weekly windows with their steady marks and
/// top-ups, and the weekly points left. Stale readings say how old they are and never drive pace.
struct UsagePoolAccountRow: Equatable, Identifiable {
    enum Status: Equatable {
        /// Signed in now with a fresh reading. The only green dot.
        case active
        /// A fresh reading for a login that is not signed in.
        case idle
        /// Unreadable, rate-limited, never read, or read too long ago.
        case stale
    }

    struct Window: Equatable {
        let title: String
        /// Nil when the window reset after a stale reading: usage since then is unknown.
        let usedPercent: Double?
        let steadyPercent: Double?
        /// Used minus steady, in points. Nil for stale readings and unknown clocks.
        let pacePoints: Int?
        var paceText: String { self.pacePoints.map { UsagePoolPaceGauge.signed($0) } ?? "" }
        let topUp: Date?
        /// The window reset after the last reading, which is now void.
        let awaitingRead: Bool
        /// A model allowance that tops up with the week: its time is already on the week's line.
        var sharesWeeklyTopUp = false
    }

    /// Where this login's week ends at its own average burn so far.
    enum Runway: Equatable {
        /// Under six hours of the current week and not yet empty: no rate to project.
        case tooEarly
        /// No weekly reset time reported, so neither run-out nor top-up can be placed.
        case unknown
        case lastsToTopUp(topUp: Date)
        case runsOut(at: Date, topUp: Date)
    }

    let id: String
    let name: String
    let status: Status
    var statusText: String
    let session: Window?
    let weekly: Window?
    let scoped: [Window]
    /// Weekly points left from a fresh reading. Nil when stale or unknown.
    let headroom: Double?
    /// Nil for stale readings, which are never projected, and for unknown weekly clocks.
    var runway: Runway?
    var mostRoom = false
    var projectionText: String?
    var hasReading = false

    var dotIsGreen: Bool {
        self.status == .active
    }
}

struct UsagePoolFleet: Equatable {
    struct TopUp: Equatable {
        let name: String
        let at: Date
    }

    /// Most weekly headroom first; stale and unknown rows last, in pool order.
    let rows: [UsagePoolAccountRow]
    /// Sum of weekly points left across logins with fresh readings.
    let headroomPoints: Double
    let readableCount: Int
    /// The earliest weekly top-up still ahead, stale logins included: their clocks are still known.
    let nextTopUp: TopUp?
    /// Whether every readable login is projected to be empty at once this week.
    enum Outlook: Equatable {
        case allEmpty(DateInterval)
        case alwaysRoom
        /// Some readable logins cannot be projected, and the rest do not rule a gap out.
        case unknown(unprojected: Int)
        case noReadable
    }

    let outlook: Outlook

    var allExhausted: DateInterval? {
        if case let .allEmpty(interval) = self.outlook { interval } else { nil }
    }

    var displayedHeadroomPoints: Int {
        self.rows.compactMap(\.headroom).reduce(0) { $0 + Int($1.rounded()) }
    }

    var capacityPoints: Double {
        Double(self.readableCount) * 100
    }

    /// A reading older than this is stale. claude-swap reads every few minutes while it can.
    static let staleAfter: TimeInterval = 3600

    static func make(
        accounts: [UsagePoolForecast.Account],
        now: Date,
        name: (UsagePoolForecast.Account, Int) -> String = { account, _ in account.displayName }) -> Self
    {
        let unsorted = accounts.enumerated().map { index, account in
            Self.row(account, name: name(account, index), now: now)
        }
        // A stable sort keeps pool order among equals.
        var rows = unsorted.enumerated().sorted { lhs, rhs in
            switch (lhs.element.headroom, rhs.element.headroom) {
            case let (left?, right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.offset < rhs.offset
            }
        }.map(\.element)
        if rows.count > 1, let best = rows.first?.headroom, best > 0 { rows[0].mostRoom = true }
        let fresh = rows.compactMap(\.headroom)
        let next = rows.compactMap { row in
            row.weekly.flatMap { window in window.topUp.flatMap { $0 > now ? TopUp(name: row.name, at: $0) : nil } }
        }.min { $0.at < $1.at }
        return Self(
            rows: rows,
            headroomPoints: fresh.reduce(0, +),
            readableCount: fresh.count,
            nextTopUp: next,
            outlook: Self.outlook(rows.filter { $0.headroom != nil }.map { $0.runway ?? .unknown }))
    }

    /// Each projected login is empty from its run-out time to its top-up. Every login is empty at once
    /// only inside the overlap of those spans. One login that lasts to its top-up, or spans that never
    /// overlap, mean one always has room. Otherwise an unprojected login leaves the gap unknown.
    /// Only the current week of each login is projected.
    static func outlook(_ runways: [UsagePoolAccountRow.Runway]) -> Outlook {
        guard !runways.isEmpty else { return .noReadable }
        var spans: [(start: Date, end: Date)] = []
        for runway in runways {
            switch runway {
            case .lastsToTopUp: return .alwaysRoom
            case let .runsOut(at, topUp): spans.append((at, topUp))
            case .tooEarly, .unknown: break
            }
        }
        let unprojected = runways.count - spans.count
        if let start = spans.map(\.start).max(), let end = spans.map(\.end).min() {
            if start >= end { return .alwaysRoom }
            if unprojected == 0 { return .allEmpty(DateInterval(start: start, end: end)) }
        }
        return .unknown(unprojected: unprojected)
    }

    /// At or near 100% a login is empty now, whatever its age.
    static let emptyPercent = 99.5

    /// Rate is used percent since the window started over the time elapsed. Six hours minimum.
    static func runway(_ window: RateWindow, now: Date) -> UsagePoolAccountRow.Runway? {
        guard let reset = window.resetsAt else { return .unknown }
        guard reset > now else { return nil }
        if window.usedPercent >= Self.emptyPercent { return .runsOut(at: now, topUp: reset) }
        let duration = Double(window.windowMinutes ?? 10080) * 60
        let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-duration))
        guard elapsed >= 6 * 3600 else { return .tooEarly }
        let rate = window.usedPercent / elapsed
        guard rate > 0 else { return .lastsToTopUp(topUp: reset) }
        let empty = now.addingTimeInterval(max(0, 100 - window.usedPercent) / rate)
        return empty < reset ? .runsOut(at: empty, topUp: reset) : .lastsToTopUp(topUp: reset)
    }

    /// Stale: unreadable, rate-limited, never read, read over an hour ago, or read before a weekly reset
    /// that has since passed, because usage after a reset is unknown until the next reading.
    static func isStale(_ account: UsagePoolForecast.Account, now: Date) -> Bool {
        guard account.refusedSince == nil, !account.isRateLimited,
              let measured = account.measuredAt else { return true }
        return now.timeIntervalSince(measured) > Self.staleAfter || Self.weeklyResetPassed(account, now: now)
    }

    static func weeklyResetPassed(_ account: UsagePoolForecast.Account, now: Date) -> Bool {
        account.weekly?.resetsAt.map { $0 <= now } == true
    }

    static func row(_ account: UsagePoolForecast.Account, name: String, now: Date) -> UsagePoolAccountRow {
        let stale = Self.isStale(account, now: now)
        let inUse = UsagePoolViewModel.isInUse(account)
        let status: UsagePoolAccountRow.Status = stale ? .stale : inUse ? .active : .idle
        let text: String = switch status {
        case .active: "Active"
        case .idle: "Not active"
        case .stale: Self.staleText(account, inUse: inUse, now: now)
        }
        let weekly = account.weekly.map { Self.window("Week", $0, stale: stale, now: now) }
        return UsagePoolAccountRow(
            id: account.id,
            name: name,
            status: status,
            statusText: text,
            session: account.session.map { Self.window("5h", $0, stale: stale, now: now) },
            weekly: weekly,
            scoped: account.scoped.filter(\.usageKnown).map {
                var line = Self.window($0.title, $0.window, stale: stale, now: now)
                // claude-swap stamps the two resets microseconds apart, so compare to the minute.
                if let own = line.topUp, let week = weekly?.topUp {
                    line.sharesWeeklyTopUp = abs(own.timeIntervalSince(week)) < 60
                }
                return line
            },
            headroom: stale ? nil : weekly?.usedPercent.map { max(0, 100 - $0) },
            runway: stale ? nil : account.weekly.flatMap { Self.runway($0, now: now) },
            hasReading: account.measuredAt != nil)
    }

    static func staleText(_ account: UsagePoolForecast.Account, inUse: Bool, now: Date) -> String {
        guard let measured = account.measuredAt else { return "Never read" }
        if account.refusedSince != nil, !account.isRateLimited {
            return "Not read · last read \(Self.age(measured, now: now)) ago"
        }
        let reason = account.isRateLimited ? "Rate-limited"
            : Self.weeklyResetPassed(account, now: now) ? "Reset" : "Unreadable"
        return "\(reason) · \(Self.age(measured, now: now)) ago"
    }

    static func window(
        _ title: String,
        _ window: RateWindow,
        stale: Bool,
        now: Date) -> UsagePoolAccountRow.Window
    {
        guard let reset = window.resetsAt, reset <= now else {
            // A stale reading shows where it was, never where it should be now.
            let steady = stale ? nil : UsagePoolViewModel.steadyPercent(window, now: now)
            return .init(
                title: title,
                usedPercent: window.usedPercent,
                steadyPercent: steady,
                pacePoints: steady.map { Int((window.usedPercent - $0).rounded()) },
                topUp: window.resetsAt,
                awaitingRead: false)
        }
        // The window reset after this reading: usage since then is unknown until the next one.
        return .init(
            title: title,
            usedPercent: nil,
            steadyPercent: nil,
            pacePoints: nil,
            topUp: reset,
            awaitingRead: true)
    }

    /// Coarse on purpose: "45m", "13h", "2d".
    static func age(_ date: Date, now: Date) -> String {
        let minutes = Int(abs(now.timeIntervalSince(date)) / 60)
        return minutes < 60 ? "\(minutes)m" : minutes < 2880 ? "\(minutes / 60)h" : "\(minutes / 1440)d"
    }

    /// "in 1d 14h" ahead, "3h 5m ago" behind.
    static func relativeText(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        return seconds >= 0 ? "in \(Self.span(seconds))" : "\(Self.span(-seconds)) ago"
    }

    /// "Thu 02:00, in 1d 14h".
    static func topUpText(_ date: Date, now: Date) -> String {
        UsagePoolViewModel.dateText(date, now: now)
    }

    /// "Runs out Tue 18:00, tops up Thu 02:00: 1d 8h short".
    static func runwayText(_ runway: UsagePoolAccountRow.Runway, now: Date) -> String {
        switch runway {
        case .tooEarly: "Too early"
        case .unknown: "No reset time"
        case .lastsToTopUp: ""
        case let .runsOut(at, topUp):
            "Out \(UsagePoolViewModel.dateText(at, now: now)) · "
                + "\(Self.span(topUp.timeIntervalSince(at))) short"
        }
    }

    static func fleetRunwayText(_ fleet: Self, now: Date) -> String {
        switch fleet.outlook {
        case let .allEmpty(gap):
            "Empty \(UsagePoolViewModel.dateText(gap.start, now: now)) to "
                + (Calendar.current.isDate(gap.start, inSameDayAs: gap.end)
                    ? UsagePoolViewModel.dateText(gap.end, now: gap.start)
                    : UsagePoolViewModel.dateText(gap.end, now: now))
        case .alwaysRoom: ""
        case .unknown: "Gap unknown"
        case .noReadable: "No reading"
        }
    }

    private static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / 1440)d \(minutes / 60 % 24)h"
    }
}
