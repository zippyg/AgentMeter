import AppKit
import CodexBarCore
import Foundation
import Observation

@MainActor
@Observable
final class UsagePoolPresentation {
    private let overflowConfiguration: () -> CodexOverflowConfiguration?
    private let creditCapConfiguration: () -> UsagePoolCreditCap?
    private(set) var creditCap: UsagePoolCreditCap?
    private let fileExists: (String) -> Bool

    init(
        overflowConfiguration: @escaping () -> CodexOverflowConfiguration? = { .load() },
        creditCapConfiguration: @escaping () -> UsagePoolCreditCap? = { .load() },
        fileExists: @escaping (String) -> Bool = FileManager.default.fileExists(atPath:))
    {
        self.overflowConfiguration = overflowConfiguration
        self.fileExists = fileExists
        self.creditCapConfiguration = creditCapConfiguration
    }

    var tab: UsagePoolViewModel.Tab = .overview
    var scenarios: [String: UsagePoolForecast.Scenario] = [:]
    var hideNames = false
    var model = UsagePoolViewModel(now: Date(), claude: nil, codex: nil)
    var analyticsWindow: AllAccountsDashboardModel.Window = .thirtyDays {
        didSet { self.rebuildAnalytics() }
    }
    private var sources: [SharedCostUsage.Source] = []
    private var accountKeyGroups: [[String]] = []
    private(set) var analytics: AllAccountsDashboardModel?
    private(set) var providerCosts: [UsageProvider: AllAccountsDashboardModel] = [:]
    private(set) var providerPlans: [UsageProvider: String] = [:]
    private(set) var codexCredits: CreditsSnapshot?
    private(set) var creditsPurchaseURL: URL?
    var creditsUsageText: String? {
        guard let events = self.codexCredits?.events, !events.isEmpty else { return nil }
        let used = events.reduce(0) { $0 + $1.creditsUsed }
        return "Used so far: \(used.formatted()) credits"
    }
    var accountLabels: [String: String] = [:]
    var errors: [String] = []
    var refreshing = false
    private(set) var accounts: [UsagePoolForecast.Account] = []
    private var codexSnapshot: UsageSnapshot?
    private var codexInputs: [CodexAccountUsageSnapshot] = []
    private(set) var codexAccounts: [UsagePoolForecast.Account] = []
    private(set) var codexModels: [String: UsagePoolViewModel] = [:]
    private(set) var codexAccountCredits: [String: CreditsSnapshot] = [:]
    var codexAccount: UsagePoolForecast.Account? {
        self.codexAccounts.first(where: \.isActive) ?? self.codexAccounts.first
    }

    /// Overview shows only the login in use, never a stand-in; the Claude tab keeps every login.
    var activeClaudeAccount: UsagePoolForecast.Account? {
        self.accounts.first(where: UsagePoolViewModel.isInUse)
    }
    /// Whether the last token scan of each provider saw every log on disk.
    private(set) var scanStatus: [CostUsageScanStatus] = []
    private var scanStatusCheckedAt: Date?
    private var scanStatusRunning = false

    /// Lists the log folders off the main thread, at most once a minute.
    func refreshScanStatus(now: Date) {
        guard !self.scanStatusRunning, self.scanStatusCheckedAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        self.scanStatusCheckedAt = now
        self.scanStatusRunning = true
        let since = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: now)) ?? now
        Task.detached(priority: .utility) { [weak self] in
            let statuses = [UsageProvider.claude, .codex].compactMap { CostUsageScanStatus.current($0, since: since) }
            await MainActor.run {
                self?.scanStatus = statuses
                self?.scanStatusRunning = false
                // Before the first scan of this launch there is nothing to compare: check again next update.
                if statuses.isEmpty { self?.scanStatusCheckedAt = nil }
            }
        }
    }

    /// "Codex logs, 30 days: 1,200 found, 1,150 read (900 compressed), 25 changed since the last scan".
    static func scanStatusText(_ status: CostUsageScanStatus) -> String {
        let name = status.provider == .claude ? "Claude" : "Codex"
        var parts = ["\(status.found.formatted()) found", "\(status.read.formatted()) read"
            + (status.compressedRead > 0 ? " (\(status.compressedRead.formatted()) compressed)" : "")]
        if status.pending > 0 { parts.append("\(status.pending.formatted()) changed since the last scan") }
        if status.unread > 0 { parts.append("\(status.unread.formatted()) not counted") }
        if status.skipped > 0 { parts.append("\(status.skipped.formatted()) skipped, format not read") }
        return "\(name) logs, 30 days: " + parts.joined(separator: ", ")
    }

    /// Every Claude login as a compact row, most weekly headroom first.
    var claudeFleet: UsagePoolFleet {
        UsagePoolFleet.make(accounts: self.accounts, now: self.model.now) { self.name($0, index: $1) }
    }

    var codexFleet: UsagePoolFleet {
        UsagePoolFleet.make(accounts: self.codexAccounts, now: self.model.now) { self.name($0, index: $1) }
    }

    private var fixturePaces: [UsagePoolForecast.Provider: UsagePoolForecast.Pace] = [:]

    func update(
        accounts: [UsagePoolForecast.Account], codex: UsageSnapshot?, sources: [SharedCostUsage.Source],
        claudeSnapshot: UsageSnapshot? = nil, labels: [String: String] = [:], accountKeyGroups: [[String]] = [], now: Date = Date(),
        paces: [UsagePoolForecast.Provider: UsagePoolForecast.Pace] = [:],
        codexCredits: CreditsSnapshot? = nil, creditsPurchaseURL: String? = nil,
        codexAccounts: [CodexAccountUsageSnapshot] = [])
    {
        self.creditCap = self.creditCapConfiguration()
        self.accounts = accounts
        self.codexSnapshot = codex
        self.codexInputs = codexAccounts
        self.codexCredits = codexCredits
        self.creditsPurchaseURL = StatusItemController.sanitizedCreditsPurchaseURL(creditsPurchaseURL)
            .flatMap(URL.init(string:))
        self.providerPlans = [:]
        for (provider, snapshot) in [(UsageProvider.claude, claudeSnapshot), (.codex, codex)] {
            if let plan = snapshot?.loginMethod(for: provider), !plan.isEmpty {
                self.providerPlans[provider] = provider == .codex
                    ? CodexPlanFormatting.displayName(plan) ?? UsageFormatter.cleanPlanName(plan)
                    : UsageFormatter.cleanPlanName(plan)
            }
        }
        self.accountLabels = labels
        for account in accounts {
            let slot = "slot:" + account.id.replacingOccurrences(of: "claude:cswap:", with: "")
            for key in accountKeyGroups.first(where: { $0.contains(slot) }) ?? [slot] {
                self.accountLabels[key] = account.displayName
            }
        }
        self.fixturePaces = paces
        self.sources = sources
        self.accountKeyGroups = accountKeyGroups
        self.recompute(now: now)
        self.rebuildAnalytics()
        self.refreshScanStatus(now: now)
        self.providerCosts = [:]
        for (provider, scope) in [(UsageProvider.claude, AllAccountsDashboardModel.Scope.claude), (.codex, .codex)] {
            self.providerCosts[provider] = AllAccountsDashboardModel.make(sources: sources, scope: scope, now: now)
        }
    }

    /// The configured credit cap applies only to the system login.
    func creditCapForAccount(_ account: UsagePoolForecast.Account) -> UsagePoolCreditCap? {
        self.codexInputs.contains { $0.id == account.id && $0.account.selectionSource == .liveSystem }
            ? self.creditCap : nil
    }

    func creditsBlock(_ account: UsagePoolForecast.Account) -> UsagePoolCredits? {
        UsagePoolCredits(account: account, balance: self.codexAccountCredits[account.id]?.remaining,
                         cap: self.creditCapForAccount(account), now: self.model.now)
    }

    private func rebuildAnalytics() {
        var privateLabels: [String: String] = [:]
        for (index, account) in self.accounts.enumerated() {
            let slot = "slot:" + account.id.replacingOccurrences(of: "claude:cswap:", with: "")
            let keys = self.accountKeyGroups.first { $0.contains(slot) } ?? [slot]
            for key in keys { privateLabels[key] = "Login \(index + 1)" }
        }
        self.analytics = AllAccountsDashboardModel.make(
            sources: self.sources, accountLabels: self.accountLabels, accountKeyGroups: self.accountKeyGroups,
            privateAccountLabels: privateLabels, window: self.analyticsWindow, now: self.model.now)
    }

    func selectScenario(_ scenario: UsagePoolForecast.Scenario, for id: String) {
        self.scenarios[id] = scenario
        self.recompute(now: self.model.now)
    }

    private func recompute(now: Date) {
        self.errors = []
        func forecast(
            _ provider: UsagePoolForecast.Provider, accounts: [UsagePoolForecast.Account], credits: CodexResetCredits? = nil)
            -> UsagePoolForecast.Result?
        {
            guard !accounts.isEmpty else { return nil }
            do {
                return try UsagePoolForecast.forecast(
                    provider: provider, accounts: accounts, now: now, pace: self.fixturePaces[provider],
                    scenarios: self.scenarios, credits: credits)
            } catch {
                if accounts.allSatisfy({ $0.refusedSince != nil }) {
                    self.errors.append("\(provider == .claude ? "Claude" : "Codex") unreadable · pace uses last readings")
                } else {
                    self.errors.append("\(provider == .claude ? "Claude" : "Codex"): a readable weekly clock is needed for a forecast.")
                }
                return nil
            }
        }
        if !self.accounts.isEmpty, self.accounts.allSatisfy({ UsagePoolFleet.isStale($0, now: now) }) {
            self.errors.append("Claude: no fresh reading, so pace and runway wait for one")
        }
        self.codexAccounts = []
        self.codexModels = [:]
        self.codexAccountCredits = [:]
        let inputs: [(id: String, name: String?, snapshot: UsageSnapshot?, active: Bool, error: String?, credits: CreditsSnapshot?)]
        if self.codexInputs.isEmpty {
            inputs = self.codexSnapshot.map { [("codex", nil, $0, true, nil, self.codexCredits)] } ?? []
        } else {
            let activeID = UsagePoolViewModel.activeCodexAccountID(
                self.codexInputs, config: self.overflowConfiguration(), now: now, fileExists: self.fileExists)
            inputs = self.codexInputs.map { input in
                let snapshot = input.snapshot ?? (input.account.isActive ? self.codexSnapshot : nil)
                return (input.id, nil, snapshot, input.id == activeID, input.error,
                        input.account.isActive ? self.codexCredits ?? input.credits : input.credits)
            }
        }
        for input in inputs {
            let plan = CodexPlanFormatting.displayName(input.snapshot?.loginMethod(for: .codex))
            let tier = plan ?? "Login"
            let occurrence = self.codexAccounts.filter {
                $0.displayName == tier || $0.displayName.hasPrefix(tier + " ")
            }.count + 1
            let name = tier + (occurrence > 1 ? " \(occurrence)" : "")
            let windows = [input.snapshot?.primary, input.snapshot?.secondary].compactMap { $0 }
            let account = UsagePoolForecast.Account(
                id: input.id, displayName: name.isEmpty ? "Login" : name,
                weekly: windows.first { $0.windowMinutes == 10080 },
                session: windows.first { $0.windowMinutes == 300 }, measuredAt: input.snapshot?.updatedAt,
                refusedSince: input.error == nil ? nil : now, isActive: input.active)
            self.codexAccounts.append(account)
            self.codexAccountCredits[input.id] = input.credits
            let credits = input.snapshot?.codexResetCredits
            self.codexModels[input.id] = UsagePoolViewModel(
                now: now, claude: nil, codex: forecast(.codex, accounts: [account], credits: credits), resetCredits: credits)
        }
        let selected = self.codexAccount.flatMap { self.codexModels[$0.id] }
        self.model = UsagePoolViewModel(
            // Stale logins are never projected: the Claude runway and events use fresh readings only.
            now: now, claude: forecast(.claude, accounts: self.accounts.filter { !UsagePoolFleet.isStale($0, now: now) }),
            codex: selected?.codex, resetCredits: selected?.resetCredits,
            claudeAccounts: self.accounts, codexAccounts: self.codexAccounts,
            codexWeeklyHistory: Dictionary(uniqueKeysWithValues: self.codexInputs.map { ($0.id, $0.weeklyHistory) }),
            codexResults: self.codexAccounts.compactMap { self.codexModels[$0.id]?.codex })
    }

    func handleKey(
        _ event: NSEvent, refresh: () -> Void, close: () -> Void, settings: () -> Void) -> Bool
    {
        // Read the key event itself. The session key counters lag events on macOS 27.2.
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { close(); return true }
        if modifiers.contains(.command), event.charactersIgnoringModifiers == "," {
            close()
            settings()
            return true
        }
        if let index = StatusItemMenu.providerSelectionIndex(for: event),
           UsagePoolViewModel.Tab.allCases.indices.contains(index)
        {
            self.tab = UsagePoolViewModel.Tab.allCases[index]
            return true
        }
        if let direction = StatusItemMenu.providerSwitcherTabNavigationDirection(for: event) {
            self.tab = self.tab.moved(direction == .next ? 1 : -1)
            return true
        }
        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
        switch event.keyCode {
        case 123: self.tab = self.tab.moved(-1)
        case 124: self.tab = self.tab.moved(1)
        default:
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if key == "r" { refresh() }
            else if let number = Int(key), (1...4).contains(number) {
                self.tab = UsagePoolViewModel.Tab.allCases[number - 1]
            } else { return false }
        }
        return true
    }

    func eventWording(_ event: UsagePoolForecast.Event) -> String {
        guard let index = self.accounts.firstIndex(where: { $0.id == event.accountID }) else { return event.wording }
        guard self.hideNames || self.accounts[index].displayName.contains("@") else { return event.wording }
        let name = self.name(self.accounts[index], index: index)
        switch event.kind {
        case .topUp: return "\(name) tops up"
        case .switchAccount: return "Switch to \(name) by"
        default: return event.wording
        }
    }

    static func displayName(_ name: String, index: Int) -> String {
        name.contains("@") ? "Login \(index + 1)" : name
    }

    func name(_ account: UsagePoolForecast.Account, index: Int) -> String {
        let accounts = self.codexAccounts.contains { $0.id == account.id } ? self.codexAccounts : self.accounts
        return self.hideNames ? "Login \((accounts.firstIndex { $0.id == account.id } ?? index) + 1)" : Self.displayName(account.displayName, index: index)
    }
}
