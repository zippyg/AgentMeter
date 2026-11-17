import CodexBarCore
import Foundation
import Testing
@testable import AgentMeter

struct UsagePoolFleetTests {
    static let now = ISO8601DateFormatter().date(from: "2026-11-07T12:00:00Z")!

    static func hours(_ value: Double) -> Date {
        self.now.addingTimeInterval(value * 3600)
    }

    /// A weekly window that started `started` hours ago.
    static func weekly(_ used: Double, started: Double) -> RateWindow {
        .init(usedPercent: used, windowMinutes: 10080, resetsAt: self.hours(168 - started), resetDescription: nil)
    }

    static func account(
        _ id: String, weekly: RateWindow?, session: RateWindow? = nil, readAgo: Double? = 0.1,
        refused: Bool = false, rateLimited: Bool = false, current: Bool = false) -> UsagePoolForecast.Account
    {
        .init(
            id: id,
            displayName: id,
            weekly: weekly,
            session: session,
            measuredAt: readAgo.map { self.hours(-$0) },
            refusedSince: refused ? self.hours(-1) : nil,
            isRateLimited: rateLimited,
            isCurrentLogin: current)
    }

    @Test func statusDotIsGreenOnlyForTheFreshSignedInLogin() {
        let rows = [
            Self.account("login-a", weekly: Self.weekly(30, started: 50), current: true),
            Self.account("login-b", weekly: Self.weekly(30, started: 50)),
            Self.account("login-c", weekly: Self.weekly(30, started: 50), readAgo: 13, current: true),
            Self.account("login-d", weekly: Self.weekly(30, started: 50), rateLimited: true),
            Self.account("login-e", weekly: Self.weekly(30, started: 50), refused: true),
            Self.account("login-f", weekly: Self.weekly(30, started: 50), readAgo: nil),
        ].map { UsagePoolFleet.row($0, name: $0.id, now: Self.now) }
        #expect(rows.map(\.status) == [.active, .idle, .stale, .stale, .stale, .stale])
        #expect(rows.map(\.dotIsGreen) == [true, false, false, false, false, false])
        #expect(rows[1].statusText == "Not active")
        #expect(rows[2].statusText == "Unreadable · 13h ago")
        #expect(rows[3].statusText == "Rate-limited · 6m ago")
        #expect(rows[4].statusText == "Not read · last read 6m ago")
        #expect(rows[5].statusText == "Never read")
    }

    @Test func failedReadsKeepTheLastReadingButPreserveRateLimitAndNeverReadReasons() {
        let weekly = Self.weekly(30, started: 50)
        let cases: [(UsagePoolForecast.Account, String)] = [
            (Self.account("login-a", weekly: weekly, refused: true), "Not read · last read 6m ago"),
            (Self.account("login-b", weekly: weekly, readAgo: nil, refused: true), "Never read"),
            (Self.account("login-c", weekly: weekly, refused: true, rateLimited: true), "Rate-limited · 6m ago"),
            (Self.account("login-d", weekly: Self.weekly(30, started: 169)), "Reset · 6m ago"),
        ]
        for (account, expected) in cases {
            #expect(UsagePoolFleet.row(account, name: account.id, now: Self.now).statusText == expected)
        }
    }

    @Test func staleReadingsKeepTheirClockButNeverDrivePaceHeadroomOrRunway() throws {
        let stale = UsagePoolFleet.row(
            Self.account("login-a", weekly: Self.weekly(95, started: 100), readAgo: 50, rateLimited: true),
            name: "A", now: Self.now)
        let weekly = try #require(stale.weekly)
        #expect(stale.statusText == "Rate-limited · 2d ago")
        #expect(weekly.usedPercent == 95)
        #expect(weekly.pacePoints == nil)
        #expect(weekly.topUp == Self.hours(68))
        #expect(stale.headroom == nil)
        #expect(stale.runway == nil)

        let fresh = UsagePoolFleet.row(
            Self.account("login-b", weekly: Self.weekly(95, started: 84)),
            name: "B",
            now: Self.now)
        // Half the week gone, so steady is 50 and 95 used is 45 points ahead.
        #expect(fresh.weekly?.pacePoints == 45)
        #expect(fresh.headroom == 5)
    }

    /// Review item 1: after a reset with no new reading, usage is unknown. The row is stale: no room,
    /// no runway, never most room, until a reading after the reset arrives.
    @Test func aReadingFromBeforeAPassedResetIsStaleNotEmpty() {
        let passedWeekly = RateWindow(
            usedPercent: 95,
            windowMinutes: 10080,
            resetsAt: Self.hours(-2),
            resetDescription: nil)
        let passedSession = RateWindow(
            usedPercent: 13,
            windowMinutes: 300,
            resetsAt: Self.hours(-1),
            resetDescription: nil)
        let stale = UsagePoolFleet.row(
            Self.account("login-a", weekly: passedWeekly, session: passedSession, readAgo: 14, refused: true),
            name: "A", now: Self.now)
        #expect(stale.statusText == "Not read · last read 14h ago")
        #expect(stale.weekly?.usedPercent == nil)
        #expect(stale.weekly?.awaitingRead == true)
        #expect(stale.session?.awaitingRead == true)

        // Read ten minutes ago, but before the weekly reset two hours ago.
        let reset = Self.account("login-b", weekly: passedWeekly, session: passedSession, readAgo: 0.1)
        let row = UsagePoolFleet.row(reset, name: "B", now: Self.now)
        #expect(UsagePoolFleet.isStale(reset, now: Self.now))
        #expect(row.status == .stale)
        #expect(row.statusText == "Reset · 6m ago")
        #expect(row.weekly?.usedPercent == nil)
        #expect(row.session?.usedPercent == nil)
        #expect(row.headroom == nil)
        #expect(row.runway == nil)

        let fleet = UsagePoolFleet.make(accounts: [
            reset, Self.account("login-c", weekly: Self.weekly(60, started: 100)),
        ], now: Self.now)
        #expect(fleet.rows.first?.id == "login-c")
        #expect(fleet.rows.first { $0.id == "login-b" }?.mostRoom == false)
        #expect(fleet.headroomPoints == 40)
        #expect(fleet.readableCount == 1)
    }

    /// Review item 4: a stale row keeps its last reading but no steady marker or pace.
    @Test func staleRowsDrawNoSteadyMarker() {
        let row = UsagePoolFleet.row(
            Self.account("login-a", weekly: Self.weekly(40, started: 84), readAgo: 3), name: "A", now: Self.now)
        #expect(row.weekly?.usedPercent == 40)
        #expect(row.weekly?.steadyPercent == nil)
        #expect(row.weekly?.pacePoints == nil)
    }

    @Test func relativeTimesReadInMinutesHoursAndDays() throws {
        #expect(UsagePoolFleet.relativeText(Self.hours(0.75), now: Self.now) == "in 45m")
        #expect(UsagePoolFleet.relativeText(Self.hours(5.5), now: Self.now) == "in 5h 30m")
        #expect(UsagePoolFleet.relativeText(Self.hours(38), now: Self.now) == "in 1d 14h")
        #expect(UsagePoolFleet.relativeText(Self.hours(-3), now: Self.now) == "3h 0m ago")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        #expect(UsagePoolViewModel.dateText(Self.hours(38), now: Self.now, calendar: calendar) == "Mon 02:00")
        #expect(UsagePoolFleet.age(Self.hours(-13.4), now: Self.now) == "13h")
        #expect(UsagePoolFleet.age(Self.hours(-52), now: Self.now) == "2d")
    }

    @Test func rowsSortByHeadroomAndMarkMostRoomOnce() {
        let fleet = UsagePoolFleet.make(accounts: [
            Self.account("login-a", weekly: Self.weekly(82, started: 100)),
            Self.account("login-b", weekly: Self.weekly(95, started: 110), readAgo: 14, rateLimited: true),
            Self.account("login-c", weekly: Self.weekly(27, started: 100), current: true),
            Self.account("login-d", weekly: Self.weekly(27, started: 100)),
        ], now: Self.now)
        #expect(fleet.rows.map(\.id) == ["login-c", "login-d", "login-a", "login-b"])
        #expect(fleet.rows.map(\.mostRoom) == [true, false, false, false])
        #expect(fleet.headroomPoints == 73 + 73 + 18)
        #expect(fleet.readableCount == 3)
        #expect(fleet.capacityPoints == 300)
        // Stale clocks still count for the next top-up.
        #expect(fleet.nextTopUp == .init(name: "login-b", at: Self.hours(58)))

        let single = UsagePoolFleet.make(
            accounts: [Self.account("codex", weekly: Self.weekly(20, started: 30))],
            now: Self.now)
        #expect(single.rows.first?.mostRoom == false)
    }

    @Test func runwayUsesUsedSinceWindowStartOverElapsed() throws {
        // 20 points in 40 hours: 80 left lasts 160 hours, past the top-up in 128 hours.
        #expect(UsagePoolFleet
            .runway(Self.weekly(20, started: 40), now: Self.now) == .lastsToTopUp(topUp: Self.hours(128)))
        // 80 points in 40 hours: 20 left lasts 10 hours, 118 hours short of the top-up.
        let short = try #require(UsagePoolFleet.runway(Self.weekly(80, started: 40), now: Self.now))
        #expect(short == .runsOut(at: Self.hours(10), topUp: Self.hours(128)))
        #expect(UsagePoolFleet.runwayText(short, now: Self.now).hasSuffix("· 4d 22h short"))
        #expect(UsagePoolFleet.runway(Self.weekly(30, started: 5), now: Self.now) == .tooEarly)
        #expect(UsagePoolFleet
            .runway(Self.weekly(0, started: 30), now: Self.now) == .lastsToTopUp(topUp: Self.hours(138)))
    }

    @Test func fleetGapIsTheOverlapOfEveryReadableLoginRunningOut() {
        // A runs out in 10h and tops up in 128h; B runs out in about 12h and tops up in 30h. Empty 12h to 30h.
        let gap = UsagePoolFleet.make(accounts: [
            Self.account("login-a", weekly: Self.weekly(80, started: 40)),
            Self.account("login-b", weekly: Self.weekly(92, started: 138)),
        ], now: Self.now)
        let bRunway = gap.rows.first { $0.id == "login-b" }?.runway
        guard case let .runsOut(bEmpty, bTopUp)? = bRunway else {
            Issue.record("login-b should run out")
            return
        }
        #expect(bTopUp == Self.hours(30))
        #expect(gap.allExhausted == DateInterval(start: max(Self.hours(10), bEmpty), end: Self.hours(30)))
        #expect(UsagePoolFleet.fleetRunwayText(gap, now: Self.now).hasPrefix("Empty"))

        // B tops up before A runs out: there is always one login with room.
        let noGap = UsagePoolFleet.make(accounts: [
            Self.account("login-a", weekly: Self.weekly(80, started: 40)),
            Self.account("login-b", weekly: Self.weekly(99, started: 165)),
        ], now: Self.now)
        #expect(noGap.allExhausted == nil)
        #expect(UsagePoolFleet.fleetRunwayText(noGap, now: Self.now) == "")

        // One login that lasts means no gap.
        let lasting = UsagePoolFleet.make(accounts: [
            Self.account("login-a", weekly: Self.weekly(80, started: 40)),
            Self.account("login-b", weekly: Self.weekly(10, started: 40)),
        ], now: Self.now)
        #expect(lasting.allExhausted == nil)
    }

    @Test func staleLoginsAreLeftOutOfTheGapRatherThanCountedAsRoom() {
        // The stale login reads 5%, but it is unknown now: it must not hide the readable login's gap.
        let fleet = UsagePoolFleet.make(accounts: [
            Self.account("login-a", weekly: Self.weekly(80, started: 40)),
            Self.account("login-b", weekly: Self.weekly(5, started: 40), readAgo: 30, refused: true),
        ], now: Self.now)
        #expect(fleet.outlook == .allEmpty(DateInterval(start: Self.hours(10), end: Self.hours(128))))
        #expect(fleet.allExhausted == DateInterval(start: Self.hours(10), end: Self.hours(128)))
        #expect(fleet.rows.first { $0.id == "login-b" }?.runway == nil)

        let allStale = UsagePoolFleet.make(accounts: [
            Self.account("login-a", weekly: Self.weekly(80, started: 40), readAgo: 5),
        ], now: Self.now)
        #expect(allStale.allExhausted == nil)
        #expect(UsagePoolFleet.fleetRunwayText(allStale, now: Self.now) == "No reading")
    }

    /// Review item 2: a readable login with no reset time has room but no runway. It must not be dropped,
    /// which would let the others claim every login is empty.
    @Test func aLoginWithNoResetTimeMakesTheGapUnknownNotAnOutage() {
        let noClock = RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        let fleet = UsagePoolFleet.make(accounts: [
            Self.account("login-a", weekly: Self.weekly(80, started: 40)),
            Self.account("login-b", weekly: noClock),
        ], now: Self.now)
        #expect(fleet.rows.first { $0.id == "login-b" }?.runway == .unknown)
        #expect(fleet.readableCount == 2)
        #expect(fleet.allExhausted == nil)
        #expect(fleet.outlook == .unknown(unprojected: 1))
        #expect(UsagePoolFleet.fleetRunwayText(fleet, now: Self.now) == "Gap unknown")
    }

    /// Review item 3: a login at 100% is empty now, however young its week. Too early only means no rate.
    @Test func aFullLoginIsEmptyEvenTooEarlyInItsWeek() {
        let full = Self.weekly(100, started: 2)
        #expect(UsagePoolFleet.runway(full, now: Self.now) == .runsOut(at: Self.now, topUp: Self.hours(166)))
        #expect(UsagePoolFleet.runway(Self.weekly(99.6, started: 2), now: Self.now)
            == .runsOut(at: Self.now, topUp: Self.hours(166)))
        #expect(UsagePoolFleet.runway(Self.weekly(40, started: 2), now: Self.now) == .tooEarly)

        // Both logins are full: empty from now until the earlier top-up, not "always one with room".
        let fleet = UsagePoolFleet.make(accounts: [
            Self.account("login-a", weekly: full),
            Self.account("login-b", weekly: Self.weekly(100, started: 100)),
        ], now: Self.now)
        #expect(fleet.allExhausted == DateInterval(start: Self.now, end: Self.hours(68)))

        // A young login with room left cannot be projected, so the gap is unknown rather than ruled out.
        let young = UsagePoolFleet.make(accounts: [
            Self.account("login-a", weekly: Self.weekly(40, started: 2)),
            Self.account("login-b", weekly: Self.weekly(100, started: 100)),
        ], now: Self.now)
        #expect(young.outlook == .unknown(unprojected: 1))
    }

    /// Review item 4: stale logins never feed the pool gauge, and the title says how many it averages.
    @MainActor
    @Test func poolPaceAveragesOnlyFreshLogins() throws {
        let fresh = Self.account("login-a", weekly: Self.weekly(50, started: 84))
        let stale = Self.account("login-b", weekly: Self.weekly(100, started: 84), readAgo: 14, rateLimited: true)
        let model = UsagePoolViewModel(now: Self.now, claude: nil, codex: nil, claudeAccounts: [fresh, stale])
        let position = try #require(model.claudePosition)
        #expect(UsagePoolViewModel.averagedLogins(position) == 1)
        // Fresh login is exactly on pace; the stale 100% must not pull the average ahead.
        #expect(abs(position.delta ?? 1) < 0.000001)
        #expect(UsagePoolFleet.make(accounts: [fresh, stale], now: Self.now).readableCount == 1)
    }

    /// A Fable allowance that tops up with the week does not repeat the week's top-up time; one with its
    /// own clock keeps it. A login whose reading reports no Fable allowance gets no Fable line.
    @Test func fableLineDropsATopUpTimeThatMatchesTheWeek() {
        let week = Self.weekly(40, started: 50)
        func fable(resetOffset: TimeInterval) -> NamedRateWindow {
            .init(id: "scoped-0", title: "Fable", window: .init(
                usedPercent: 4, windowMinutes: 10080,
                resetsAt: week.resetsAt!.addingTimeInterval(resetOffset), resetDescription: nil))
        }
        func row(_ scoped: [NamedRateWindow]) -> UsagePoolAccountRow {
            UsagePoolFleet.row(.init(
                id: "login-a", displayName: "login-a", weekly: week, session: nil, scoped: scoped,
                measuredAt: Self.hours(-0.1), refusedSince: nil), name: "login-a", now: Self.now)
        }
        // claude-swap stamps the two resets microseconds apart.
        let same = row([fable(resetOffset: 0.0002)])
        #expect(same.scoped.map(\.title) == ["Fable"])
        #expect(same.scoped.first?.sharesWeeklyTopUp == true)
        #expect(same.weekly?.sharesWeeklyTopUp == false)
        let own = row([fable(resetOffset: -86400)])
        #expect(own.scoped.first?.sharesWeeklyTopUp == false)
        #expect(row([]).scoped.isEmpty)
    }
}
