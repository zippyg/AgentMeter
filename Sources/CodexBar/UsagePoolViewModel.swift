import CodexBarCore
import Foundation

struct UsagePoolViewModel {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", claude = "Claude", codex = "Codex", spend = "Analytics"
        var id: String { self.rawValue }
        func moved(_ offset: Int) -> Self {
            let tabs = Self.allCases
            let index = tabs.firstIndex(of: self) ?? 0
            return tabs[(index + offset + tabs.count) % tabs.count]
        }
    }

    enum CodexSection: String, CaseIterable, Identifiable {
        case status = "Status", bankedResets = "Banked resets", accountDetails = "Per account details"
        var id: String { self.rawValue }
    }

    var codexSections: [CodexSection] { self.codexAccounts.isEmpty ? [] : CodexSection.allCases }

    var orderedCodexAccounts: [UsagePoolForecast.Account] {
        self.codexAccounts.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            let left = max($0.session?.usedPercent ?? -1, $0.weekly?.usedPercent ?? -1)
            let right = max($1.session?.usedPercent ?? -1, $1.weekly?.usedPercent ?? -1)
            return left == right ? $0.id < $1.id : left > right
        }
    }

    let now: Date
    let claude: UsagePoolForecast.Result?
    let codex: UsagePoolForecast.Result?
    var resetCredits: CodexResetCredits? = nil
    /// Every Claude login, so pool pace can count last readings even when the forecast could not run.
    var claudeAccounts: [UsagePoolForecast.Account] = []
    var codexAccounts: [UsagePoolForecast.Account] = []
    var codexWeeklyHistory: [String: [PlanUtilizationHistoryEntry]] = [:]
    var codexResults: [UsagePoolForecast.Result] = []
    var availableResets: [CodexResetCredits.Credit] {
        (self.resetCredits?.credits ?? []).filter {
            $0.status == "available" && ($0.expiresAt == nil || $0.expiresAt! > self.now)
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
    struct BankedReset {
        let number: Int
        let expiresAt: Date?
        let redemption: UsagePoolForecast.Redemption?
        var kind: String? = nil
        var availability: String? = nil
        var title: String { "\(self.number)" }
    }

    /// One row per available, unexpired reset, numbered once in expiry order, with the planned
    /// redemption attached when the forecast made one. Redemptions for credits that are no longer
    /// available never add rows, so the list always matches the count.
    var bankedResets: [BankedReset] {
        // Each planned redemption is used once: credits without IDs that share an expiry keep separate plans.
        var unmatched = self.codex?.redemptions ?? []
        return self.availableResets.enumerated().map { index, credit in
            let match = unmatched.firstIndex { (redemption: UsagePoolForecast.Redemption) -> Bool in
                if let id = credit.id { return redemption.creditID == id }
                return redemption.expiresAt == credit.expiresAt
            }
            let redemption = match.map { unmatched.remove(at: $0) }
            return BankedReset(number: index + 1, expiresAt: credit.expiresAt, redemption: redemption)
        }
    }

    /// Available resets: listed ones plus those the summary counts without details.
    var bankedResetCount: Int { self.availableResets.count + (self.codex?.unplannedCreditCount ?? 0) }

    private func claudeResets(_ account: UsagePoolForecast.Account) -> ClaudeLimitResets? {
        guard let resets = account.claudeLimitResets else { return nil }
        if let fetchedAt = resets.fetchedAt, self.now.timeIntervalSince(fetchedAt) > 7 * 86400 { return nil }
        return resets
    }

    func claudeBankedResets(_ account: UsagePoolForecast.Account) -> [BankedReset]? {
        self.claudeResets(account).map { resets in
            var rows: [BankedReset] = []
            for grant in resets.available(at: self.now) {
                for _ in 0..<min(grant.resetsLeft, max(0, 20 - rows.count)) {
                    rows.append(BankedReset(number: rows.count + 1, expiresAt: grant.expiresAt,
                                            redemption: nil, kind: grant.kind,
                                            availability: grant.unavailableReason(at: self.now)))
                }
            }
            return rows
        }
    }

    func claudeResetCount(_ account: UsagePoolForecast.Account) -> Int? {
        self.claudeResets(account)?.count(at: self.now)
    }

    func claudeResetDetail(_ account: UsagePoolForecast.Account) -> String? {
        guard let resets = self.claudeResets(account) else { return nil }
        let total = resets.available(at: self.now).reduce(0) { $0 + $1.resetsLeft }
        var details = [String]()
        let unavailable = total - resets.count(at: self.now)
        if unavailable > 0 { details.append("\(unavailable) not yet usable or paused") }
        if total > 20 { details.append("\(total - 20) more") }
        if let age = resets.age(at: self.now) { details.append(age) }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    var claudeBankedResetTotal: String {
        let counts = self.claudeAccounts.compactMap { self.claudeResetCount($0) }
        guard !counts.isEmpty else { return "Unknown" }
        let total = "\(counts.reduce(0, +))" + (counts.count == self.claudeAccounts.count ? "" : "+")
        let unavailable = self.claudeAccounts.compactMap { self.claudeResets($0) }.reduce(0) { sum, resets in
            sum + resets.available(at: self.now).reduce(0) { $0 + $1.resetsLeft } - resets.count(at: self.now)
        }
        return total + (unavailable > 0 ? " · \(unavailable) not usable" : "")
    }

    var expiringCredit: CodexResetCredits.Credit? {
        self.availableResets.first { $0.expiresAt.map { $0.timeIntervalSince(self.now) <= 86400 } == true }
    }
    var results: [UsagePoolForecast.Result] {
        [self.claude].compactMap { $0 } + (self.codexResults.isEmpty ? [self.codex].compactMap { $0 } : self.codexResults)
    }
    /// Both providers use one pace: used percent against the elapsed fraction of the current window,
    /// from readings and clocks alone. Banked resets and demand forecasts never move it.
    /// Stale logins never drive pace: an unreadable, rate-limited, old or pre-reset reading is left out,
    /// so each provider combines only fresh logins.
    var claudePosition: UsagePoolForecast.PacePosition? {
        let accounts = self.claudeAccounts.isEmpty ? self.claude?.accounts ?? [] : self.claudeAccounts
        guard !accounts.isEmpty else { return nil }
        return UsagePoolForecast.poolPacePosition(
            accounts: accounts.filter { !UsagePoolFleet.isStale($0, now: self.now) },
            scenarios: self.claude?.assumptions.scenarios ?? [:], now: self.now)
    }
    var codexPosition: UsagePoolForecast.PacePosition? {
        let accounts = self.codexAccounts.isEmpty ? self.codex?.accounts ?? [] : self.codexAccounts
        return UsagePoolForecast.poolPacePosition(
            accounts: accounts.filter { !UsagePoolFleet.isStale($0, now: self.now) }, now: self.now)
    }

    func codexIsIdle(_ account: UsagePoolForecast.Account) -> Bool {
        guard let weekly = account.weekly, let measured = account.measuredAt,
              !UsagePoolFleet.isStale(account, now: self.now) else { return false }
        let cutoff = measured.addingTimeInterval(-3 * 3600)
        let history = (self.codexWeeklyHistory[account.id] ?? []).filter {
            $0.capturedAt <= measured && $0.resetsAt == weekly.resetsAt
        }.sorted { $0.capturedAt < $1.capturedAt }
        guard let baseline = history.last(where: { $0.capturedAt <= cutoff }),
              cutoff.timeIntervalSince(baseline.capturedAt) <= UsagePoolFleet.staleAfter else { return false }
        let readings = history.filter { $0.capturedAt >= baseline.capturedAt }.map(\.usedPercent)
            + [weekly.usedPercent]
        return zip(readings, readings.dropFirst()).allSatisfy { $1 <= $0 }
    }

    func codexRow(_ account: UsagePoolForecast.Account, name: String) -> UsagePoolAccountRow {
        var row = UsagePoolFleet.row(account, name: name, now: self.now)
        if self.codexIsIdle(account) {
            row.runway = nil
            row.projectionText = "Idle 3h"
        }
        return row
    }

    static func activeCodexAccountID(
        _ inputs: [CodexAccountUsageSnapshot], config: CodexOverflowConfiguration?, now: Date,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String?
    {
        let system = inputs.first { $0.account.selectionSource == .liveSystem }
        guard let config, config.allowsOverflow(now: now) else {
            return inputs.first { $0.account.isActive }?.id ?? inputs.first?.id
        }
        func full(_ input: CodexAccountUsageSnapshot) -> Bool {
            [input.snapshot?.primary, input.snapshot?.secondary].compactMap { $0 }.contains {
                $0.usedPercent >= config.switchAt && $0.resetsAt.map { $0 > now } == true
            }
        }
        guard let system, full(system), fileExists(config.homeURL.appendingPathComponent("auth.json").path) else {
            return system?.id
        }
        let managed = inputs.filter {
            if case .managedAccount = $0.account.selectionSource { return true }
            return false
        }
        let overflow: CodexAccountUsageSnapshot?
        if let email = config.accountEmail {
            overflow = managed.first { $0.account.email.caseInsensitiveCompare(email) == .orderedSame }
        } else {
            overflow = managed.count == 1 ? managed.first : nil
        }
        // An overflow login without a reading is treated as having room.
        return overflow.flatMap { full($0) ? nil : $0.id } ?? system.id
    }

    /// Project pooled remaining capacity to the next top-up using each login's own weekly clock.
    /// Unknown or early clocks keep the existing advice.
    var codexNeedsNoResetNow: Bool {
        let accounts = self.codexAccounts.filter { !UsagePoolFleet.isStale($0, now: self.now) && $0.weekly != nil }
        guard accounts.count > 1,
              let next = accounts.compactMap({ $0.weekly?.resetsAt }).min(), next > self.now else { return false }
        var remaining = 0.0
        var rate = 0.0
        for account in accounts {
            guard let window = account.weekly, let reset = window.resetsAt else { return false }
            let elapsed = self.now.timeIntervalSince(reset) + Double(window.windowMinutes ?? 10080) * 60
            guard elapsed >= 6 * 3600 else { return false }
            remaining += max(0, window.remainingPercent) / 100 * account.capacity
            rate += window.usedPercent / 100 * account.capacity / elapsed
        }
        return remaining > 0 && remaining >= rate * next.timeIntervalSince(self.now)
    }

    var codexResetAdvice: String? { self.codexNeedsNoResetNow ? "Not needed yet" : nil }

    /// How many logins a pace line averages.
    static func averagedLogins(_ position: UsagePoolForecast.PacePosition?) -> Int {
        Set(position?.contributions.map(\.accountID) ?? []).count
    }
    var providerPaces: [(name: String, position: UsagePoolForecast.PacePosition)] {
        [("Claude", self.claudePosition), ("Codex", self.codexPosition)].compactMap { name, position in
            position.map { (name, $0) }
        }
    }
    var pace: UsagePoolForecast.PacePosition {
        self.providerPaces.filter { $0.position.delta != nil }.max { abs($0.position.delta ?? 0) < abs($1.position.delta ?? 0) }?.position
            ?? UsagePoolForecast.pacePosition(results: [], now: self.now)
    }
    var mixedPace: Bool {
        let deltas = self.providerPaces.compactMap { $0.position.delta }
        return deltas.contains { $0 > 0.10 + 0.000000001 } && deltas.contains { $0 < -0.10 - 0.000000001 }
    }
    var overallPaceTitle: String {
        if self.mixedPace { return "Mixed" }
        return Self.paceTitle(self.pace)
    }
    var providerPaceLines: [String] {
        self.providerPaces.map { provider in
            guard provider.position.delta != nil else { return "\(provider.name) unreadable" }
            return "\(provider.name) \(Self.paceShort(provider.position))"
        }
    }

    /// One line explaining the gauge: Mixed names who is fast and who is slow.
    var overallPaceDetail: String? {
        if self.mixedPace {
            let fast = self.providerPaces.filter { ($0.position.delta ?? 0) > 0.10 }.map(\.name)
            let slow = self.providerPaces.filter { ($0.position.delta ?? 0) < -0.10 }.map(\.name)
            return "\(fast.joined(separator: " and ")) fast, \(slow.joined(separator: " and ")) slow"
        }
        return nil
    }
    var comingUp: [UsagePoolForecast.Event] {
        self.results.flatMap(\.comingUp).sorted { $0.at < $1.at }
    }
    var nextAction: UsagePoolForecast.Event? {
        self.comingUp.first { $0.kind == .switchAccount || $0.kind == .redeemCredit }
    }
    var expiringReset: UsagePoolForecast.Redemption? {
        self.results.filter { $0.provider == .codex }.flatMap(\.redemptions).filter {
            $0.expiresAt.map { $0 > self.now && $0.timeIntervalSince(self.now) <= 86400 } == true
        }.min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }
    var menuBarText: String {
        let deadline = ([self.nextAction?.at].compactMap { $0 }
            + self.results.filter { $0.provider == .codex }.flatMap(\.redemptions).map(\.at)).min()
        let time = deadline.map { Self.dateText($0, now: self.now) }
            ?? (self.results.isEmpty ? "Usage unavailable" : "No action in 7d")
        return time + (self.expiringCredit == nil && self.expiringReset == nil ? "" : " •")
    }

    enum PaceState: Equatable {
        case onPace, ahead, behind, mixed, unavailable
    }

    /// Mirrors `overallPaceTitle`: green needs every readable provider within 10 percent.
    var overallPaceState: PaceState {
        self.mixedPace ? .mixed : Self.paceState(self.pace)
    }

    static func paceState(_ position: UsagePoolForecast.PacePosition) -> PaceState {
        guard let delta = position.delta else { return .unavailable }
        if abs(delta) <= 0.10 + 0.000000001 { return .onPace }
        return delta > 0 ? .ahead : .behind
    }

    /// Gauge position from 0 (far behind) to 1 (far ahead); expected usage sits at 0.5.
    static func paceGaugeFraction(_ delta: Double, range: Double = 0.5) -> Double {
        guard delta.isFinite, range > 0 else { return 0.5 }
        return min(1, max(0, 0.5 + delta / (2 * range)))
    }

    /// The forecast needs six hours of the current weekly window before pace means anything.
    static func paceStartDate(_ account: UsagePoolForecast.Account?, now: Date) -> Date? {
        guard let account, account.refusedSince == nil, let weekly = account.weekly,
              let reset = weekly.resetsAt, reset > now else { return nil }
        let duration = Double(weekly.windowMinutes ?? 10080) * 60
        let start = reset.addingTimeInterval(-duration)
        let ready = start.addingTimeInterval(6 * 3600)
        return now >= start && now < ready ? ready : nil
    }

    static func paceUnavailableTitle(_ account: UsagePoolForecast.Account?, now: Date) -> String {
        if self.paceStartDate(account, now: now) != nil { return "Too early" }
        if account?.refusedSince != nil { return "Unreadable" }
        return "No pace"
    }

    static func paceUnavailableDetail(_ account: UsagePoolForecast.Account?, now: Date) -> String {
        if let ready = self.paceStartDate(account, now: now) {
            return "Pace from \(self.dateText(ready, now: now))"
        }
        if account?.refusedSince != nil { return "" }
        return "No weekly clock"
    }

    /// Plain words for the gauge headline. On pace means using the week evenly: by Wednesday noon,
    /// about half of the weekly allowance.
    static func paceTitle(_ position: UsagePoolForecast.PacePosition) -> String {
        guard let delta = position.delta else { return "No pace" }
        let label = abs(delta) <= 0.10 + 0.000000001 ? "On pace" : delta > 0 ? "Fast" : "Slow"
        return "\(label) \(UsagePoolPaceGauge.signed(Int((delta * 100).rounded())))"
    }

    /// Percentage points of the weekly allowance ahead of or behind an even pace.
    static func paceShort(_ position: UsagePoolForecast.PacePosition) -> String {
        guard let delta = position.delta else { return "unavailable" }
        return UsagePoolPaceGauge.signed(Int((delta * 100).rounded()))
    }

    struct LoginPace: Equatable {
        let accountID: String
        let points: Int
        let estimated: Bool
    }

    /// Each login's own distance from an even pace, in points of its weekly allowance, in pool order.
    /// Estimated means it counts from a last reading because the login is unreadable now.
    static func loginPaces(_ position: UsagePoolForecast.PacePosition, accounts: [UsagePoolForecast.Account]) -> [LoginPace] {
        let grouped = Dictionary(grouping: position.contributions, by: \.accountID)
        return accounts.compactMap { account in
            guard let group = grouped[account.id], !group.isEmpty else { return nil }
            let capacity = group.reduce(0) { $0 + $1.capacity }
            let delta = capacity > 0 ? group.reduce(0) { $0 + $1.deltaPoints * $1.capacity } / capacity : 0
            return LoginPace(accountID: account.id, points: Int(delta.rounded()), estimated: account.refusedSince != nil)
        }
    }

    /// Whether this login is signed in right now. The active dot and Overview follow this, not the
    /// forecast's planning login, so Personal shows as active while it absorbs overflow.
    static func isInUse(_ account: UsagePoolForecast.Account) -> Bool {
        account.isCurrentLogin ?? account.isActive
    }

    static func role(_ account: UsagePoolForecast.Account) -> String {
        let inUse = self.isInUse(account)
        let status = account.isRateLimited ? "Rate-limited" : account.refusedSince != nil ? "Unreadable" : nil
        if let status { return inUse ? "Active · \(status)" : status }
        if inUse { return account.isPersonal ? "Active · overflow" : "Active" }
        // claude-swap's chosen work login while Personal overflows.
        if account.isActive { return "Returns after overflow" }
        return account.isPersonal ? "Automatic overflow" : "Switch by hand"
    }

    static func usageText(_ window: RateWindow, unreadable: Bool, estimated: Bool, now: Date,
                          creditsRemaining: Double? = nil) -> String {
        let passed = window.resetsAt.map { $0 <= now } == true
        let emptyText = creditsRemaining.flatMap { balance in
            balance > 0 ? " · on credits" : nil
        } ?? " · exhausted"
        let suffix = !passed && window.usedPercent.rounded() >= 100 ? emptyText : estimated && !unreadable ? " · estimated" : ""
        return "\(Int(window.usedPercent.rounded()))% used" + suffix
    }

    static func resetUseText(_ at: Date, now: Date) -> String {
        at <= now ? "Use now" : "Use when empty, \(Self.dateText(at, now: now))"
    }

    static func showsSession(_ account: UsagePoolForecast.Account, now: Date) -> Bool {
        guard let end = account.session?.resetsAt else { return false }
        return end > now || account.refusedSince != nil
    }

    static func topUpText(_ window: RateWindow, unreadable: Bool, now: Date) -> String? {
        guard let date = self.topUpDate(window, unreadable: unreadable, now: now) else { return nil }
        return "\(date <= now ? "Topped up" : "Tops up") \(self.dateText(date, now: now))"
    }

    static func topUpDate(_ window: RateWindow, unreadable: Bool, now: Date) -> Date? {
        guard let date = window.resetsAt else { return nil }
        let duration = Double(window.windowMinutes ?? 10080) * 60
        let elapsed = now.timeIntervalSince(date)
        return !unreadable && elapsed >= 0 && duration > 0
            ? date.addingTimeInterval((floor(elapsed / duration) + 1) * duration) : date
    }

    /// Where usage would be at an even pace: the elapsed fraction of the window, in percent.
    /// Nil unless both the window length and its upcoming end are known.
    static func steadyPercent(_ window: RateWindow, now: Date) -> Double? {
        guard let end = window.resetsAt, end > now, let minutes = window.windowMinutes, minutes > 0 else { return nil }
        let duration = Double(minutes) * 60
        return 100 * min(1, max(0, 1 - end.timeIntervalSince(now) / duration))
    }

    static func isAwaitingTopUpRead(_ window: RateWindow, unreadable: Bool, now: Date) -> Bool {
        unreadable && window.resetsAt.map { $0 <= now } == true
    }

    static func lastReadText(_ account: UsagePoolForecast.Account, now: Date) -> String {
        guard let date = account.measuredAt else { return "Last read unavailable" }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        let age = minutes < 60 ? "\(minutes)m" : minutes < 1440 ? "\(minutes / 60)h" : "\(minutes / 1440)d"
        return "Last read \(age) ago"
    }

    private static let formatterLock = NSLock()
    private static let dateFormatters: [String: DateFormatter] = {
        Dictionary(uniqueKeysWithValues: ["HH:mm", "EEE HH:mm", "d MMM, HH:mm", "yyyy-MM-dd", "d MMM", "EEE d MMM"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_GB")
            formatter.dateFormat = format
            return (format, formatter)
        })
    }()

    static func dateText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let format = days == 0 ? "HH:mm" : (1...6).contains(days) ? "EEE HH:mm" : "d MMM, HH:mm"
        // Keep timezone updates and formatting together when concurrent callers share the cache.
        return Self.formatterLock.withLock {
            let formatter = Self.dateFormatters[format]!
            formatter.timeZone = calendar.timeZone
            return formatter.string(from: date)
        }
    }

    static func axisDateText(_ day: String) -> String {
        Self.formatterLock.withLock {
            guard let date = Self.dateFormatters["yyyy-MM-dd"]!.date(from: day) else { return day }
            return Self.dateFormatters["d MMM"]!.string(from: date)
        }
    }

    static func weekdayDateText(_ day: String) -> String {
        Self.formatterLock.withLock {
            guard let date = Self.dateFormatters["yyyy-MM-dd"]!.date(from: day) else { return day }
            return Self.dateFormatters["EEE d MMM"]!.string(from: date)
        }
    }

    static func countdown(to date: Date, now: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes >= 48 * 60 { return "\(minutes / 1440)d \(minutes / 60 % 24)h" }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    static func runway(_ date: Date?, result: UsagePoolForecast.Result, now: Date) -> String {
        let end = date ?? result.evaluatedUntil
        let hours = max(0, end.timeIntervalSince(now) / 3600)
        let text = hours < 48 ? "\(Int(hours))h \(Int(hours * 60) % 60)m" : String(format: "%.1f days", hours / 24)
        return date == nil ? "≥ " + text : text
    }
}
