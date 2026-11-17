@testable import CodexBarCore
import Foundation
import Testing
@testable import AgentMeter

@Suite(.serialized)
@MainActor
struct UsagePoolCodexAccountsTests {
    private let now = Date(timeIntervalSince1970: 1_794_312_000)

    // Invented logins and balances, with no live provider calls.
    private func reading(
        id: String, plan: String, active: Bool, weekly: Double, session: Double,
        resetID: String, balance: Double, email: String? = nil, workspace: String? = nil,
        error: String? = nil) throws -> CodexAccountUsageSnapshot
    {
        let email = email ?? "invented-\(id)@example.invalid"
        let credits = try JSONDecoder().decode(CodexResetCredits.self, from: Data("""
        {"available_count":1,"credits":[{"id":"\(resetID)","status":"available",
          "expires_at":\(self.now.addingTimeInterval(3600).timeIntervalSince1970)}]}
        """.utf8))
        return CodexAccountUsageSnapshot(
            account: .init(id: id, email: email, workspaceLabel: workspace, storedAccountID: nil,
                selectionSource: id == "system" ? .liveSystem : .managedAccount(id: UUID()),
                isActive: active, isLive: id == "system",
                canReauthenticate: false, canRemove: false),
            snapshot: .init(
                primary: .init(usedPercent: session, windowMinutes: 300,
                    resetsAt: self.now.addingTimeInterval(7200), resetDescription: nil),
                secondary: .init(usedPercent: weekly, windowMinutes: 10080,
                    resetsAt: self.now.addingTimeInterval(3.5 * 86400), resetDescription: nil),
                codexResetCredits: credits, updatedAt: self.now,
                identity: .init(providerID: .codex, accountEmail: email, accountOrganization: nil, loginMethod: plan)),
            error: error, sourceLabel: "invented", credits: .init(remaining: balance, events: [], updatedAt: self.now))
    }

    private func popoverSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/CodexBar/UsagePoolPopoverView.swift"),
                          encoding: .utf8)
    }

    @Test func overviewShowsOnlyTheCodexLoginInUse() throws {
        let inputs = try [
            self.reading(id: "system", plan: "pro", active: true, weekly: 80, session: 40,
                         resetID: "invented-reset-a", balance: 0),
            self.reading(id: "managed", plan: "prolite", active: false, weekly: 10, session: 2,
                         resetID: "invented-reset-b", balance: 0),
        ]
        let state = UsagePoolPresentation(overflowConfiguration: { nil })
        state.update(accounts: [], codex: inputs[0].snapshot, sources: [], now: self.now, codexAccounts: inputs)
        #expect(state.codexAccounts.map(\.displayName) == ["Pro 20x", "Pro 10x"])
        #expect(state.codexAccounts.map { $0.weekly?.usedPercent } == [80, 10])
        #expect(state.codexAccounts.filter(UsagePoolViewModel.isInUse).map { $0.session?.usedPercent } == [40])
        let inactive = try #require(state.codexAccounts.first { $0.id == "managed" })
        let row = UsagePoolFleet.row(inactive, name: inactive.displayName, now: self.now)
        #expect(UsagePoolAccountDot(status: row.status, hasReading: row.hasReading).color == .secondary)
        #expect(!UsagePoolViewModel.isInUse(inactive))
        let source = try self.popoverSource()
        let overview = try #require(source.components(separatedBy: "@ViewBuilder private var overview:").last?
            .components(separatedBy: "@ViewBuilder private var claude:").first)
        // Overview shows only the active login.
        #expect(overview.contains("if let account = self.state.codexAccount, UsagePoolViewModel.isInUse(account)"))
        #expect(!overview.contains("ForEach(Array(self.state.codexAccounts.enumerated())"))
        #expect(source.contains("UsagePoolViewModel.isInUse(account) ? row.status : .idle"))
        #expect(source.contains("if UsagePoolViewModel.isInUse(account) {\n                Text(\"Active\")"))
    }

    @Test func codexUsageKeepsInactiveLoginsOwnCredits() throws {
        let inputs = try [
            self.reading(id: "system", plan: "pro", active: true, weekly: 100, session: 100,
                         resetID: "invented-reset-a", balance: 12),
            self.reading(id: "managed", plan: "prolite", active: false, weekly: 100, session: 100,
                         resetID: "invented-reset-b", balance: 99),
        ]
        var loads = 0
        let state = UsagePoolPresentation(overflowConfiguration: { nil }, creditCapConfiguration: {
            loads += 1
            return UsagePoolCreditCap(floor: 700, cap: 100)
        })
        state.update(accounts: [], codex: inputs[0].snapshot, sources: [], now: self.now,
                     codexCredits: .init(remaining: 777, events: [], updatedAt: self.now), codexAccounts: inputs)
        #expect(loads == 1)
        for account in state.codexAccounts {
            let window = try #require(account.weekly)
            let balance = try #require(state.codexAccountCredits[account.id]?.remaining)
            #expect(balance == (account.id == "system" ? 777 : 99))
            let text = UsagePoolViewModel.usageText(window, unreadable: false, estimated: false,
                                                   now: self.now, creditsRemaining: balance)
            #expect(text == "100% used · on credits")
            let block = try #require(state.creditsBlock(account))
            #expect(block.balance == balance)
            #expect((block.cap != nil) == (account.id == "system"))
            #expect(loads == 1)
            if !account.isActive { #expect(balance != state.codexCredits?.remaining) }
        }
        let source = try self.popoverSource()
        #expect(state.codexAccounts.map { state.creditCapForAccount($0) != nil } == state.codexAccounts.map { $0.id == "system" })
        // Balance and cap appear only in per-account details.
        for (start, end) in [("@ViewBuilder private func codexRow(", "static func codexRowName"),
                             ("@ViewBuilder private func accountUsage(", "private func usageBar(")] {
            let section = try #require(source.components(separatedBy: start).last?
                .components(separatedBy: end).first)
            #expect(!section.contains("UsagePoolCreditsView"))
            #expect(!section.contains("self.state.codexCredits"))
        }
        #expect(source.contains("cap: self.state.creditCapForAccount(account))"))
        #expect(source.contains("UsagePoolCreditsView(credits: accountCap, tint: self.codexColor, showsBalance: false)"))
    }

    @Test func tierNamesArePrivateUniqueAndRespectHideNames() throws {
        let state = UsagePoolPresentation(overflowConfiguration: { nil })
        let inputs = try [
            self.reading(id: "system", plan: "pro", active: true, weekly: 80.4, session: 40,
                         resetID: "invented-reset-a", balance: 0),
            self.reading(id: "managed", plan: "pro", active: false, weekly: 10.4, session: 2,
                         resetID: "invented-reset-b", balance: 0),
        ]
        state.update(accounts: [], codex: inputs[0].snapshot, sources: [], now: self.now, codexAccounts: inputs)
        #expect(state.codexAccounts.map(\.displayName) == ["Pro 20x", "Pro 20x 2"])
        #expect(state.codexAccounts.allSatisfy { !$0.displayName.contains("@") })
        let fleet = state.codexFleet
        #expect(fleet.capacityPoints == 200)
        #expect(fleet.displayedHeadroomPoints == fleet.rows.compactMap(\.headroom).reduce(0) { $0 + Int($1.rounded()) })
        #expect(fleet.displayedHeadroomPoints == 110)
        #expect(fleet.rows.map(\.status) == [.idle, .active])
        state.hideNames = true
        #expect(state.codexAccounts.enumerated().map { state.name($1, index: $0) } == ["Login 1", "Login 2"])
        #expect(UsagePoolPresentation.displayName("invented@example.invalid", index: 1) == "Login 2")
    }

    @Test func bothRowsSurviveActiveAccountSwitchWithTheirOwnUsageAndCredits() throws {
        let state = UsagePoolPresentation(overflowConfiguration: { nil })
        for active in ["system", "managed"] {
            let system = try self.reading(id: "system", plan: "pro", active: active == "system",
                weekly: 80, session: 40, resetID: "invented-system-reset", balance: 12)
            let managed = try self.reading(id: "managed", plan: "prolite", active: active == "managed",
                weekly: 10, session: 2, resetID: "invented-managed-reset", balance: 99)
            state.update(accounts: [], codex: active == "system" ? system.snapshot : managed.snapshot,
                sources: [], now: self.now, codexAccounts: [system, managed])
            #expect(state.codexAccounts.map(\.id) == ["system", "managed"])
            #expect(state.codexAccounts.filter(\.isActive).map(\.id) == [active])
            #expect(state.codexAccounts.map(\.displayName) == [
                "Pro 20x", "Pro 10x",
            ])
            let rows = state.codexAccounts.map { UsagePoolFleet.row($0, name: $0.displayName, now: self.now) }
            #expect(rows.map { $0.weekly?.usedPercent } == [80, 10])
            #expect(rows.map { $0.session?.usedPercent } == [40, 2])
            #expect(rows.map { $0.weekly?.topUp } == [system.snapshot?.secondary?.resetsAt, managed.snapshot?.secondary?.resetsAt])
            #expect(state.codexModels["system"]?.availableResets.map(\.id) == ["invented-system-reset"])
            #expect(state.codexModels["managed"]?.availableResets.map(\.id) == ["invented-managed-reset"])
            #expect(state.codexModels.values.allSatisfy { $0.bankedResetCount == 1 })
            #expect(state.codexAccountCredits["system"]?.remaining == 12)
            #expect(state.codexAccountCredits["managed"]?.remaining == 99)
            #expect(Set(state.model.results.flatMap(\.accounts).map(\.id)) == ["system", "managed"])
            #expect(Set(state.model.codexPosition?.contributions.map(\.accountID) ?? []) == ["system", "managed"])
            #expect(abs((state.model.codexPosition?.delta ?? 0) + 0.05) < 0.000001)
            for tab in [UsagePoolViewModel.Tab.overview, .codex] {
                state.tab = tab
                #expect(state.codexAccounts.count == 2)
            }
        }
        state.hideNames = true
        #expect(state.codexAccounts.enumerated().map { state.name($0.element, index: $0.offset) } == ["Login 1", "Login 2"])
    }

    @Test func codexSectionsGroupAllStatusesBeforeResetsAndDetails() throws {
        let state = UsagePoolPresentation(overflowConfiguration: { nil })
        #expect(state.model.codexSections.isEmpty)
        for active in ["system", "managed", "none"] {
            let system = try self.reading(id: "system", plan: "pro", active: active == "system",
                weekly: 80, session: 40, resetID: "invented-system-reset", balance: 12)
            let managed = try self.reading(id: "managed", plan: "prolite", active: active == "managed",
                weekly: 10, session: 2, resetID: "invented-managed-reset", balance: 99)
            state.update(accounts: [], codex: nil, sources: [], now: self.now, codexAccounts: [managed, system])
            #expect(state.model.codexSections == [.status, .bankedResets, .accountDetails])
            let expected = active == "system" ? ["system", "managed"] : ["managed", "system"]
            #expect(state.model.orderedCodexAccounts.map(\.id) == expected)
            #expect(state.model.orderedCodexAccounts.count == 2)
            state.hideNames = true
            #expect(state.model.orderedCodexAccounts.map { state.name($0, index: 0) }
                == (active == "system" ? ["Login 2", "Login 1"] : ["Login 1", "Login 2"]))
            state.hideNames = false
        }
    }

    @Test func sameTierRowsUseNumberedNamesAndUnreadableLoginDoesNotDrivePace() throws {
        let state = UsagePoolPresentation(overflowConfiguration: { nil })
        let system = try self.reading(id: "system", plan: "pro", active: false,
            weekly: 90, session: 50, resetID: "invented-system-reset", balance: 12,
            email: "invented-shared@example.invalid", workspace: "Invented workspace A", error: "Network unavailable")
        let managed = try self.reading(id: "managed", plan: "pro", active: true,
            weekly: 10, session: 2, resetID: "invented-managed-reset", balance: 99,
            email: "invented-shared@example.invalid", workspace: "Invented workspace B")
        state.update(accounts: [], codex: managed.snapshot, sources: [], now: self.now, codexAccounts: [system, managed])
        #expect(Set(state.codexAccounts.map(\.displayName)).count == 2)
        #expect(state.codexAccounts[0].displayName == "Pro 20x")
        #expect(state.codexAccounts[1].displayName == "Pro 20x 2")
        #expect(state.codexAccounts[0].weekly?.usedPercent == 90)
        #expect(Set(state.model.codexPosition?.contributions.map(\.accountID) ?? []) == ["managed"])
        #expect(state.codexModels["system"]?.availableResets.map(\.id) == ["invented-system-reset"])
    }

    @Test func missingAccountReadingStaysVisibleWithoutBorrowingActiveUsage() throws {
        let state = UsagePoolPresentation(overflowConfiguration: { nil })
        let system = try self.reading(id: "system", plan: "pro", active: false,
            weekly: 80, session: 40, resetID: "invented-system-reset", balance: 12)
        let managed = try self.reading(id: "managed", plan: "prolite", active: true,
            weekly: 0, session: 0, resetID: "invented-managed-reset", balance: 99)
        let missing = CodexAccountUsageSnapshot(account: system.account, snapshot: nil, error: "Unavailable", sourceLabel: nil)
        state.update(accounts: [], codex: managed.snapshot, sources: [], now: self.now, codexAccounts: [missing, managed])
        #expect(state.codexAccounts.count == 2)
        #expect(state.codexAccounts[0].weekly == nil)
        #expect(state.codexAccounts[0].session == nil)
        #expect(state.codexAccountCredits["system"] == nil)
        #expect(state.codexAccounts[1].weekly?.usedPercent == 0)
    }

    private func overflowConfig(_ extra: [String: Any] = [:]) throws -> CodexOverflowConfiguration {
        let json = ["home": "~/.codex-invented-overflow", "until": "2026-12-10", "switch_at": 95,
                    "account_email": "INVENTED-MANAGED@example.invalid"] as [String: Any]
        return try JSONDecoder().decode(CodexOverflowConfiguration.self,
            from: JSONSerialization.data(withJSONObject: json.merging(extra) { _, new in new }))
    }

    private func activeCodexAccountID(
        _ inputs: [CodexAccountUsageSnapshot], config: CodexOverflowConfiguration?, now: Date) -> String?
    {
        UsagePoolViewModel.activeCodexAccountID(inputs, config: config, now: now, fileExists: { _ in true })
    }

    @Test func overflowSelectionUsesBothWindowsAndConfiguredIdentity() throws {
        let config = try self.overflowConfig()
        for (weekly, session, otherWeekly, otherSession, expected) in [
            (94.0, 94.0, 0.0, 0.0, "system"),
            (95, 0, 0, 0, "managed"), (0, 95, 0, 0, "managed"),
            (100, 0, 95, 0, "system"), (100, 0, 0, 95, "system"),
        ] {
            let system = try self.reading(id: "system", plan: "pro", active: false,
                weekly: weekly, session: session, resetID: "a", balance: 0)
            let managed = try self.reading(id: "managed", plan: "prolite", active: true,
                weekly: otherWeekly, session: otherSession, resetID: "b", balance: 0)
            let state = UsagePoolPresentation(overflowConfiguration: { config }, fileExists: { _ in true })
            state.update(accounts: [], codex: managed.snapshot, sources: [], now: self.now, codexAccounts: [system, managed])
            #expect(state.codexAccounts.filter(\.isActive).map(\.id) == [expected])
            #expect(state.codexAccount?.id == expected)
            #expect(state.model.orderedCodexAccounts.count == 2)
            let third = try self.reading(id: "third", plan: "prolite", active: false,
                weekly: 0, session: 0, resetID: "c", balance: 0)
            if weekly >= 95 || session >= 95 {
                #expect(self.activeCodexAccountID([system, third, managed], config: config, now: self.now) == expected)
                let missing = CodexAccountUsageSnapshot(account: managed.account, snapshot: nil,
                    error: "Not read yet", sourceLabel: nil)
                #expect(self.activeCodexAccountID([system, missing], config: config, now: self.now) == "managed")
            }
        }
    }

    @Test func overflowSelectionReevaluatesConfigAndReturnsOnResetWithoutNewReading() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("codex-overflow.json")
        let state = UsagePoolPresentation(overflowConfiguration: { .load(from: url) }, fileExists: { _ in true })
        let system = try self.reading(id: "system", plan: "pro", active: false,
            weekly: 0, session: 95, resetID: "a", balance: 0)
        let managed = try self.reading(id: "managed", plan: "prolite", active: true,
            weekly: 0, session: 0, resetID: "b", balance: 0)
        func update(_ now: Date, expected: String) {
            state.update(accounts: [], codex: managed.snapshot, sources: [], now: now, codexAccounts: [system, managed])
            #expect(state.codexAccount?.id == expected)
            #expect(state.codexAccounts.filter(\.isActive).map(\.id) == [expected])
        }
        update(self.now, expected: "managed")
        for json in ["[]", "{", "{}", #"{"home":"~/.codex-invented-overflow","until":"invalid"}"#,
                     #"{"home":"~/.codex-invented-overflow","until":"2026-01-01"}"#,
                     #"{"home":"~/.codex-invented-overflow","until":"2026-12-10","enabled":false}"#] {
            try Data(json.utf8).write(to: url)
            update(self.now, expected: "managed")
        }
        try Data(#"{"home":"~/.codex-invented-overflow","until":"2026-12-10"}"#.utf8).write(to: url)
        update(self.now, expected: "managed")
        update(self.now.addingTimeInterval(7200), expected: "system")
        update(self.now, expected: "managed")
        try FileManager.default.removeItem(at: url)
        update(self.now, expected: "managed")
        state.update(accounts: [], codex: system.snapshot, sources: [], now: self.now, codexAccounts: [system])
        #expect(state.codexAccount?.id == "system")
        #expect(state.codexAccounts.count == 1)
    }

    @Test func overflowRequiresItsAuthFileAndUnambiguousManagedIdentity() throws {
        let system = try self.reading(id: "system", plan: "pro", active: true,
            weekly: 100, session: 0, resetID: "a", balance: 0)
        let managed = try self.reading(id: "managed", plan: "prolite", active: false,
            weekly: 0, session: 0, resetID: "b", balance: 0)
        let third = try self.reading(id: "third", plan: "prolite", active: false,
            weekly: 0, session: 0, resetID: "c", balance: 0)
        let config = try self.overflowConfig()
        let activeID = UsagePoolViewModel.activeCodexAccountID([system, managed], config: config, now: self.now,
            fileExists: { path in
                #expect(path == config.homeURL.appendingPathComponent("auth.json").path)
                return false
            })
        #expect(activeID == "system")
        let noEmail = try self.overflowConfig(["account_email": NSNull()])
        #expect(self.activeCodexAccountID([system, managed], config: noEmail, now: self.now) == "managed")
        #expect(self.activeCodexAccountID([system, third, managed], config: noEmail, now: self.now) == "system")
        let unmatched = try self.overflowConfig(["account_email": "invented-absent@example.invalid"])
        #expect(self.activeCodexAccountID([system, managed], config: unmatched, now: self.now) == "system")
        #expect(self.activeCodexAccountID([system, third], config: config, now: self.now) == "system")
        #expect(self.activeCodexAccountID([managed, third], config: config, now: self.now) == nil)
    }

    @Test func managedOnlyAccountKeepsOverviewPaceAndBankedResetsWithoutOverflow() throws {
        let managed = try self.reading(id: "managed", plan: "prolite", active: true,
            weekly: 10, session: 2, resetID: "invented-managed-reset", balance: 99)
        for config in [nil, try self.overflowConfig(["enabled": false])] {
            let state = UsagePoolPresentation(overflowConfiguration: { config })
            state.update(accounts: [], codex: nil, sources: [], now: self.now, codexAccounts: [managed])
            #expect(state.codexAccount?.id == "managed")
            #expect(state.codexAccount?.isActive == true)
            #expect(state.model.codex != nil)
            #expect(state.model.codexPosition != nil)
            #expect(state.model.availableResets.map(\.id) == ["invented-managed-reset"])
            let inactive = CodexAccountUsageSnapshot(
                account: try self.reading(id: "managed", plan: "prolite", active: false,
                    weekly: 10, session: 2, resetID: "invented-managed-reset", balance: 99).account,
                snapshot: managed.snapshot, error: nil, sourceLabel: nil)
            state.update(accounts: [], codex: nil, sources: [], now: self.now, codexAccounts: [inactive])
            #expect(state.codexAccount?.isActive == true)
            #expect(state.model.codex != nil)
            #expect(state.model.availableResets.count == 1)
        }
    }

    @Test func overflowSelectionNeedsLiveThresholdAndHonorsCustomThresholdAndLocalUntilDay() throws {
        let system = try self.reading(id: "system", plan: "pro", active: true,
            weekly: 96, session: 0, resetID: "a", balance: 0)
        let managed = try self.reading(id: "managed", plan: "prolite", active: false,
            weekly: 0, session: 0, resetID: "b", balance: 0)
        let high = try self.overflowConfig(["switch_at": 97])
        #expect(self.activeCodexAccountID([system, managed], config: high, now: self.now) == "system")
        let config = try self.overflowConfig()
        #expect(self.activeCodexAccountID([system, managed], config: config,
            now: self.now.addingTimeInterval(3.5 * 86400)) == "system")
        let missing = CodexAccountUsageSnapshot(account: system.account, snapshot: nil, error: nil, sourceLabel: nil)
        #expect(self.activeCodexAccountID([missing, managed], config: config, now: self.now) == "system")
        #expect(self.activeCodexAccountID([system], config: config, now: self.now) == "system")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        let lastMinute = ISO8601DateFormatter().date(from: "2026-12-11T07:59:59Z")!
        #expect(config.allowsOverflow(now: lastMinute, calendar: calendar))
        #expect(!config.allowsOverflow(now: lastMinute.addingTimeInterval(1), calendar: calendar))
    }

    @Test func overflowWindowResetMakesRoomAndSchedulesImmediateReevaluation() throws {
        let config = try self.overflowConfig()
        let system = try self.reading(id: "system", plan: "pro", active: true,
            weekly: 100, session: 0, resetID: "a", balance: 0)
        let managed = try self.reading(id: "managed", plan: "prolite", active: false,
            weekly: 0, session: 95, resetID: "b", balance: 0)
        #expect(self.activeCodexAccountID([system, managed], config: config, now: self.now) == "system")
        let reset = self.now.addingTimeInterval(7200)
        #expect(self.activeCodexAccountID([system, managed], config: config, now: reset) == "managed")
        let state = UsagePoolPresentation(overflowConfiguration: { config }, fileExists: { _ in true })
        state.update(accounts: [], codex: nil, sources: [], now: reset.addingTimeInterval(-10), codexAccounts: [system, managed])
        #expect(abs(StatusItemController.usagePoolRefreshDelay(accounts: state.codexAccounts,
            now: reset.addingTimeInterval(-10)) - 10.05) < 0.001)
        #expect(StatusItemController.usagePoolRefreshDelay(accounts: state.codexAccounts, now: reset) == 60)
        let noReset = CodexAccountUsageSnapshot(account: system.account,
            snapshot: .init(primary: .init(usedPercent: 100, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil, updatedAt: self.now), error: nil, sourceLabel: nil)
        #expect(self.activeCodexAccountID([noReset, managed], config: config, now: reset) == "system")
    }

    private func account(
        id: String = "invented-a", used: Double, elapsedDays: Double = 3.5,
        capacity: Double = 100, active: Bool = false) -> UsagePoolForecast.Account
    {
        .init(id: id, displayName: id,
              weekly: .init(usedPercent: used, windowMinutes: 10080,
                  resetsAt: self.now.addingTimeInterval((7 - elapsedDays) * 86400), resetDescription: nil),
              measuredAt: self.now, isActive: active, calibratedCapacity: capacity)
    }

    @Test func codexRowsUseClaudeActivityLabelsAndDotsAndHideMissingSession() {
        for active in [false, true] {
            for used in [2.0, 95, 100, 105] {
                let account = self.account(used: used, active: active)
                let model = UsagePoolViewModel(now: self.now, claude: nil, codex: nil, codexAccounts: [account])
                let row = model.codexRow(account, name: account.displayName)
                #expect(row.statusText == (active ? "Active" : "Not active"))
                #expect(row.dotIsGreen == active)
                #expect(row.session == nil)
            }
        }
    }

    @Test func weeklyOnlyPrimaryReachesBothCodexSurfacesWithoutSessionRow() {
        let snapshot = UsageSnapshot(
            primary: .init(usedPercent: 95, windowMinutes: 10080,
                resetsAt: self.now.addingTimeInterval(3.5 * 86400), resetDescription: nil),
            secondary: nil, updatedAt: self.now)
        let state = UsagePoolPresentation(overflowConfiguration: { nil })
        state.update(accounts: [], codex: snapshot, sources: [], now: self.now)
        #expect(state.model.orderedCodexAccounts.count == 1)
        for tab in [UsagePoolViewModel.Tab.overview, .codex] {
            state.tab = tab
            let account = state.model.orderedCodexAccounts[0]
            let row = state.model.codexRow(account, name: account.id)
            #expect(row.weekly?.usedPercent == 95)
            #expect(row.session == nil)
        }
    }

    @Test func pooledPaceWeightsCapacityAndEachWeeklyClockAndKeepsSingleLoginPace() throws {
        let first = self.account(used: 95, elapsedDays: 4, capacity: 200)
        let second = self.account(id: "invented-b", used: 2, elapsedDays: 2, capacity: 100)
        let model = UsagePoolViewModel(now: self.now, claude: nil, codex: nil, codexAccounts: [first, second])
        let expected = ((0.95 - 4.0 / 7) * 200 + (0.02 - 2.0 / 7) * 100) / 300
        #expect(abs(try #require(model.codexPosition?.delta) - expected) < 0.000001)
        let single = UsagePoolViewModel(now: self.now, claude: nil, codex: nil, codexAccounts: [first])
        #expect(abs(try #require(single.codexPosition?.delta) - (0.95 - 4.0 / 7)) < 0.000001)
    }

    @Test func idleRequiresThreeHoursOfSameWindowHistoryAndNoIncrease() throws {
        let account = self.account(used: 95)
        var model = UsagePoolViewModel(now: self.now, claude: nil, codex: nil, codexAccounts: [account])
        #expect(!model.codexIsIdle(account))
        #expect(model.codexRow(account, name: account.id).runway != nil)
        let entries = (0...3).map { hour in
            PlanUtilizationHistoryEntry(capturedAt: self.now.addingTimeInterval(Double(hour - 3) * 3600),
                usedPercent: 95, resetsAt: account.weekly?.resetsAt)
        }
        model.codexWeeklyHistory = [account.id: entries]
        #expect(model.codexIsIdle(account))
        #expect(model.codexRow(account, name: account.id).projectionText == "Idle 3h")
        #expect(model.codexRow(account, name: account.id).runway == nil)
        model.codexWeeklyHistory[account.id] = Array(entries.dropFirst())
        #expect(!model.codexIsIdle(account))
        model.codexWeeklyHistory[account.id] = entries.map {
            .init(capturedAt: $0.capturedAt, usedPercent: $0.capturedAt < self.now ? 94 : 95, resetsAt: $0.resetsAt)
        }
        #expect(!model.codexIsIdle(account))
        model.codexWeeklyHistory[account.id] = entries.map {
            .init(capturedAt: $0.capturedAt, usedPercent: 95, resetsAt: $0.resetsAt?.addingTimeInterval(-604800))
        }
        #expect(!model.codexIsIdle(account))
    }

    @Test func resetRowsHaveShortTitlesAndAdviceUsesCombinedRunway() {
        let full = self.account(used: 95)
        let room = self.account(id: "invented-b", used: 2)
        var model = UsagePoolViewModel(now: self.now, claude: nil, codex: nil, codexAccounts: [full, room])
        #expect(model.codexResetAdvice == "Not needed yet")
        #expect(UsagePoolViewModel.BankedReset(number: 1, expiresAt: nil, redemption: nil).title == "1")
        #expect(UsagePoolViewModel.BankedReset(number: 2, expiresAt: nil, redemption: nil).title == "2")
        model.codexAccounts = [full, self.account(id: "invented-b", used: 90)]
        #expect(model.codexResetAdvice == nil)
        model.codexAccounts = [full]
        #expect(model.codexResetAdvice == nil)
    }

    @Test func codexPacePointsExplainTheirUnitInline() {
        for (used, expected) in [(90.0, "+40"), (10, "−40"), (50, "0")] {
            let account = self.account(used: used)
            let model = UsagePoolViewModel(now: self.now, claude: nil, codex: nil)
            #expect(model.codexRow(account, name: account.id).weekly?.paceText == expected)
        }
    }

    @Test func segmentedMenuFetchesSystemReadOnlyAndManagedWithoutCLIAndKeepsReadingsOnSwitch() async throws {
        let support = CodexAccountScopedRefreshTests()
        let settings = support.makeSettingsStore(suite: "UsagePoolCodexAccountsTests-read-only")
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .segmented
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = support.liveAccount(email: "invented-system@example.invalid")
        let id = UUID()
        let managed = ManagedCodexAccount(id: id, email: "invented-managed@example.invalid",
            managedHomePath: ManagedCodexHomeFactory.defaultRootURL().appendingPathComponent(UUID().uuidString).path,
            createdAt: 1, updatedAt: 2, lastAuthenticatedAt: 2)
        let url = try support.makeManagedAccountStoreURL(accounts: [managed])
        defer { try? FileManager.default.removeItem(at: url) }
        settings._test_managedCodexAccountStoreURL = url
        settings.codexActiveSource = .liveSystem
        let store = support.makeUsageStore(settings: settings)
        let systemUsage = try #require(self.reading(id: "system", plan: "pro", active: true,
            weekly: 80, session: 40, resetID: "invented-system-reset", balance: 12).snapshot)
        let managedUsage = try #require(self.reading(id: "managed", plan: "prolite", active: false,
            weekly: 10, session: 2, resetID: "invented-managed-reset", balance: 99).snapshot)
        let base = try #require(store.providerSpecs[.codex])
        store.providerSpecs[.codex] = CodexAccountScopedRefreshTests.makeCodexProviderSpec(baseSpec: base) { context in
            #expect(context.includeCredits)
            let isManaged = context.env["CODEX_HOME"] == managed.managedHomePath
            #expect(context.codexReadOnly == !isManaged)
            #expect(!context.codexAllowsCLIFallback)
            return [TestCodexFetchStrategy(loader: { isManaged ? managedUsage : systemUsage },
                credits: .init(remaining: isManaged ? 99 : 12, events: [], updatedAt: systemUsage.updatedAt))]
        }
        #expect(store.shouldFetchAllCodexVisibleAccounts())
        await store.refreshProvider(.codex, allowDisabled: true)
        let before = store.usagePoolCodexSnapshots()
        #expect(before.count == 2)
        #expect(Set(before.compactMap { $0.snapshot?.secondary?.usedPercent }) == [80, 10])
        #expect(Set(before.compactMap { $0.credits?.remaining }) == [12, 99])
        settings.codexActiveSource = .managedAccount(id: id)
        #expect(store.prepareCodexAccountScopedRefreshIfNeeded())
        let after = store.usagePoolCodexSnapshots()
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map { $0.snapshot?.secondary?.usedPercent } == before.map { $0.snapshot?.secondary?.usedPercent })
        #expect(after.filter { $0.account.isActive }.map { $0.account.email } == ["invented-managed@example.invalid"])
        let context = store.makeFetchContext(provider: .codex, override: nil, includeCredits: true)
        #expect(!context.codexReadOnly)
        #expect(!context.codexAllowsCLIFallback)
        #expect(await CodexCLIUsageStrategy().isAvailable(context) == false)
        await #expect(throws: ProviderFetchError.self) { try await CodexCLIUsageStrategy().fetch(context) }
        #expect(CodexOAuthFetchStrategy().shouldFallback(on: CodexOAuthFetchError.unauthorized, context: context) == false)
    }

    @Test(arguments: ["system", "managed", "direct-system", "symlink-system", "outside"])
    func expiredCredentialsRefreshOnlyInTheManagedHome(homeKind: String) async throws {
        let managed = homeKind == "managed"
        let support = CodexAccountScopedRefreshTests()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let systemHome = root.appendingPathComponent("system")
        let managedRoot = root.appendingPathComponent("managed-codex-homes")
        let managedHome = managedRoot.appendingPathComponent("managed")
        for home in [systemHome, managedHome] {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try Data("""
            {"tokens":{"access_token":"invented-expired","refresh_token":"invented-refresh"},
             "last_refresh":"2020-01-01T00:00:00Z"}
            """.utf8).write(to: home.appendingPathComponent("auth.json"))
        }
        let systemAuth = systemHome.appendingPathComponent("auth.json")
        let systemBefore = try Data(contentsOf: systemAuth)
        let systemAttributes = try FileManager.default.attributesOfItem(atPath: systemAuth.path)
        let symlink = managedRoot.appendingPathComponent("system-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: systemHome)
        let storedHome = switch homeKind {
        case "direct-system": systemHome
        case "symlink-system": symlink
        case "outside": root.appendingPathComponent("outside")
        default: managedHome
        }
        if homeKind == "outside" {
            try FileManager.default.createDirectory(at: storedHome, withIntermediateDirectories: true)
            try systemBefore.write(to: storedHome.appendingPathComponent("auth.json"))
        }
        let id = UUID()
        let account = ManagedCodexAccount(id: id, email: "invented-managed@example.invalid",
            managedHomePath: storedHome.path, createdAt: 1, updatedAt: 2, lastAuthenticatedAt: 2)
        let url = try support.makeManagedAccountStoreURL(accounts: [account])
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = support.makeSettingsStore(suite: "UsagePoolCodexAccountsTests-expired-\(homeKind)")
        settings._test_managedCodexAccountStoreURL = url
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "invented-system@example.invalid", codexHomePath: systemHome.path, observedAt: Date())
        let store = support.makeUsageStore(settings: settings, environmentBase: ["CODEX_HOME": systemHome.path])
        let context = store.makeFetchContext(provider: .codex, override: nil,
            codexActiveSourceOverride: homeKind == "system" ? .liveSystem : .managedAccount(id: id),
            includeCredits: true, managedCodexHomesRoot: managedRoot)
        #expect(context.codexReadOnly == !managed)
        #expect(context.env["CODEX_HOME"] == (homeKind == "system" ? systemHome.path : storedHome.path))
        #expect(try CodexOAuthCredentialsStore.load(env: context.env).needsRefresh)
        let transport = ProviderHTTPTransportStub { request in
            let requestURL = try #require(request.url)
            let isRefresh = requestURL.path == "/oauth/token"
            #expect(managed || !isRefresh)
            let status = managed ? 200 : 401
            let response = try #require(HTTPURLResponse(
                url: requestURL, statusCode: status, httpVersion: nil, headerFields: nil))
            if isRefresh {
                #expect(request.httpMethod == "POST")
                return (Data(#"{"access_token":"invented-new","refresh_token":"invented-new-refresh"}"#.utf8), response)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") ==
                "Bearer \(managed ? "invented-new" : "invented-expired")")
            return (Data(#"{"credits":{"balance":42}}"#.utf8), response)
        }
        try await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            if managed {
                let result = try await CodexOAuthFetchStrategy().fetch(context)
                #expect(result.credits?.remaining == 42)
            } else {
                let error = await #expect(throws: CodexOAuthFetchError.self) {
                    try await CodexOAuthFetchStrategy().fetch(context)
                }
                guard case .unauthorized = error else {
                    Issue.record("Expected an unauthorized usage response")
                    return
                }
            }
        }
        #expect(await transport.requests().count == (managed ? 2 : 1))
        #expect(try Data(contentsOf: systemAuth) == systemBefore)
        let systemAfter = try FileManager.default.attributesOfItem(atPath: systemAuth.path)
        #expect(systemAfter[.modificationDate] as? Date == systemAttributes[.modificationDate] as? Date)
        let managedCredentials = try CodexOAuthCredentialsStore.load(env: ["CODEX_HOME": managedHome.path])
        #expect(managedCredentials.accessToken == (managed ? "invented-new" : "invented-expired"))
        #expect(managedCredentials.refreshToken == (managed ? "invented-new-refresh" : "invented-refresh"))
        #expect(managedCredentials.needsRefresh == !managed)
        #expect(!context.codexAllowsCLIFallback)
        #expect(await CodexCLIUsageStrategy().isAvailable(context) == false)
        await #expect(throws: ProviderFetchError.self) { try await CodexCLIUsageStrategy().fetch(context) }
        #expect(!CodexOAuthFetchStrategy().shouldFallback(on: CodexOAuthFetchError.unauthorized, context: context))
    }

    @Test(arguments: ["managed", "direct-system", "symlink-system", "root"])
    func singleManagedAccountAllowsCLIOnlyInSafeHome(homeKind: String) async throws {
        let support = CodexAccountScopedRefreshTests()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let systemHome = CodexHomeScope.ambientHomeURL(env: [:])
        let symlink = root.appendingPathComponent("system-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: systemHome)
        let home = switch homeKind {
        case "direct-system": systemHome
        case "symlink-system": symlink
        case "root": root
        default: root.appendingPathComponent("managed")
        }
        let id = UUID()
        let account = ManagedCodexAccount(id: id, email: "invented-managed@example.invalid",
            managedHomePath: home.path, createdAt: 1, updatedAt: 2, lastAuthenticatedAt: 2)
        let url = try support.makeManagedAccountStoreURL(accounts: [account])
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = support.makeSettingsStore(suite: "UsagePoolCodexAccountsTests-single-managed-\(homeKind)")
        settings._test_managedCodexAccountStoreURL = url
        settings._test_liveSystemCodexAccount = nil
        settings.codexActiveSource = .managedAccount(id: id)
        let store = support.makeUsageStore(settings: settings, environmentBase: ["CODEX_CLI_PATH": "/usr/bin/true"])
        #expect(!store.shouldFetchAllCodexVisibleAccounts())
        let context = store.makeFetchContext(provider: .codex, override: nil, managedCodexHomesRoot: root)
        let safe = homeKind == "managed"
        #expect(context.env["CODEX_HOME"] == home.path)
        #expect(context.codexReadOnly == !safe)
        #expect(context.codexAllowsCLIFallback == safe)
        #expect(await CodexCLIUsageStrategy().isAvailable(context) == safe)
        #expect(CodexOAuthFetchStrategy().shouldFallback(on: CodexOAuthFetchError.unauthorized, context: context) == safe)
    }

    @Test func singleSystemAccountShowsOneRowAndKeepsCLIFallback() async throws {
        let support = CodexAccountScopedRefreshTests()
        let settings = support.makeSettingsStore(suite: "UsagePoolCodexAccountsTests-single-system")
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .off
        settings._test_liveSystemCodexAccount = support.liveAccount(email: "invented-system@example.invalid")
        let url = try support.makeManagedAccountStoreURL(accounts: [])
        defer { try? FileManager.default.removeItem(at: url) }
        settings._test_managedCodexAccountStoreURL = url
        let store = support.makeUsageStore(settings: settings)
        let reading = try self.reading(id: "system", plan: "pro", active: true,
            weekly: 80, session: 40, resetID: "invented-system-reset", balance: 12)
        support.installImmediateCodexProvider(on: store, snapshot: try #require(reading.snapshot))
        #expect(!store.shouldFetchAllCodexVisibleAccounts())
        await store.refreshProvider(.codex, allowDisabled: true)
        let state = UsagePoolPresentation(overflowConfiguration: { nil })
        state.update(accounts: [], codex: store.snapshots[.codex], sources: [], now: self.now,
            codexAccounts: store.usagePoolCodexSnapshots())
        #expect(state.codexAccounts.count == 1)
        #expect(state.codexAccounts.first?.weekly?.usedPercent == 80)
        #expect(state.codexAccounts.first?.displayName == "Pro 20x")
        let context = store.makeFetchContext(provider: .codex, override: nil)
        #expect(!context.codexReadOnly)
        #expect(context.codexAllowsCLIFallback)
        #expect(CodexOAuthFetchStrategy().shouldFallback(on: CodexOAuthFetchError.unauthorized, context: context))
    }
}
