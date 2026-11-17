import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import AgentMeter

@MainActor
struct UsagePoolPopoverTests {
    /// The Codex card title already says Codex, so its login row goes by the plan.
    @Test func codexRowIsNamedByPlanNotCodex() {
        #expect(UsagePoolPopoverView.codexRowName(plan: "Pro 20x") == "Pro 20x")
        #expect(UsagePoolPopoverView.codexRowName(plan: nil) == "Login")
        #expect(UsagePoolPopoverView.codexRowName(plan: "") == "Login")
    }

    @Test func accountDotsUseStatus() {
        for (status, color, label) in [
            (UsagePoolAccountRow.Status.active, Color.green, "Active account"),
            (.idle, .secondary, "Not active"),
            (.stale, .red.opacity(0.75), "Never read"),
        ] {
            let dot = UsagePoolAccountDot(status: status)
            #expect(dot.color == color)
            #expect(dot.label == label)
        }
    }

    @Test func cachedReadingsUseCalmDots() {
        let dot = UsagePoolAccountDot(status: .stale, hasReading: true)
        #expect(dot.color == .secondary)
        #expect(dot.label == "Not read")
    }

    @Test func exhaustedUsageUsesOnlyKnownPositivePaidCredits() {
        let window = Self.window(100, "2026-11-13T12:00:00Z")
        for (balance, suffix) in [(Double?.none, "exhausted"), (0, "exhausted"),
                                  (12.5, "on credits")] {
            #expect(UsagePoolViewModel.usageText(window, unreadable: false, estimated: false,
                now: Self.now, creditsRemaining: balance) == "100% used · " + suffix)
        }
    }

    @Test func resetUseTimeIsNotAnExpiryDeadline() {
        let now = Calendar.current.startOfDay(for: Self.now)
        let future = now.addingTimeInterval(3600)
        #expect(UsagePoolViewModel.resetUseText(future, now: now) == "Use when empty, 01:00")
        #expect(UsagePoolViewModel.resetUseText(Self.now, now: Self.now) == "Use now")
        #expect(UsagePoolViewModel.resetUseText(Self.now.addingTimeInterval(-1), now: Self.now) == "Use now")
    }

    @Test func codexDotUsesTheCurrentAccountSelection() throws {
        let state = try Self.captureFixture()
        let account = try #require(state.codexAccount)
        let row = UsagePoolFleet.row(account, name: "Login", now: state.model.now)
        #expect(UsagePoolAccountDot(status: row.status).color == .green)
    }

    @Test func freshCodexWeeklyUsageSurvivesMissingPaceAndPlan() throws {
        let state = UsagePoolPresentation()
        // Synthetic reading 13 minutes into a weekly window.
        let now = Self.date("2026-11-06T11:13:00Z")
        let banked = try JSONDecoder().decode(CodexResetCredits.self, from: Data(
            #"{"available_count":1,"credits":[{"id":"invented-fresh-reset","status":"available","expires_at":"2026-11-06T23:21:00Z"}]}"#.utf8))
        state.update(accounts: [], codex: .init(primary: Self.window(2, "2026-11-13T11:00:00Z"),
            secondary: nil, codexResetCredits: banked, updatedAt: now), sources: [], now: now, codexCredits: Self.creditsFixture())
        #expect(state.codexAccount?.weekly?.usedPercent == 2)
        #expect(state.codexAccount?.weekly?.resetsAt == Self.date("2026-11-13T11:00:00Z"))
        #expect(state.model.codex?.assumptions.pace == nil)
        #expect(state.model.codex != nil)
        #expect(state.model.availableResets.count == 1)
        #expect(state.model.expiringCredit?.id == "invented-fresh-reset")
        #expect(state.model.comingUp.map(\.kind) == [.creditExpiry, .topUp])
        // Pace needs only the reading and clock, not a demand estimate: 2% used 13 minutes in is on pace.
        #expect(state.model.codexPosition.map(UsagePoolViewModel.paceState) == .onPace)
        #expect(state.errors.isEmpty)
        #expect(state.providerPlans.isEmpty)
        #expect(state.codexCredits != nil)
        state.tab = .codex
        let host = NSHostingView(rootView: UsagePoolPopoverView(state: state))
        // Same priming as the live panel: one layout pass measures the content before sizing.
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 680)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height <= 680 && host.fittingSize.height > 300, "\(host.fittingSize.height)")
    }

    @Test func overviewShowsOnlyTheActiveLoginAndCompactLabelsStayAccurate() throws {
        let state = try Self.captureFixture()
        #expect(state.accounts.first?.isActive == false)
        #expect(state.activeClaudeAccount?.isActive == true)
        #expect(state.accounts.filter { !$0.isActive }.count == 3)
        let active = try #require(state.activeClaudeAccount)
        #expect(state.accounts.filter(\.isActive).map(\.id) == [active.id])
        state.hideNames = true
        #expect(state.name(active, index: state.accounts.firstIndex { $0.isActive }!).hasPrefix("Login "))
        // With no chosen login (personal overflow only), Overview never stands in a saved login.
        let idle = UsagePoolPresentation()
        idle.update(accounts: state.accounts.map { account in
            .init(id: account.id, displayName: account.displayName, weekly: account.weekly, session: account.session,
                  scoped: account.scoped, measuredAt: account.measuredAt, refusedSince: account.refusedSince,
                  isActive: false, isPersonal: account.isPersonal, isRateLimited: account.isRateLimited)
        }, codex: nil, sources: [], now: state.model.now)
        #expect(idle.accounts.count == 4)
        #expect(idle.activeClaudeAccount == nil)
    }

    /// During personal overflow, the active dot and Overview follow the signed-in login, not the
    /// chosen work login used for planning.
    @Test func activeDotFollowsTheSignedInLoginDuringOverflow() throws {
        let usage = Data("""
        {"schemaVersion":2,"accounts":{
          "1":{"fetchedAt":\(Self.now.timeIntervalSince1970),"lastGood":{"seven_day":{"pct":80,"resets_at":"2026-11-11T02:00:00Z"}}},
          "2":{"fetchedAt":\(Self.now.timeIntervalSince1970),"lastGood":{"seven_day":{"pct":95,"resets_at":"2026-11-09T19:00:00Z"}}}
        }}
        """.utf8)
        func sequence(active: Int) -> Data {
            Data("""
            {"activeAccountNumber":\(active),"accounts":{"1":{"email":"invented-personal@example.invalid"},
              "2":{"email":"invented-work@example.invalid","alias":"invented-work-1"}}}
            """.utf8)
        }
        let umbrella = Data(#"{"enabled":true,"personal":"invented-personal@example.invalid"}"#.utf8)
        let state = Data(#"{"chosen_work":["invented-work@example.invalid","invented-org"]}"#.utf8)
        let overflow = try UsagePoolClaudeCache.accounts(
            usage: usage, sequence: sequence(active: 1), umbrella: umbrella, umbrellaState: state, now: Self.now)
        #expect(overflow.map(UsagePoolViewModel.isInUse) == [true, false])
        #expect(overflow[1].isActive, "the forecast still plans around the chosen work login")
        #expect(UsagePoolViewModel.role(overflow[0]) == "Active · overflow")
        #expect(UsagePoolViewModel.role(overflow[1]) == "Returns after overflow")
        let presentation = UsagePoolPresentation()
        presentation.update(accounts: overflow, codex: nil, sources: [], now: Self.now)
        #expect(presentation.activeClaudeAccount?.displayName == "Personal")
        #expect(presentation.model.claude != nil)
        let back = try UsagePoolClaudeCache.accounts(
            usage: usage, sequence: sequence(active: 2), umbrella: umbrella, umbrellaState: state, now: Self.now)
        presentation.update(accounts: back, codex: nil, sources: [], now: Self.now)
        #expect(presentation.activeClaudeAccount?.displayName == "invented-work-1")
        #expect(UsagePoolViewModel.role(back[0]) == "Automatic overflow")
    }

    @Test func claudeSwapWatcherSeesReplacedAndRewrittenSequence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-cswap-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sequence.json")
        try Data(#"{"activeAccountNumber":2}"#.utf8).write(to: file)
        let counter = WatchCounter()
        let watcher = ClaudeSwapStateWatcher(directory: directory) { counter.increment() }
        func waitForChange(after count: Int) async throws -> Bool {
            for _ in 0..<100 {
                if counter.value > count { return true }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        // claude-swap style: write a new file and rename it over the old one.
        try Data(#"{"activeAccountNumber":1}"#.utf8).write(to: file, options: .atomic)
        #expect(try await waitForChange(after: 0))
        let afterReplace = counter.value
        // An in-place write to the replacement file is seen too.
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
        #expect(try await waitForChange(after: afterReplace))
        withExtendedLifetime(watcher) {}
    }

    @Test func claudeSwapWatcherAttachesLateAndAfterTheFolderIsReplaced() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmeter-cswap-recover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("state", isDirectory: true)
        let file = directory.appendingPathComponent("sequence.json")
        let counter = WatchCounter()
        let watcher = ClaudeSwapStateWatcher(directory: directory, retryInterval: 0.1) { counter.increment() }
        func waitForChange(after count: Int) async throws -> Bool {
            for _ in 0..<150 {
                if counter.value > count { return true }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return false
        }
        // Absent at start: the slow retry attaches once the folder appears.
        try await Task.sleep(nanoseconds: 150_000_000)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"activeAccountNumber":1}"#.utf8).write(to: file)
        #expect(try await waitForChange(after: 0))
        // Writes inside the newly attached folder are seen.
        var count = counter.value
        try Data(#"{"activeAccountNumber":2}"#.utf8).write(to: file, options: .atomic)
        #expect(try await waitForChange(after: count))
        // The whole folder is replaced: move it aside and create a fresh one.
        try await Task.sleep(nanoseconds: 400_000_000)
        count = counter.value
        try FileManager.default.moveItem(at: directory, to: parent.appendingPathComponent("old", isDirectory: true))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"activeAccountNumber":3}"#.utf8).write(to: file)
        #expect(try await waitForChange(after: count))
        try await Task.sleep(nanoseconds: 400_000_000)
        count = counter.value
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
        #expect(try await waitForChange(after: count), "the replacement folder's file is watched")
        withExtendedLifetime(watcher) {}
    }

    @Test func pastTopUpsUseOneLabelAndNeverClaimExhaustion() throws {
        let window = Self.window(100, "2026-11-04T22:00:00Z")
        let account = UsagePoolForecast.Account(id: "invented-past", displayName: "Invented past",
            weekly: window, refusedSince: Self.now, isRateLimited: true)
        #expect(UsagePoolViewModel.topUpText(window, unreadable: true, now: Self.now) == "Topped up 4 Nov, 22:00")
        #expect(UsagePoolViewModel.role(account) == "Rate-limited")
        #expect(UsagePoolViewModel.usageText(window, unreadable: true, estimated: true, now: Self.now) == "100% used")
        let future = Self.window(94, "2026-11-09T19:00:00Z")
        #expect(UsagePoolViewModel.usageText(future, unreadable: true, estimated: true, now: Self.now) == "94% used")
        #expect(UsagePoolViewModel.topUpText(future, unreadable: true, now: Self.now) == "Tops up Mon 19:00")
    }

    @Test func readableExpiredSessionsAreHiddenWhileUnreadableLastReadingsRemain() {
        for offset in [-1.0, 0, 1] {
            for unreadable in [false, true] {
                let session = RateWindow(usedPercent: 69, windowMinutes: 300,
                    resetsAt: Self.now.addingTimeInterval(offset), resetDescription: nil)
                let account = UsagePoolForecast.Account(id: "invented-session", displayName: "Invented session",
                    weekly: nil, session: session, refusedSince: unreadable ? Self.now : nil)
                #expect(UsagePoolViewModel.showsSession(account, now: Self.now) == (offset > 0 || unreadable))
            }
        }
        let noClock = UsagePoolForecast.Account(id: "invented-no-clock", displayName: "Invented no clock",
            weekly: nil, session: .init(usedPercent: 69, windowMinutes: 300, resetsAt: nil, resetDescription: nil))
        #expect(!UsagePoolViewModel.showsSession(noClock, now: Self.now))
    }

    @Test func cacheRead429IsRateLimitedAndLowUsageIsNeverExhausted() throws {
        let accounts = try UsagePoolClaudeCache.accounts(
            usage: Data(#"{"schemaVersion":2,"accounts":{"1":{"lastError":"http-429","fetchedAt":1793958600,"lastGood":{"seven_day":{"pct":41,"resets_at":"2026-11-09T19:00:00Z"}}}}}"#.utf8),
            sequence: Data(#"{"accounts":{"1":{}}}"#.utf8), umbrella: Data(#"{"enabled":false}"#.utf8), now: Self.now)
        let account = try #require(accounts.first)
        #expect(UsagePoolViewModel.role(account) == "Rate-limited")
        let weekly = try #require(account.weekly)
        #expect(UsagePoolViewModel.usageText(weekly, unreadable: true, estimated: true, now: Self.now) == "41% used")
        #expect(UsagePoolViewModel.topUpText(weekly, unreadable: true, now: Self.now) == "Tops up Mon 19:00")
    }

    // Invented engine regression inputs. Review captures use the synthetic schema 2 cache below.
    // Spend uses entirely synthetic daily usage counters.
    static let now = date("2026-11-06T09:50:00Z")
    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    static func window(_ used: Double, _ reset: String, minutes: Int = 10080) -> RateWindow {
        .init(usedPercent: used, windowMinutes: minutes, resetsAt: self.date(reset), resetDescription: nil)
    }

    static func fixture() throws -> UsagePoolPresentation {
        let state = UsagePoolPresentation()
        let accounts: [UsagePoolForecast.Account] = [
            .init(id: "invented-work-1", displayName: "Work-1",
                  weekly: self.window(65, "2026-11-09T19:00:00Z"),
                  session: self.window(14, "2026-11-06T14:10:00Z", minutes: 300),
                  measuredAt: self.now, isActive: true),
            .init(id: "invented-personal", displayName: "Personal",
                  weekly: self.window(69, "2026-11-11T02:00:00Z"), measuredAt: self.now, isPersonal: true),
            .init(id: "invented-work-2", displayName: "Work-2",
                  weekly: self.window(95, "2026-11-04T22:00:00Z"),
                  measuredAt: self.date("2026-11-03T09:00:00Z"), refusedSince: self.date("2026-11-03T09:00:00Z")),
            .init(id: "invented-work-3", displayName: "Work-3",
                  weekly: self.window(95, "2026-11-09T14:00:00Z"),
                  measuredAt: self.date("2026-11-03T09:00:00Z"), refusedSince: self.date("2026-11-03T09:00:00Z")),
        ]
        let credits = try JSONDecoder().decode(CodexResetCredits.self, from: Data("""
        {"available_count":3,"credits":[
          {"id":"invented-reset-one","status":"available","expires_at":"2026-11-06T23:21:00Z"},
          {"id":"invented-reset-two","status":"available","expires_at":"2026-11-30T19:54:00Z"},
          {"id":"invented-reset-three","status":"available","expires_at":"2026-12-01T22:28:00Z"}
        ]}
        """.utf8))
        let snapshot = UsageSnapshot(primary: nil, secondary: self.window(33, "2026-11-12T09:18:00Z"),
                                     codexResetCredits: credits, updatedAt: self.now,
                                     identity: .init(providerID: .codex, accountEmail: nil, accountOrganization: nil, loginMethod: "pro"))
        let sources = try Self.cachedSpendSources()
        state.update(accounts: accounts, codex: snapshot, sources: sources,
                     claudeSnapshot: .init(primary: nil, secondary: nil, updatedAt: self.now,
                                           identity: .init(providerID: .claude, accountEmail: nil, accountOrganization: nil, loginMethod: "max")),
                     labels: ["slot:1": "Work-1"],
                     now: self.now, paces: [
                        .claude: try .init(unitsPerDay: 51, assumption: "51 points/day fixture"),
                        .codex: try .init(unitsPerDay: 32, assumption: "32 points/day fixture"),
                     ])
        return state
    }

    static func captureFixture() throws -> UsagePoolPresentation {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/usage-pool-cache-synthetic.json")
        let data = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let now = Date(timeIntervalSince1970: try #require(data["capturedAt"] as? Double))
        func bytes(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: #require(data[key])) }
        let accounts = try UsagePoolClaudeCache.accounts(usage: bytes("usage"), sequence: bytes("sequence"),
            umbrella: bytes("umbrella"), umbrellaState: bytes("umbrellaState"), now: now)
        let old = try Self.fixture()
        let state = UsagePoolPresentation()
        state.update(accounts: accounts, codex: .init(primary: nil,
            secondary: old.model.codex?.accounts.first?.weekly, codexResetCredits: old.model.resetCredits,
            updatedAt: now, identity: .init(providerID: .codex, accountEmail: nil, accountOrganization: nil, loginMethod: "pro")),
            sources: try Self.cachedSpendSources(),
            claudeSnapshot: .init(primary: nil, secondary: nil, updatedAt: now,
                identity: .init(providerID: .claude, accountEmail: nil, accountOrganization: nil, loginMethod: "max")),
            now: now, codexCredits: Self.creditsFixture(),
            creditsPurchaseURL: "https://chatgpt.com/codex/settings/usage")
        return state
    }

    // Invented history counters for credits-row QA, not a live usage reading.
    static func creditsFixture() -> CreditsSnapshot {
        .init(remaining: 60101.12, events: [
            .init(date: Self.now, service: "Invented Codex usage", creditsUsed: 12.5),
            .init(date: Self.now.addingTimeInterval(-3600), service: "Invented Codex usage", creditsUsed: 7.5),
        ], updatedAt: Self.now)
    }

    @Test(arguments: [true, false])
    func creditsRowUsesReportedHistoryAndHidesWithoutCredits(hasCredits: Bool) throws {
        let state = UsagePoolPresentation()
        state.update(accounts: [], codex: nil, sources: [], now: Self.now,
            codexCredits: hasCredits ? Self.creditsFixture() : nil,
            creditsPurchaseURL: "https://chatgpt.com/codex/settings/usage?ignored=1#credits")
        #expect(state.creditsPurchaseURL?.absoluteString == "https://chatgpt.com/codex/settings/usage")
        if hasCredits {
            let credits = try #require(state.codexCredits)
            let balance = UsageFormatter.creditsString(from: credits.remaining)
            #expect(balance == "60,101.12 left")
            #expect(state.creditsUsageText == "Used so far: 20 credits")
        } else {
            #expect(state.codexCredits == nil)
            #expect(state.creditsUsageText == nil)
        }
        let host = NSHostingView(rootView: UsagePoolPopoverView(state: state).creditsRow.frame(width: 348))
        #expect(hasCredits ? host.fittingSize.height > 40 : host.fittingSize.height == 0)
        state.update(accounts: [], codex: nil, sources: [], now: Self.now,
            codexCredits: .init(remaining: 0, events: [], updatedAt: Self.now),
            creditsPurchaseURL: "https://example.invalid/credits")
        #expect(state.codexCredits?.remaining == 0)
        #expect(state.creditsUsageText == nil)
        #expect(state.creditsPurchaseURL == nil)
    }

    @Test func unreadableLoginRenderingKeepsRecordedBarsAndPassedTopUp() throws {
        let state = try Self.captureFixture()
        #expect(state.accounts.count == 4)
        let refused = state.accounts.filter { $0.refusedSince != nil }
        #expect(refused.count == 2)
        for account in refused {
            let window = try #require(account.weekly)
            #expect(window.usedPercent == 95)
            #expect(UsagePoolViewModel.usageText(window, unreadable: true, estimated: true, now: state.model.now) ==
                "95% used")
            #expect(UsagePoolViewModel.lastReadText(account, now: state.model.now).hasPrefix("Last read "))
            #expect(UsagePoolViewModel.topUpDate(window, unreadable: true, now: state.model.now) == window.resetsAt)
        }
        #expect(UsagePoolViewModel.isAwaitingTopUpRead(try #require(refused.first?.weekly), unreadable: true, now: state.model.now))
        #expect(!UsagePoolViewModel.isAwaitingTopUpRead(try #require(refused.last?.weekly), unreadable: true, now: state.model.now))
        let account = UsagePoolForecast.Account(id: "invented-age", displayName: "invented-age",
            weekly: nil, measuredAt: Self.now.addingTimeInterval(-7200), refusedSince: Self.now)
        #expect(UsagePoolViewModel.lastReadText(account, now: Self.now) == "Last read 2h ago")
        #expect(UsagePoolViewModel.usageText(Self.window(41, "2026-11-09T19:00:00Z"), unreadable: true, estimated: true, now: Self.now) == "41% used")
        let unreadable = UsagePoolPresentation()
        unreadable.update(accounts: refused, codex: nil, sources: [], now: state.model.now)
        #expect(unreadable.accounts.count == 2)
        #expect(unreadable.model.claude == nil)
        // Their recorded bars stay, but stale readings never drive pace.
        #expect(unreadable.model.overallPaceTitle == "No pace")
        #expect(unreadable.model.claudePosition?.contributions.isEmpty == true)
    }

    @Test func scopedLimitsOnlyRenderWindowsReportedByEachLogin() throws {
        let usage = Data(#"{"schemaVersion":2,"accounts":{"1":{"fetchedAt":1793958600,"lastGood":{"seven_day":{"pct":65},"scoped":[]}},"2":{"fetchedAt":1793958600,"lastGood":{"seven_day":{"pct":95},"scoped":[{"name":"Fable","pct":13}]}}}}"#.utf8)
        let accounts = try UsagePoolClaudeCache.accounts(usage: usage,
            sequence: Data(#"{"accounts":{"1":{},"2":{}}}"#.utf8), umbrella: Data(#"{"enabled":false}"#.utf8), now: Self.now)
        #expect(accounts[0].scoped.isEmpty)
        #expect(accounts[1].scoped.map(\.title) == ["Fable"])
        let fixture = try Self.captureFixture()
        #expect(fixture.accounts.flatMap(\.scoped).allSatisfy { $0.title == "Fable" })
    }

    @Test func cacheOnlyLoginSurvivesMissingSequenceMetadata() throws {
        let accounts = try UsagePoolClaudeCache.accounts(
            usage: Data(#"{"schemaVersion":2,"accounts":{"5":{"lastError":"http-403","fetchedAt":1793958600,"lastGood":{"seven_day":{"pct":99}}}}}"#.utf8),
            sequence: Data(#"{"accounts":{}}"#.utf8), umbrella: Data(#"{"enabled":false}"#.utf8), now: Self.now)
        #expect(accounts.count == 1)
        #expect(accounts[0].id == "claude:cswap:5")
        #expect(accounts[0].weekly?.usedPercent == 99)
        #expect(accounts[0].refusedSince != nil)
    }

    @Test func qaTabOptInIgnoresNormalAndInvalidLaunches() {
        #expect(StatusItemController.qaPopoverTab(environment: [:]) == nil)
        #if !DEBUG
        #expect(StatusItemController.qaPopoverTab(environment: ["AGENTMETER_QA_POPOVER_TAB": "overview"]) == nil)
        #expect(StatusItemController.qaPopoverTab(environment: ["AGENTMETER_QA_POPOVER_TAB": "overview", "AGENTMETER_QA_ALLOW": "0"]) == nil)
        #endif
        #expect(StatusItemController.qaPopoverTab(environment: ["AGENTMETER_QA_POPOVER_TAB": "invalid"]) == nil)
        for tab in UsagePoolViewModel.Tab.allCases {
            #expect(StatusItemController.qaPopoverTab(environment: ["AGENTMETER_QA_POPOVER_TAB": tab.rawValue, "AGENTMETER_QA_ALLOW": "1"]) == tab)
        }
        let qa = ["AGENTMETER_QA_POPOVER_TAB": "analytics", "AGENTMETER_QA_ALLOW": "1"]
        #expect(StatusItemController.qaAnalyticsRange(environment: ["AGENTMETER_QA_ANALYTICS_RANGE": "7d"]) == nil)
        #expect(StatusItemController.qaAnalyticsRange(environment: qa) == nil)
        for (value, window) in [("today", AllAccountsDashboardModel.Window.today), ("7d", .week), ("30d", .thirtyDays), ("month", .month)] {
            #expect(StatusItemController.qaAnalyticsRange(environment: qa.merging(["AGENTMETER_QA_ANALYTICS_RANGE": value]) { $1 }) == window)
        }
        #expect(AllAccountsDashboardModel.Window.allCases.map(\.rawValue) == ["Today", "7d", "30d", "This month"])
    }

    static func cachedSpendSources() throws -> [SharedCostUsage.Source] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/usage-pool-spend-synthetic.json")
        let aggregate = try SharedCostUsage.read(at: url)
        return aggregate.engines.map { .init(user: NSUserName(), usage: $0, stale: false) }
    }

    @Test func overviewOrdersActionsAndKeepsProviderRunwaysSeparate() throws {
        let state = try Self.fixture()
        #expect(state.errors.isEmpty)
        #expect(state.model.results.count == 2)
        #expect(state.model.comingUp.map(\.at) == state.model.comingUp.map(\.at).sorted())
        #expect(state.model.nextAction?.kind == .redeemCredit)
        #expect(state.model.expiringReset?.at == Self.date("2026-11-06T23:16:00Z"))
        #expect(state.model.menuBarText.contains("23:16"))
        #expect(state.model.menuBarText.hasSuffix("•"))
        #expect(state.model.claude?.ownRunwayUntil != state.model.codex?.ownRunwayUntil)
    }

    @Test func claudeScenariosRecomputeAndOnlyReportedSessionExists() throws {
        let state = try Self.fixture()
        let initial = try #require(state.model.claude)
        #expect(initial.accounts.filter { $0.session != nil }.count == 1)
        // Stale logins are never projected, so only the two fresh logins reach the forecast.
        #expect(initial.accounts.map(UsagePoolViewModel.role) == ["Active", "Automatic overflow"])
        state.selectScenario(.lastReading, for: "invented-work-2")
        #expect(state.model.claude?.actingRunwayUntil == initial.actingRunwayUntil)
        // The engine itself still models an unreadable login's scenario when asked directly.
        let dead = try UsagePoolForecast.forecast(
            provider: .claude, accounts: state.accounts, now: Self.now,
            pace: .init(unitsPerDay: 51, assumption: "51 points/day fixture"), scenarios: ["invented-work-2": .dead])
        let last = try UsagePoolForecast.forecast(
            provider: .claude, accounts: state.accounts, now: Self.now,
            pace: .init(unitsPerDay: 51, assumption: "51 points/day fixture"), scenarios: ["invented-work-2": .lastReading])
        #expect(try #require(last.actingRunwayUntil) > #require(dead.ownRunwayUntil))
        #expect(last.assumptions.scenarios["invented-work-2"] == .lastReading)
    }

    @Test func codexShowsWorthAndPlannedTimesWithoutRedemption() throws {
        let state = try Self.fixture()
        let result = try #require(state.model.codex)
        #expect(result.accounts.first?.session == nil)
        #expect(result.redemptions.count == 3)
        #expect(abs(try #require(result.redemptions.first).valuePercent - 50.91) < 0.02)
        #expect(result.redemptions.last?.at == Self.date("2026-11-13T05:16:00Z"))
        #expect(result.actingRunwayUntil == Self.date("2026-11-16T08:16:00Z"))
    }

    @Test func bankedResetsNumberOnceAndMatchTheCount() throws {
        let state = try Self.fixture()
        let model = state.model
        let rows = model.bankedResets
        #expect(rows.map(\.number) == Array(1...rows.count))
        #expect(model.bankedResetCount == rows.count + (model.codex?.unplannedCreditCount ?? 0))
        let expiries = rows.compactMap(\.expiresAt)
        #expect(expiries == expiries.sorted() && expiries.allSatisfy { $0 > Self.now })
        // Every planned redemption that matches an available credit is attached to exactly one row.
        let attached = rows.compactMap(\.redemption?.creditID)
        #expect(Set(attached).count == attached.count)
        // Expired and redeemed credits never appear, and a redemption with no available credit adds no row.
        let credits = try JSONDecoder().decode(CodexResetCredits.self, from: Data("""
        {"available_count":3,"credits":[
          {"id":"invented-late","status":"available","expires_at":"2026-12-01T22:28:00Z"},
          {"id":"invented-early","status":"available","expires_at":"2026-11-30T19:54:00Z"},
          {"id":"invented-expired","status":"available","expires_at":"2026-11-01T00:00:00Z"},
          {"id":"invented-spent","status":"redeemed","expires_at":"2026-11-20T00:00:00Z"}]}
        """.utf8))
        let bare = UsagePoolViewModel(now: Self.now, claude: nil, codex: nil, resetCredits: credits)
        #expect(bare.bankedResets.map(\.number) == [1, 2])
        #expect(bare.bankedResets.map(\.expiresAt) == [Self.date("2026-11-30T19:54:00Z"), Self.date("2026-12-01T22:28:00Z")])
        #expect(bare.bankedResets.allSatisfy { $0.redemption == nil })
    }

    @Test func resetsWithoutIDsSharingAnExpiryKeepTheirOwnPlans() throws {
        let credits = try JSONDecoder().decode(CodexResetCredits.self, from: Data("""
        {"available_count":2,"credits":[
          {"status":"available","expires_at":"2026-11-30T19:54:00Z"},
          {"status":"available","expires_at":"2026-11-30T19:54:00Z"}]}
        """.utf8))
        let account = UsagePoolForecast.Account(id: "codex", displayName: "Codex",
            weekly: Self.window(90, "2026-11-12T09:18:00Z"), measuredAt: Self.now, isActive: true)
        let result = try UsagePoolForecast.forecast(
            provider: .codex, accounts: [account], now: Self.now,
            pace: .init(unitsPerDay: 60, assumption: "Invented heavy fixture"), credits: credits)
        try #require(result.redemptions.count == 2)
        let model = UsagePoolViewModel(now: Self.now, claude: nil, codex: result, resetCredits: credits)
        let plans = model.bankedResets.compactMap(\.redemption)
        #expect(plans.count == 2)
        #expect(Set(plans.map(\.creditID)).count == 2)
        #expect(Set(plans.map(\.at)) == Set(result.redemptions.map(\.at)))
    }

    @Test func analyticsEmailLabelsUseTheirOwnCollectionIndex() throws {
        let rows = (0..<3).map { index in
            AllAccountsDashboardModel.Row(id: "invented-\(index)", label: "invented\(index)@example.invalid",
                tokens: 10, cost: 1)
        }
        for collection in ["sources", "models", "subscriptions"] {
            var model = AllAccountsDashboardModel(scope: .codex, tokens: 30, cost: 3, todayTokens: 30,
                todayCost: 3, days: [], sources: collection == "sources" ? rows : [], engines: [],
                tokenTypes: [], models: collection == "models" ? rows : [])
            if collection == "subscriptions" { model.subscriptions = rows }
            let view = AllAccountsUsageCard(model: model, width: 348, hideNames: false)
            #expect(rows.enumerated().map { view.displayLabel($0.element) } == ["Login 1", "Login 2", "Login 3"])
        }
    }

    @Test func analyticsRestoresThirtyDaysTokenMixModelsAccountsAndPrivacy() throws {
        let state = try Self.fixture()
        let sources = try Self.cachedSpendSources()
        let analytics = try #require(state.analytics)
        #expect(state.analyticsWindow == .thirtyDays)
        #expect(analytics.days.count == 30)
        #expect(analytics.tokens == sources.flatMap { $0.usage.report.data }.compactMap(\.totalTokens).reduce(0, +))
        for day in analytics.days {
            let cached = sources.flatMap { $0.usage.report.data }.filter { $0.date == day.id }
            #expect(day.values.reduce(0, +) == cached.compactMap(\.totalTokens).reduce(0, +))
        }
        #expect(analytics.engines.allSatisfy { $0.tokens > 0 && $0.cost > 0 })
        #expect(analytics.tokenTypes.count == 4)
        #expect(analytics.models.contains { $0.label == "gpt-6.1-sol" && $0.cost > 0 })
        #expect(!analytics.subscriptions.isEmpty)
        state.hideNames = true
        for event in state.model.comingUp where state.accounts.contains(where: { $0.id == event.accountID }) {
            let account = try #require(state.accounts.first { $0.id == event.accountID })
            #expect(state.eventWording(event).contains(state.name(account, index: 0)))
            #expect(!state.eventWording(event).contains(account.displayName))
        }
        let view = AllAccountsUsageCard(model: analytics, width: 404, showsDetails: true, hideNames: true)
        #expect(view.displayLabel(try #require(analytics.subscriptions.first)) == "Login 1")
        #expect(view.displayLabel(try #require(analytics.sources.first)).hasPrefix("User 1"))
        state.analyticsWindow = .week
        #expect(state.analytics?.days.count == 7)
        let weekEntries = sources.flatMap { $0.usage.report.data }.filter {
            $0.date >= "2026-10-31" && $0.date <= "2026-11-06"
        }
        let weekTokens = weekEntries.compactMap(\.totalTokens).reduce(0, +)
        #expect(state.analytics?.tokens == weekTokens)
        state.analyticsWindow = .month
        #expect(state.analytics?.days.count == 6)
        #expect(state.analytics?.days.first?.id == "2026-11-01")
    }

    /// Stale logins never drive pace. With no fresh Claude login there is no Claude pace
    /// or forecast, and the popover says why instead of going quiet.
    @Test func allUnreadableLoginsLeaveClaudePaceUnavailableAndSaySo() throws {
        let state = UsagePoolPresentation()
        let accounts = [UsagePoolForecast.Account(
            id: "invented-rate-limited", displayName: "Invented rate limited",
            weekly: Self.window(95, "2026-11-09T19:00:00Z"),
            measuredAt: Self.now.addingTimeInterval(-93 * 3600), refusedSince: Self.now)]
        state.update(accounts: accounts, codex: .init(
            primary: nil, secondary: Self.window(33, "2026-11-12T09:18:00Z"), updatedAt: Self.now),
            sources: [], now: Self.now)
        #expect(state.model.claude == nil, "no readable login: the forecast cannot run")
        let claude = try #require(state.model.claudePosition)
        #expect(claude.contributions.isEmpty)
        #expect(claude.delta == nil)
        #expect(state.model.providerPaceLines.first == "Claude unreadable")
        #expect(!state.model.mixedPace)
        #expect(state.errors == ["Claude: no fresh reading, so pace and runway wait for one"])
    }

    @Test func providerPlansCostsAndColoursStaySiloed() throws {
        let state = try Self.fixture()
        #expect(state.providerPlans[.claude]?.lowercased() == "max")
        #expect(state.providerPlans[.codex] == "Pro 20x")
        for provider in [UsageProvider.claude, .codex] {
            let cost = try #require(state.providerCosts[provider])
            #expect(cost.sources.allSatisfy { $0.engine == provider.rawValue })
            let view = AllAccountsUsageCard(model: cost, width: 348, showsDetails: true)
            let expected = try #require(NSColor(UsageMenuCardView.Model.progressColor(for: provider)).usingColorSpace(.deviceRGB))
            let row = try #require(cost.sources.first)
            var shades: [NSColor] = []
            for shade in [0, 1] {
                var source = row
                source.shade = shade
                let color = try #require(NSColor(view.color(source)).usingColorSpace(.deviceRGB))
                if shade == 0 || provider == .codex {
                    #expect(abs(color.hueComponent - expected.hueComponent) < 0.001)
                    #expect(abs(color.saturationComponent - expected.saturationComponent) < 0.001)
                } else {
                    #expect(color.redComponent > color.greenComponent && color.greenComponent > color.blueComponent)
                    let distance = abs(color.redComponent - expected.redComponent)
                        + abs(color.greenComponent - expected.greenComponent) + abs(color.blueComponent - expected.blueComponent)
                    #expect(distance > 0.25)
                }
                #expect(abs(color.alphaComponent - (shade == 0 || provider == .claude ? 1 : 0.55)) < 0.001)
                shades.append(color)
            }
            #expect(shades[0] != shades[1])
        }
        let foreignIdentity = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Self.now,
            identity: .init(providerID: .claude, accountEmail: nil, accountOrganization: nil, loginMethod: "max"))
        state.update(accounts: [], codex: foreignIdentity, sources: [], now: Self.now)
        #expect(state.providerPlans[.codex] == nil)
        #expect(state.providerCosts.isEmpty)
    }

    @Test func analyticsMonthIncludesTheThirtyFirstDayAndExcludesFutureRows() throws {
        let now = Self.date("2026-10-31T12:00:00Z")
        let entries: [CostUsageDailyReport.Entry] = [
            .init(date: "2026-09-30", inputTokens: nil, outputTokens: nil, totalTokens: 100, costUSD: 100, modelsUsed: nil, modelBreakdowns: nil),
            .init(date: "2026-10-01", inputTokens: nil, outputTokens: nil, totalTokens: 1, costUSD: 1, modelsUsed: nil, modelBreakdowns: nil),
            .init(date: "2026-10-31", inputTokens: nil, outputTokens: nil, totalTokens: 2, costUSD: 2, modelsUsed: nil, modelBreakdowns: nil),
            .init(date: "2026-11-01", inputTokens: nil, outputTokens: nil, totalTokens: 100, costUSD: 100, modelsUsed: nil, modelBreakdowns: nil),
        ]
        let cost = CostUsageTokenSnapshot(sessionTokens: nil, sessionCostUSD: nil,
            last30DaysTokens: nil, last30DaysCostUSD: nil, daily: entries, updatedAt: now)
        let sources = [SharedCostUsage.Source(user: NSUserName(), usage: .init(provider: .claude, snapshot: cost), stale: false)]
        let month = try #require(AllAccountsDashboardModel.make(sources: sources, window: .month, now: now))
        #expect(month.tokens == 3 && month.cost == 3 && month.days.count == 31)
        let thirtyDays = try #require(AllAccountsDashboardModel.make(sources: sources, now: now))
        #expect(thirtyDays.tokens == 2 && thirtyDays.days.count == 30)
    }

    @Test func morningPaceIgnoresBankedResetsAndCountsEstimatedUnreadableLogins() throws {
        let state = try Self.fixture()
        let claude = try #require(state.model.claude)
        let claudePace = UsagePoolForecast.pacePosition(results: [claude], now: Self.now)
        // Only the two fresh logins count; the two unreadable ones never drive pace.
        #expect(claudePace.contributions.count == 2)
        #expect(claudePace.excludedAccountIDs.isEmpty)
        let logins = UsagePoolViewModel.loginPaces(claudePace, accounts: state.accounts)
        #expect(logins.map(\.accountID) == ["invented-work-1", "invented-personal"])
        #expect(UsagePoolViewModel.averagedLogins(state.model.claudePosition) == 2)
        // Both providers are ahead, so the overall is the larger one, not Mixed.
        #expect(state.model.overallPaceTitle == "Fast +25")
        #expect(state.model.providerPaceLines == ["Claude \(UsagePoolViewModel.paceShort(claudePace))", "Codex +18"])
        let codex = try #require(state.model.codex)
        #expect(codex.redemptions.isEmpty == false)
        // The three banked resets add nothing: Codex is its one weekly clock, 18.396825 points ahead.
        let codexPace = try #require(state.model.codexPosition)
        #expect(codexPace.contributions.count == 1)
        #expect(abs(try #require(codexPace.delta) - 0.18396825) < 0.0001)
        #expect(UsagePoolForecast.pacePosition(results: [codex], now: Self.now).delta == codexPace.delta)
        // The forecast scenario for an unreadable login no longer changes how pace counts it.
        state.selectScenario(.lastReading, for: "invented-work-3")
        let changedClaude = try #require(state.model.claude)
        #expect(UsagePoolForecast.pacePosition(results: [changedClaude], now: Self.now).delta == claudePace.delta)
    }

    /// Weekly pace compares used quota with elapsed time, independently of banked resets. 25% used
    /// 19 hours into the week is fast by about 14 points.
    @Test func codexPaceIsUsedAgainstElapsedEvenWithBankedResets() throws {
        let now = Self.date("2026-11-03T03:00:00Z")
        let banked = try JSONDecoder().decode(CodexResetCredits.self, from: Data("""
        {"available_count":3,"credits":[
          {"id":"invented-soon","status":"available","expires_at":"2026-11-04T04:00:00Z"},
          {"id":"invented-later","status":"available","expires_at":"2026-11-07T04:00:00Z"},
          {"id":"invented-latest","status":"available","expires_at":"2026-11-26T04:00:00Z"}
        ]}
        """.utf8))
        func model(used: Double, now: Date) -> UsagePoolViewModel {
            let state = UsagePoolPresentation()
            state.update(accounts: [], codex: .init(primary: nil, secondary: Self.window(used, "2026-11-09T08:00:00Z"),
                codexResetCredits: banked, updatedAt: now), sources: [], now: now,
                paces: [.codex: try! .init(unitsPerDay: 32, assumption: "Invented 32 points/day")])
            return state.model
        }
        let early = model(used: 25, now: now)
        #expect(early.codex?.redemptions.isEmpty == false)
        let elapsed = now.timeIntervalSince(Self.date("2026-11-02T08:00:00Z")) / 604800
        let delta = try #require(early.codexPosition?.delta)
        #expect(abs(delta - (0.25 - elapsed)) < 0.000001)
        #expect(Int((delta * 100).rounded()) == 14)
        #expect(UsagePoolViewModel.paceState(try #require(early.codexPosition)) == .ahead)
        #expect(early.overallPaceState == .ahead)
        #expect(early.overallPaceTitle == "Fast +14")
        #expect(early.overallPaceDetail == nil)
        #expect(early.providerPaceLines == ["Codex +14"])

        // Just after the reset, a little use is on pace.
        let fresh = model(used: 1, now: Self.date("2026-11-02T08:10:00Z"))
        #expect(UsagePoolViewModel.paceState(try #require(fresh.codexPosition)) == .onPace)
        // Near the next reset, nearly everything should be used: 95% is on pace, 60% is slow by 40.
        let late = Self.date("2026-11-09T07:50:00Z")
        #expect(UsagePoolViewModel.paceState(try #require(model(used: 95, now: late).codexPosition)) == .onPace)
        let slow = try #require(model(used: 60, now: late).codexPosition?.delta)
        #expect(Int((slow * 100).rounded()) == -40)
        #expect(model(used: 60, now: late).overallPaceDetail == nil)
    }

    @Test func steadyMarkerOnlyWithAKnownWindow() throws {
        let now = Self.date("2026-11-03T03:00:00Z")
        let weekly = try #require(UsagePoolViewModel.steadyPercent(Self.window(25, "2026-11-09T08:00:00Z"), now: now))
        #expect(abs(weekly - 100 * (19 * 60) / 10080) < 0.001)
        let session = try #require(UsagePoolViewModel.steadyPercent(Self.window(10, "2026-11-03T05:30:00Z", minutes: 300), now: now))
        #expect(abs(session - 50) < 0.001)
        #expect(UsagePoolViewModel.steadyPercent(Self.window(25, "2026-11-03T02:00:00Z"), now: now) == nil)
        #expect(UsagePoolViewModel.steadyPercent(.init(usedPercent: 25, windowMinutes: nil,
            resetsAt: Self.date("2026-11-09T08:00:00Z"), resetDescription: nil), now: now) == nil)
        #expect(UsagePoolViewModel.steadyPercent(.init(usedPercent: 25, windowMinutes: 10080,
            resetsAt: nil, resetDescription: nil), now: now) == nil)
    }

    @Test
    func fullWork3ScenarioEngineReproducer() throws {
        // The UI no longer forecasts stale logins, so the engine reproducer calls the engine directly.
        let state = try Self.fixture()
        let result = try UsagePoolForecast.forecast(
            provider: .claude, accounts: state.accounts, now: Self.now,
            pace: .init(unitsPerDay: 51, assumption: "51 points/day fixture"),
            scenarios: ["invented-work-3": .fullAfterPassedTopUp])
        #expect(result.assumptions.scenarios["invented-work-3"] == .fullAfterPassedTopUp)
    }

    @Test func tabNavigationWrapsAndPaceBoundaryIsInclusive() throws {
        #expect(UsagePoolViewModel.Tab.overview.moved(-1) == .spend)
        #expect(UsagePoolViewModel.Tab.spend.moved(1) == .overview)
        #expect(UsagePoolViewModel.Tab.allCases.count == 4)
        for (used, expected) in [(40.0, "On pace −10"), (61.0, "Fast +11"), (39.0, "Slow −11")] {
            let account = UsagePoolForecast.Account(
                id: "invented-boundary", displayName: "Invented boundary",
                weekly: .init(usedPercent: used, windowMinutes: 10080,
                              resetsAt: Self.now.addingTimeInterval(302400), resetDescription: nil), isActive: true)
            let result = try UsagePoolForecast.forecast(
                provider: .codex, accounts: [account], now: Self.now,
                pace: .init(unitsPerDay: 0, assumption: "Invented idle fixture"))
            #expect(UsagePoolViewModel.paceTitle(UsagePoolForecast.pacePosition(results: [result], now: Self.now)) == expected)
        }
    }

    @Test func overallPaceUsesWorstProviderAndNeverNetsOppositeErrors() throws {
        func result(_ provider: UsagePoolForecast.Provider, delta: Double) throws -> UsagePoolForecast.Result {
            let account = UsagePoolForecast.Account(
                id: "invented-overall", displayName: "Invented overall",
                weekly: .init(usedPercent: 50 + delta * 100, windowMinutes: 10080,
                              resetsAt: Self.now.addingTimeInterval(302400), resetDescription: nil),
                measuredAt: Self.now, isActive: true)
            return try UsagePoolForecast.forecast(provider: provider, accounts: [account], now: Self.now,
                                                  pace: .init(unitsPerDay: 0, assumption: "Invented idle fixture"))
        }
        for (claudeDelta, codexDelta, title) in [
            (0.20, -0.31, "Mixed"), (0.20, 0.05, "Fast +20"),
            (-0.20, -0.31, "Slow −31"), (0.10, -0.10, "On pace +10"),
        ] {
            let model = try UsagePoolViewModel(now: Self.now, claude: result(.claude, delta: claudeDelta),
                                               codex: result(.codex, delta: codexDelta))
            #expect(model.overallPaceTitle == title)
            if title == "Mixed" { #expect(model.overallPaceDetail == "Claude fast, Codex slow") }
            if title == "Mixed" { #expect(model.providerPaceLines == ["Claude +20", "Codex −31"]) }
            if title == "Slow −31" { #expect(model.overallPaceDetail == nil) }
        }
    }

    @Test func paceGaugeStatesFollowOverallRules() throws {
        func result(_ provider: UsagePoolForecast.Provider, delta: Double) throws -> UsagePoolForecast.Result {
            let account = UsagePoolForecast.Account(
                id: "invented-gauge", displayName: "Invented gauge",
                weekly: .init(usedPercent: 50 + delta * 100, windowMinutes: 10080,
                              resetsAt: Self.now.addingTimeInterval(302400), resetDescription: nil),
                measuredAt: Self.now, isActive: true)
            return try UsagePoolForecast.forecast(provider: provider, accounts: [account], now: Self.now,
                                                  pace: .init(unitsPerDay: 0, assumption: "Invented idle fixture"))
        }
        for (claudeDelta, codexDelta, state) in [
            (0.20, -0.31, UsagePoolViewModel.PaceState.mixed), (0.20, 0.05, .ahead),
            (-0.20, -0.31, .behind), (0.10, -0.10, .onPace), (0.05, 0.11, .ahead),
        ] {
            let model = try UsagePoolViewModel(now: Self.now, claude: result(.claude, delta: claudeDelta),
                                               codex: result(.codex, delta: codexDelta))
            #expect(model.overallPaceState == state)
        }
        #expect(UsagePoolViewModel(now: Self.now, claude: nil, codex: nil).overallPaceState == .unavailable)
        #expect(UsagePoolViewModel.paceGaugeFraction(0) == 0.5)
        #expect(UsagePoolViewModel.paceGaugeFraction(0.25) == 0.75)
        #expect(UsagePoolViewModel.paceGaugeFraction(-0.25) == 0.25)
        #expect(UsagePoolViewModel.paceGaugeFraction(0.9) == 1)
        #expect(UsagePoolViewModel.paceGaugeFraction(-0.9) == 0)
        #expect(UsagePoolViewModel.paceGaugeFraction(.nan) == 0.5)
    }

    @Test func coincidentGaugeMarkersStaySideBySide() {
        #expect(UsagePoolPaceGauge.separated([100, 100], gap: 22, lower: 10, upper: 338) == [89, 111])
        #expect(UsagePoolPaceGauge.separated([120, 110], gap: 22, lower: 10, upper: 338) == [126, 104])
        #expect(UsagePoolPaceGauge.separated([338, 338], gap: 22, lower: 10, upper: 338) == [316, 338])
        #expect(UsagePoolPaceGauge.separated([10, 338], gap: 22, lower: 10, upper: 338) == [10, 338])
        #expect(UsagePoolPaceGauge.separated([50], gap: 22, lower: 10, upper: 338) == [50])
    }

    @Test func onlyTheDismissingClickIsIgnored() throws {
        func mouse(_ type: NSEvent.EventType, _ number: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: number, clickCount: 1, pressure: 1))
        }
        #expect(UsagePoolPanel.isDismissingClick(try mouse(.leftMouseDown, 7), dismissingClick: 7))
        #expect(UsagePoolPanel.isDismissingClick(try mouse(.leftMouseUp, 7), dismissingClick: 7))
        #expect(!UsagePoolPanel.isDismissingClick(try mouse(.leftMouseUp, 8), dismissingClick: 7))
        #expect(!UsagePoolPanel.isDismissingClick(try mouse(.leftMouseUp, 7), dismissingClick: nil))
        #expect(!UsagePoolPanel.isDismissingClick(nil, dismissingClick: 7))
        let shortcut = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock],
            timestamp: 0, windowNumber: 0, context: nil, characters: "m", charactersIgnoringModifiers: "m",
            isARepeat: false, keyCode: 46))
        #expect(!UsagePoolPanel.isDismissingClick(shortcut, dismissingClick: 7))
    }

    @Test func panelFitsBetweenMenuBarAndDock() {
        // 1280x720 with a 24pt menu bar and a 72pt Dock: visible y 72...696.
        let visible = NSRect(x: 0, y: 72, width: 1280, height: 624)
        let anchor = NSRect(x: 1100, y: 696, width: 30, height: 24)
        let available = UsagePoolPanel.availableHeight(under: anchor, in: visible)
        #expect(available == CGFloat(610))
        let height = min(680, available)
        let origin = UsagePoolPanel.origin(for: NSSize(width: 380, height: height), under: anchor, in: visible)
        #expect(origin.y >= visible.minY + 8)
        #expect(origin.y + height <= anchor.minY - UsagePoolPanel.gapBelowMenuBar)
        #expect(origin.x + 380 <= visible.maxX - 8)
        // Even an oversized panel is never pushed below the Dock.
        #expect(UsagePoolPanel.origin(for: NSSize(width: 380, height: 900), under: anchor, in: visible).y == 80)
    }

    @Test func earlyWeekPaceSaysWhenItStarts() {
        func account(started hours: Double, refused: Bool = false) -> UsagePoolForecast.Account {
            .init(id: "codex", displayName: "Codex",
                  weekly: .init(usedPercent: 2, windowMinutes: 10080,
                                resetsAt: Self.now.addingTimeInterval(7 * 86400 - hours * 3600), resetDescription: nil),
                  refusedSince: refused ? Self.now : nil, isActive: true)
        }
        let early = account(started: 1.5)
        #expect(UsagePoolViewModel.paceStartDate(early, now: Self.now) == Self.now.addingTimeInterval(4.5 * 3600))
        #expect(UsagePoolViewModel.paceUnavailableTitle(early, now: Self.now) == "Too early")
        #expect(UsagePoolViewModel.paceUnavailableDetail(early, now: Self.now).hasPrefix("Pace from "))
        let mature = account(started: 6)
        #expect(UsagePoolViewModel.paceStartDate(mature, now: Self.now) == nil)
        #expect(UsagePoolViewModel.paceUnavailableTitle(mature, now: Self.now) == "No pace")
        let unreadable = account(started: 1, refused: true)
        #expect(UsagePoolViewModel.paceStartDate(unreadable, now: Self.now) == nil)
        #expect(UsagePoolViewModel.paceUnavailableTitle(unreadable, now: Self.now) == "Unreadable")
        #expect(UsagePoolViewModel.paceUnavailableTitle(nil, now: Self.now) == "No pace")
    }

    @Test func datesDistinguishTodayNextSixDaysAndDistantExpiry() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for (date, expected) in [
            ("2026-11-06T23:21:00Z", "23:21"),
            ("2026-11-07T00:01:00Z", "Sat 00:01"),
            ("2026-11-12T23:59:00Z", "Thu 23:59"),
            ("2026-11-13T00:00:00Z", "13 Nov, 00:00"),
            ("2026-11-30T19:54:00Z", "30 Nov, 19:54"),
            ("2026-12-01T22:28:00Z", "1 Dec, 22:28"),
        ] {
            #expect(UsagePoolViewModel.dateText(Self.date(date), now: Self.now, calendar: calendar) == expected)
        }
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(UsagePoolViewModel.dateText(Self.now, now: Self.now, calendar: calendar) == "01:50")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(UsagePoolViewModel.dateText(Self.now, now: Self.now, calendar: calendar) == "09:50")
    }

    @Test func countdownsAxisDatesAndExpirySymbolStayReadable() {
        for (minutes, expected) in [(0, "0m"), (59, "59m"), (60, "1h 0m"), (2879, "47h 59m"),
                                    (2880, "2d 0h"), (9806, "6d 19h")] {
            #expect(UsagePoolViewModel.countdown(to: Self.now.addingTimeInterval(Double(minutes) * 60), now: Self.now) == expected)
        }
        #expect(UsagePoolViewModel.countdown(to: Self.now.addingTimeInterval(-60), now: Self.now) == "0m")
        #expect(UsagePoolViewModel.axisDateText("2026-10-08") == "8 Oct")
        #expect(UsagePoolViewModel.weekdayDateText("2026-10-08") == "Thu 8 Oct")
        #expect(NSImage(systemSymbolName: "clock.badge.exclamationmark", accessibilityDescription: nil) != nil)
    }

    /// Stale logins never drive pace, so a provider whose only login is unreadable has none. The engine's
    /// own pacePosition still marks such contributions estimated when a caller passes them in.
    @Test func unreadableProvidersNoLongerDriveTheGauge() throws {
        // An invented slow Codex week: 5% used with 3.5 days gone.
        let codex = try UsagePoolForecast.forecast(
            provider: .codex,
            accounts: [.init(id: "codex", displayName: "Codex", weekly: Self.window(5, "2026-11-09T21:50:00Z"),
                             measuredAt: Self.now, isActive: true)],
            now: Self.now, pace: .init(unitsPerDay: 0, assumption: "Invented idle fixture"))
        for scenario in [UsagePoolForecast.Scenario.dead, .lastReading, .fullAfterPassedTopUp] {
            let accounts = [UsagePoolForecast.Account(
                id: "invented-unreadable", displayName: "Invented unreadable",
                weekly: Self.window(95, "2026-11-09T19:00:00Z"),
                measuredAt: Self.now.addingTimeInterval(-30 * 3600), refusedSince: Self.now)]
            let claude = try UsagePoolForecast.forecast(
                provider: .claude, accounts: accounts, now: Self.now,
                pace: .init(unitsPerDay: 0, assumption: "Invented unreadable fixture"),
                scenarios: ["invented-unreadable": scenario])
            let position = UsagePoolForecast.pacePosition(results: [claude], now: Self.now)
            #expect(position.contributions.allSatisfy { $0.estimated })
            #expect(UsagePoolViewModel.loginPaces(position, accounts: accounts).map(\.estimated) == [true])
            let model = UsagePoolViewModel(now: Self.now, claude: claude, codex: codex)
            #expect(model.providerPaceLines.first == "Claude unreadable")
            #expect(!model.mixedPace)
            #expect(UsagePoolViewModel(now: Self.now, claude: claude, codex: nil).overallPaceTitle == "No pace")
        }
        let expected = UsagePoolViewModel.paceTitle(UsagePoolForecast.pacePosition(results: [codex], now: Self.now))
        #expect(UsagePoolViewModel(now: Self.now, claude: nil, codex: codex).overallPaceTitle == expected)
        #expect(UsagePoolViewModel(now: Self.now, claude: nil, codex: nil).overallPaceTitle == "No pace")
    }

    @Test func nativeKeyEventsControlTabsRefreshAndCloseWithoutStatusBar() throws {
        let state = UsagePoolPresentation()
        var refreshes = 0
        var closes = 0
        var settingsOpened = 0
        func send(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [],
                  type: NSEvent.EventType = .keyDown) throws -> Bool {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            return state.handleKey(event, refresh: { refreshes += 1 }, close: { closes += 1 },
                                   settings: { settingsOpened += 1 })
        }
        for (index, tab) in UsagePoolViewModel.Tab.allCases.enumerated() {
            #expect(try send([18, 19, 20, 21][index], "\(index + 1)"))
            #expect(state.tab == tab)
        }
        #expect(try send(124, ""))
        #expect(state.tab == .overview)
        #expect(try send(123, ""))
        #expect(state.tab == .spend)
        #expect(try send(15, "r"))
        #expect(try send(15, "R", modifiers: .shift))
        #expect(refreshes == 2)
        #expect(try send(53, ""))
        #expect(closes == 1)
        #expect(try send(43, ",", modifiers: .command))
        #expect(closes == 2 && settingsOpened == 1)
        for (index, tab) in UsagePoolViewModel.Tab.allCases.enumerated() {
            #expect(try send([18, 19, 20, 21][index], "\(index + 1)", modifiers: [.command, .capsLock]))
            #expect(state.tab == tab)
        }
        #expect(try send(48, "\t"))
        #expect(state.tab == .overview)
        #expect(try send(48, "\t", modifiers: .shift))
        #expect(state.tab == .spend)
        #expect(try !send(48, "\t", modifiers: .control))
        // Shift-Command-[ and ] step tabs like Chrome and wrap like the arrows; Shift makes the characters { }.
        #expect(try send(30, "}", modifiers: [.command, .shift]))
        #expect(state.tab == .overview)
        #expect(try send(33, "{", modifiers: [.command, .shift]))
        #expect(state.tab == .spend)
        #expect(try send(33, "{", modifiers: [.command, .shift, .capsLock]))
        #expect(state.tab == .codex)
        #expect(try !send(30, "]", modifiers: .command))
        #expect(try !send(30, "}", modifiers: [.command, .shift, .option]))
        #expect(try !send(33, "{", modifiers: .shift))
        #expect(state.tab == .codex)
        #expect(try !send(18, "1", modifiers: [.command, .option]))
        #expect(try !send(15, "r", modifiers: .option))
        #expect(try !send(7, "x"))
        #expect(try !send(15, "r", type: .keyUp))
        #expect(refreshes == 2)
    }

    @Test func tabsAcceptClicksAcrossTheirWholeArea() throws {
        let state = UsagePoolPresentation()
        let host = NSHostingView(rootView: UsagePoolPopoverView(state: state))
        let height = host.fittingSize.height
        let window = ClickTestPanel(contentRect: NSRect(x: -10000, y: -10000, width: 380, height: height),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func click(_ point: NSPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                window.sendEvent(event)
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        // The tab strip sits under the header. Probe each tab's empty corners, not just its glyphs.
        let tabs = UsagePoolViewModel.Tab.allCases
        let width = (380.0 - 20 - 12) / 4
        for (index, tab) in tabs.enumerated().reversed() {
            let minX = 10 + Double(index) * (width + 4)
            // The label centre is the positive control; the corners are where clicks used to fall through.
            for (x, y) in [(minX + 6, UsagePoolPopoverView.tabStripProbeY),
                           (minX + width - 6, UsagePoolPopoverView.tabStripProbeY),
                           (minX + width / 2, UsagePoolPopoverView.tabStripProbeY + 30)] {
                state.tab = tabs[(index + 1) % tabs.count]
                try click(NSPoint(x: x, y: height - y))
                #expect(state.tab == tab, "Click at \(Int(x)), \(Int(y)) should select \(tab.rawValue)")
            }
        }
    }

    @Test func expiryWithoutUsefulRedemptionStillShowsDot() throws {
        let credits = try JSONDecoder().decode(CodexResetCredits.self, from: Data("""
        {"available_count":1,"credits":[
          {"id":"invented-idle-reset","status":"available","expires_at":"2026-11-06T23:21:00Z"}
        ]}
        """.utf8))
        let state = UsagePoolPresentation()
        state.update(accounts: [], codex: .init(
            primary: nil, secondary: Self.window(0, "2026-11-12T09:18:00Z"),
            codexResetCredits: credits, updatedAt: Self.now), sources: [], now: Self.now,
            paces: [.codex: try .init(unitsPerDay: 0, assumption: "Invented idle fixture")])
        #expect(state.model.codex?.redemptions.isEmpty == true)
        #expect(state.model.expiringCredit != nil)
        #expect(state.model.menuBarText.hasSuffix("•"))
    }

    @Test func spendDoesNotMergeUnrelatedSlotIdentitiesAndExcludesStaleSources() throws {
        let entry = try #require(try Self.cachedSpendSources().first?.usage.report.data.first {
            $0.date == AllAccountsDashboardModel.dayKey(from: Self.now)
        })
        let cost = CostUsageTokenSnapshot(sessionTokens: nil, sessionCostUSD: nil,
                                          last30DaysTokens: nil, last30DaysCostUSD: nil,
                                          daily: [entry], updatedAt: Self.now)
        let sources: [SharedCostUsage.Source] = [
            .init(user: NSUserName(), usage: .init(provider: .claude, snapshot: cost), stale: false),
            .init(user: "invented-other-user", usage: .init(provider: .claude, snapshot: cost), stale: false),
            .init(user: "invented-stale-user", usage: .init(provider: .codex, snapshot: cost), stale: true),
        ]
        let analytics = try #require(AllAccountsDashboardModel.make(sources: sources, now: Self.now))
        #expect(analytics.subscriptions.count == (entry.accountBreakdowns?.count ?? 0) * 2)
        #expect(Set(analytics.subscriptions.map(\.id)).count == analytics.subscriptions.count)
        #expect(abs(analytics.cost - (entry.costUSD ?? 0) * 2) < 0.000001)
        #expect(analytics.sources.filter { $0.status == "stale, excluded" }.count == 1)
    }

    @Test func renderAllTabs() throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTMETER_UI_REVIEW_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state = try Self.captureFixture()
        // Prime the first offscreen hosting surface before accepting review captures.
        let warmup = output.appendingPathComponent(".warmup.png")
        try Self.capture(UsagePoolPopoverView(state: state).environment(\.colorScheme, .light),
                         size: NSSize(width: 380, height: 680), dark: false, to: warmup)
        try FileManager.default.removeItem(at: warmup)
        for tab in UsagePoolViewModel.Tab.allCases {
            state.tab = tab
            for dark in [false, true] {
                for increasedContrast in [false, true] {
                    let view = UsagePoolPopoverView(state: state)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\._colorSchemeContrast, increasedContrast ? .increased : .standard)
                    let name = "\(tab.rawValue.lowercased())-\(dark ? "dark" : "light")\(increasedContrast ? "-contrast" : "").png"
                    try Self.capture(view, size: NSSize(width: 380, height: 680), dark: dark,
                                     to: output.appendingPathComponent(name))
                    if !increasedContrast {
                        let expanded = UsagePoolPopoverView(state: state, maxHeight: 1400)
                            .environment(\.colorScheme, dark ? .dark : .light)
                        try Self.capture(expanded, size: NSSize(width: 380, height: 1400), dark: dark,
                            to: output.appendingPathComponent(name.replacingOccurrences(of: ".png", with: "-full.png")))
                    }
                }
            }
        }
        state.tab = .spend
        state.hideNames = true
        for dark in [false, true] {
            let view = UsagePoolPopoverView(state: state, maxHeight: 1400)
                .environment(\.colorScheme, dark ? .dark : .light)
            try Self.capture(view, size: NSSize(width: 380, height: 1400), dark: dark,
                to: output.appendingPathComponent("analytics-full-\(dark ? "dark" : "light")-hidden.png"))
        }
        let fresh = UsagePoolPresentation()
        let now = Self.date("2026-11-06T11:13:00Z")
        fresh.update(accounts: state.accounts,
            codex: .init(primary: Self.window(2, "2026-11-13T11:00:00Z"), secondary: nil,
                codexResetCredits: state.model.resetCredits, updatedAt: now),
            sources: try Self.cachedSpendSources(), now: now, codexCredits: Self.creditsFixture())
        for tab in [UsagePoolViewModel.Tab.overview, .codex] {
            fresh.tab = tab
            for dark in [false, true] {
                let view = UsagePoolPopoverView(state: fresh).environment(\.colorScheme, dark ? .dark : .light)
                try Self.capture(view, size: NSSize(width: 380, height: 680), dark: dark,
                    to: output.appendingPathComponent("\(tab.rawValue.lowercased())-fresh-week-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test func renderRestoredLocalAnalytics() throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_LOCAL_CACHE_QA"] == "1",
              let directory = ProcessInfo.processInfo.environment["AGENTMETER_UI_REVIEW_DIR"] else { return }
        let now = Date()
        let state = UsagePoolPresentation()
        state.update(accounts: UsageStore.readUsagePoolClaudeCache(now: now), codex: nil,
            sources: UsageStore.readOwnCostSources(directory: SharedCostUsage.directory, now: now)
                + SharedCostUsage.importedSources(now: now),
            accountKeyGroups: Array(ClaudeSwapUsage.accountKeys().values), now: now)
        let own = try #require(state.analytics?.providers.first { $0.id == "claude" }?
            .users.first { $0.row.label == NSUserName() })
        #expect(own.row.tokens > 0)
        #expect(!own.accounts.isEmpty && own.accounts.allSatisfy { $0.label != "Unattributed" })
        #expect(own.accounts.reduce(0) { $0 + $1.tokens } == own.row.tokens)
        // Every level of the breakdown follows the selected range.
        var totals: [AllAccountsDashboardModel.Window: (Int, Int, Int)] = [:]
        for window in AllAccountsDashboardModel.Window.allCases {
            state.analyticsWindow = window
            let model = try #require(state.analytics)
            let providers = model.providers.reduce(0) { $0 + $1.row.tokens }
            let users = model.providers.flatMap(\.users).reduce(0) { $0 + $1.row.tokens }
            #expect(providers == model.tokens && users == model.tokens, "\(window.rawValue)")
            totals[window] = (model.tokens, providers, model.days.count)
            print("QA analytics \(window.rawValue): tokens \(model.tokens) providers \(providers) days \(model.days.count)")
        }
        #expect(totals[.today]!.2 == 1 && totals[.week]!.2 == 7 && totals[.thirtyDays]!.2 == 30)
        #expect(totals[.today]!.0 <= totals[.week]!.0 && totals[.week]!.0 <= totals[.thirtyDays]!.0)
        state.analyticsWindow = .thirtyDays
        state.tab = .spend
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        for dark in [false, true] {
            let view = UsagePoolPopoverView(state: state, maxHeight: 1400)
                .environment(\.colorScheme, dark ? .dark : .light)
            try Self.capture(view, size: NSSize(width: 380, height: 1400), dark: dark,
                to: output.appendingPathComponent("analytics-local-full-\(dark ? "dark" : "light").png"))
        }
    }

    @Test func renderSettingsContent() throws {
        guard let directory = ProcessInfo.processInfo.environment["AGENTMETER_UI_REVIEW_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "UsagePoolSettingsReview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(userDefaults: defaults, configStore: testConfigStore(suiteName: suite),
                                     zaiTokenStore: NoopZaiTokenStore(), syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(fetcher: UsageFetcher(), browserDetection: BrowserDetection(cacheTTL: 0),
                               settings: settings, startupBehavior: .testing)
        for dark in [false, true] {
            let view = PreferencesView(settings: settings, store: store, updater: DisabledUpdaterController(),
                                       selection: PreferencesSelection())
                .environment(\.colorScheme, dark ? .dark : .light)
            try Self.capture(view, size: NSSize(width: PreferencesTab.general.preferredWidth,
                                               height: PreferencesTab.general.preferredHeight), dark: dark,
                             to: output.appendingPathComponent("settings-content-\(dark ? "dark" : "light").png"))
        }
    }

    @Test func renderClaudeBankedResets() throws {
        let assertions = try Self.captureFixture()
        var account = UsagePoolForecast.Account(id: "claude:cswap:1", displayName: "Invented", weekly: nil)
        account.claudeLimitResets = try ClaudeLimitResets.decodeUsage(Data(ClaudeLimitResetsTests.grants.utf8))
        assertions.update(accounts: [account], codex: nil, sources: [], now: Self.date("2026-11-11T12:00:00Z"))
        #expect(assertions.model.claudeBankedResetTotal == "3")
        #expect(assertions.model.claudeBankedResets(account)?.map(\.kind) == ["Fable reset", "Fable reset", "Full reset"])
        guard let directory = ProcessInfo.processInfo.environment["AGENTMETER_CLAUDE_RESETS_REVIEW_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state = try Self.captureFixture()
        let now = Self.date("2026-11-11T12:00:00Z")
        let fixture = try #require(Bundle.module.url(forResource: "claude-limit-resets-unavailable-2026-11-11",
                                                     withExtension: "json", subdirectory: "Fixtures"))
        let responses = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        var accounts = [UsagePoolForecast.Account]()
        for (index, name) in ["work-1", "work-2", "work-3", "Personal"].enumerated() {
            var account = UsagePoolForecast.Account(id: "claude:cswap:\(index + 1)", displayName: name,
                weekly: Self.window(20, "2026-11-17T12:00:00Z"), measuredAt: now, isActive: index == 0)
            if let response = responses[name] {
                account.claudeLimitResets = try? ClaudeLimitResets.decodeUsage(
                    JSONSerialization.data(withJSONObject: response))
            }
            accounts.append(account)
        }
        state.update(accounts: accounts, codex: nil, sources: [], now: now)
        state.tab = .claude
        for hidden in [false, true] {
            state.hideNames = hidden
            let view = UsagePoolPopoverView(state: state, maxHeight: 1400).environment(\.colorScheme, .light)
            try Self.capture(view, size: NSSize(width: 380, height: 1400), dark: false,
                             to: output.appendingPathComponent("claude-resets-\(hidden ? "hidden" : "named").png"))
        }
        accounts[0].claudeLimitResets = try ClaudeLimitResets.decodeUsage(Data(ClaudeLimitResetsTests.grants.utf8))
        accounts[3].claudeLimitResets = try ClaudeLimitResets.decodeUsage(Data(
            #"{"cedar_ember":{"eligible":true,"grants":[]}}"#.utf8))
        state.update(accounts: accounts, codex: nil, sources: [], now: now)
        for hidden in [false, true] {
            state.hideNames = hidden
            let view = UsagePoolPopoverView(state: state, maxHeight: 1600).environment(\.colorScheme, .light)
            try Self.capture(view, size: NSSize(width: 380, height: 1600), dark: false,
                to: output.appendingPathComponent("claude-resets-invented-\(hidden ? "hidden" : "named").png"))
        }
    }

    private static func capture(_ view: some View, size: NSSize, dark: Bool, to output: URL) throws {
        // The live panel's glass is AppKit chrome; offscreen reviews stand in a flat window fill.
        let controller = NSHostingController(rootView: view.background(Color(white: dark ? 0.16 : 0.94)))
        let host = controller.view
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentViewController = controller
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        window.display()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var contentColors: Set<Int> = []
        for y in stride(from: bitmap.pixelsHigh / 6, to: bitmap.pixelsHigh * 5 / 6, by: bitmap.pixelsHigh / 128) {
            for x in stride(from: bitmap.pixelsWide / 6, to: bitmap.pixelsWide * 5 / 6, by: bitmap.pixelsWide / 32) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 {
                    let red = Int((color.redComponent * 255).rounded())
                    let green = Int((color.greenComponent * 255).rounded())
                    let blue = Int((color.blueComponent * 255).rounded())
                    contentColors.insert(red << 16 | green << 8 | blue)
                }
            }
        }
        #expect(contentColors.count > 8, "Capture \(output.lastPathComponent) must contain rendered controls, not a blank surface")
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output)
        #expect(bitmap.pixelsWide == Int(size.width * 2) && bitmap.pixelsHigh == Int(size.height * 2))
    }

}

@MainActor
private final class ClickTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class WatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { self.lock.withLock { self.count } }
    func increment() { self.lock.withLock { self.count += 1 } }
}
