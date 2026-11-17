import Foundation

/// A read-only forecast in one provider's capacity units. Default tanks hold 100 points.
/// Every number in a Result (including nested events) inherits its assumptions.
public enum UsagePoolForecast {
    public enum Provider: Sendable { case claude, codex }
    public enum Scenario: String, Sendable { case measured, fullAfterPassedTopUp, lastReading, dead }
    public enum ForecastError: Error, Equatable { case invalidInput, missingWeeklyWindow, insufficientHistory }

    public struct Account: Sendable {
        public let id: String
        public let displayName: String
        public let weekly: RateWindow?
        public let session: RateWindow?
        public let scoped: [NamedRateWindow]
        public let measuredAt: Date?
        public let refusedSince: Date?
        public let isRateLimited: Bool
        /// The work login the forecast plans around (claude-swap's chosen work login while Personal overflows).
        public let isActive: Bool
        /// The login claude-swap has signed in right now, which can be Personal during overflow.
        /// Nil when the source does not say; displays then fall back to `isActive`.
        public let isCurrentLogin: Bool?
        public let isPersonal: Bool
        public let capacity: Double
        public let sizeEstimated: Bool
        public var claudeLimitResets: ClaudeLimitResets? = nil

        public init(
            id: String, displayName: String, weekly: RateWindow?, session: RateWindow? = nil,
            scoped: [NamedRateWindow] = [], measuredAt: Date? = nil, refusedSince: Date? = nil,
            isActive: Bool = false, isPersonal: Bool = false, calibratedCapacity: Double? = nil,
            isRateLimited: Bool = false, isCurrentLogin: Bool? = nil)
        {
            self.id = id
            self.displayName = displayName
            self.weekly = weekly
            self.session = session?.resetsAt == nil ? nil : session
            self.scoped = scoped
            self.measuredAt = measuredAt
            self.refusedSince = refusedSince
            self.isRateLimited = isRateLimited
            self.isActive = isActive
            self.isCurrentLogin = isCurrentLogin
            self.isPersonal = isPersonal
            self.capacity = calibratedCapacity ?? 100
            self.sizeEstimated = calibratedCapacity == nil
        }
    }

    public struct Assumptions: Sendable {
        public let scenarios: [String: Scenario]
        public let pace: Pace?
        public let sizeLabel: String
        public let manualActionCost: Double
    }

    public struct Event: Sendable {
        public enum Kind: Sendable { case switchAccount, redeemCredit, topUp, creditExpiry }
        public let kind: Kind
        public let at: Date
        public let accountID: String
        public let displayName: String
        public let creditID: String?
        public let unusedPercent: Double?

        public var wording: String {
            switch self.kind {
            case .switchAccount: "Switch to \(self.displayName) by"
            case .redeemCredit: "Redeem Codex reset by"
            case .topUp: "\(self.displayName) tops up"
            case .creditExpiry: "Codex reset expires"
            }
        }
    }

    public struct Redemption: Sendable {
        public let creditID: String
        public let at: Date
        public let expiresAt: Date?
        public let valuePercent: Double
        /// Points/hour needed to empty the tank before expiry, at the preceding planning event.
        public let paceToUseBeforeExpiry: Double?
        public let paceMeasuredAt: Date
    }

    /// Historical demand and observed waste must cover the same complete 28 days, in capacity units.
    public struct History: Sendable {
        public let demand: Double
        public let waste: Double?
        public init(demand: Double, waste: Double?) {
            self.demand = demand
            self.waste = waste
        }
    }

    public struct Utilisation: Sendable {
        public let wasteBased: Double?
        public let pressureBased: Double
        public let days: Int = 28
    }

    public struct Result: Sendable {
        public let provider: Provider
        public let accounts: [Account]
        public let assumptions: Assumptions
        /// First unmet demand. Nil means covered through evaluatedUntil, not infinite runway.
        public let ownRunwayUntil: Date?
        public let actingRunwayUntil: Date?
        public let evaluatedUntil: Date
        public let horizonUntil: Date
        public let comingUp: [Event]
        public let redemptions: [Redemption]
        /// Capacity discarded by the selected plan over the seven-day horizon, keyed by account.
        public let wasteByAccount: [String: Double]
        public let unmetDemand: Double
        public let utilisation: Utilisation?
        public let unplannedCreditCount: Int
    }

    public static func defaultScenario(for account: Account, now: Date) -> Scenario {
        guard let refused = account.refusedSince else { return account.weekly == nil ? .dead : .measured }
        if let reset = account.weekly?.resetsAt, let measured = account.measuredAt,
           reset > measured, reset <= now, refused <= now, now.timeIntervalSince(refused) < week
        {
            return .fullAfterPassedTopUp
        }
        return .dead
    }

    public static func codexAccount(snapshot: UsageSnapshot, calibratedCapacity: Double? = nil) throws -> Account {
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        guard let weekly = windows.first(where: { $0.windowMinutes == 10080 }) else {
            throw ForecastError.missingWeeklyWindow
        }
        return Account(
            id: "codex", displayName: "Codex", weekly: weekly,
            session: windows.first(where: { $0.windowMinutes == 300 }), measuredAt: snapshot.updatedAt,
            isActive: true, calibratedCapacity: calibratedCapacity)
    }

    public static func forecast(
        provider: Provider, accounts: [Account], now: Date, pace: Pace? = nil,
        scenarios: [String: Scenario] = [:], credits: CodexResetCredits? = nil,
        history: History? = nil, kappa: Double? = nil, continuationDays: Int = 28) throws -> Result
    {
        guard now.timeIntervalSince1970.isFinite, !accounts.isEmpty, accounts.count <= 16,
              Set(accounts.map(\.id)).count == accounts.count,
              accounts.filter({ $0.isActive && !$0.isPersonal }).count <= 1,
              accounts.filter(\.isPersonal).count <= 1,
              continuationDays >= 7, continuationDays <= 90,
              kappa.map({ $0.isFinite && $0 >= 0 }) != false,
              provider != .codex || accounts.count == 1 else { throw ForecastError.invalidInput }
        for account in accounts {
            guard account.capacity.isFinite, account.capacity > 0 else { throw ForecastError.invalidInput }
            for window in [account.weekly, account.session].compactMap({ $0 }) {
                guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                      window.windowMinutes.map({ $0 > 0 }) != false,
                      window.resetsAt.map({ $0.timeIntervalSince1970.isFinite }) != false else {
                    throw ForecastError.invalidInput
                }
            }
        }
        let resolved = Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.id, $0.refusedSince == nil ? self.defaultScenario(for: $0, now: now)
                : scenarios[$0.id] ?? self.defaultScenario(for: $0, now: now))
        })
        let resolvedPace: Pace?
        do {
            resolvedPace = try pace ?? Pace.windowAverage(accounts: accounts, now: now)
        } catch ForecastError.insufficientHistory {
            resolvedPace = nil
        }
        guard let pace = resolvedPace else {
            let horizon = now.addingTimeInterval(week)
            let topUps = accounts.compactMap { account -> Event? in
                guard let reset = account.weekly?.resetsAt, reset > now, reset <= horizon else { return nil }
                return Event(kind: .topUp, at: reset, accountID: account.id,
                             displayName: account.displayName, creditID: nil, unusedPercent: nil)
            }
            let available = provider == .codex ? (credits?.credits ?? []).filter {
                $0.status == "available" && ($0.expiresAt == nil || $0.expiresAt! > now)
            } : []
            let expiries = available.compactMap { credit -> Event? in
                guard let expiry = credit.expiresAt, expiry <= horizon else { return nil }
                return Event(kind: .creditExpiry, at: expiry, accountID: accounts[0].id,
                             displayName: accounts[0].displayName, creditID: credit.id, unusedPercent: nil)
            }
            // Keep observed clocks and banked resets visible without inventing demand or redemption times.
            return Result(provider: provider, accounts: accounts,
                assumptions: Assumptions(scenarios: resolved, pace: nil,
                    sizeLabel: accounts.contains(where: \.sizeEstimated) ? "size estimated" : "size calibrated",
                    manualActionCost: 0),
                ownRunwayUntil: nil, actingRunwayUntil: nil, evaluatedUntil: now, horizonUntil: horizon,
                comingUp: (topUps + expiries).sorted { $0.at < $1.at }, redemptions: [],
                wasteByAccount: [:], unmetDemand: 0, utilisation: nil,
                unplannedCreditCount: provider == .codex
                    ? max(0, (credits?.availableCount ?? 0) - (credits?.credits ?? []).filter { $0.status == "available" }.count) : 0)
        }
        let actionCost = kappa ?? pace.meanPerHour
        guard actionCost.isFinite, actionCost >= 0 else { throw ForecastError.invalidInput }
        let end = now.addingTimeInterval(Double(continuationDays) * day)
        let horizon = now.addingTimeInterval(week)
        let available = provider == .codex ? (credits?.credits ?? []).enumerated().compactMap { index, credit in
            credit.status == "available" && (credit.expiresAt == nil || credit.expiresAt! > now)
                ? BankedCredit(id: credit.id ?? "reset-\(index + 1)", expires: credit.expiresAt) : nil
        }.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) } : []
        var initial = State(accounts: accounts, scenarios: resolved, now: now, credits: available)
        if provider == .codex { initial.active = 0 }
        var own = initial
        while own.time < end {
            own = Search(
                accounts: accounts, pace: pace, end: min(own.time.addingTimeInterval(week), end),
                kappa: actionCost, provider: provider, manual: false).solve(own)
        }
        // Optimize each seven-day event horizon, then continue from its terminal state.
        var selected = initial
        var horizonState = initial
        while selected.time < end {
            let stop = min(selected.time.addingTimeInterval(week), end)
            selected = Search(
                accounts: accounts, pace: pace, end: stop, kappa: actionCost,
                provider: provider, manual: true).solve(selected)
            if stop == horizon { horizonState = selected }
        }
        let utilisation: Utilisation?
        if let history, history.demand.isFinite, history.demand >= 0 {
            let capacity = accounts.filter { resolved[$0.id] != .dead }.reduce(0) { $0 + $1.capacity }
            if capacity > 0 {
                let waste = history.waste.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                utilisation = Utilisation(
                    wasteBased: waste.flatMap { history.demand + $0 > 0 ? history.demand / (history.demand + $0) : nil },
                    pressureBased: history.demand / (4 * capacity))
            } else { utilisation = nil }
        } else { utilisation = nil }
        return Result(
            provider: provider, accounts: accounts,
            assumptions: Assumptions(
                scenarios: resolved, pace: pace,
                sizeLabel: accounts.contains(where: \.sizeEstimated) ? "size estimated" : "size calibrated",
                manualActionCost: actionCost),
            ownRunwayUntil: own.runway, actingRunwayUntil: selected.runway,
            evaluatedUntil: end, horizonUntil: horizon,
            comingUp: selected.events.filter { $0.at <= horizon }.sorted { $0.at < $1.at },
            redemptions: selected.redemptions,
            wasteByAccount: Dictionary(uniqueKeysWithValues: accounts.indices.map {
                (accounts[$0].id, horizonState.waste[$0])
            }), unmetDemand: horizonState.loss, utilisation: utilisation,
            unplannedCreditCount: provider == .codex
                ? max(0, (credits?.availableCount ?? 0) -
                    (credits?.credits ?? []).filter { $0.status == "available" }.count) : 0)
    }

    static let day: TimeInterval = 86400
    static let week: TimeInterval = 7 * day
    static let epsilon = 0.0000001

    private struct BankedCredit {
        let id: String
        let expires: Date?
    }

    private struct State {
        var time: Date
        var balances: [Double]
        var sessionEnds: [Date?]
        var topUps: [Date?]
        var active: Int?
        var personalSelected = false
        var alive: [Bool]
        var credits: [BankedCredit]
        var events: [Event] = []
        var redemptions: [Redemption] = []
        var waste: [Double]
        var loss: Double = 0
        var actions: Int = 0
        var runway: Date?
        var creditMeasuredAt: Date
        var creditMeasuredBalance: Double

        init(accounts: [Account], scenarios: [String: Scenario], now: Date, credits: [BankedCredit]) {
            self.time = now
            self.balances = accounts.map {
                switch scenarios[$0.id] {
                case .fullAfterPassedTopUp: $0.capacity
                case .dead: 0
                case .measured where $0.weekly?.resetsAt.map({ $0 <= now }) == true: $0.capacity
                default: ($0.weekly?.remainingPercent ?? 0) / 100 * $0.capacity
                }
            }
            self.alive = accounts.map { scenarios[$0.id] != .dead && $0.weekly != nil }
            self.topUps = accounts.map { account in
                guard let reset = account.weekly?.resetsAt else { return nil }
                if reset > now { return reset }
                return reset.addingTimeInterval((floor(now.timeIntervalSince(reset) / week) + 1) * week)
            }
            self.sessionEnds = accounts.map {
                guard let session = $0.session, session.usedPercent >= 100,
                      let end = session.resetsAt, end > now else { return nil }
                return end
            }
            self.active = accounts.firstIndex { $0.isActive && !$0.isPersonal }
            self.credits = self.alive.contains(true) ? credits : []
            self.waste = accounts.map { _ in 0 }
            self.creditMeasuredAt = now
            self.creditMeasuredBalance = self.balances.first ?? 0
        }

        func available(_ index: Int) -> Double {
            self.alive[index] && self.sessionEnds[index] == nil ? self.balances[index] : 0
        }

        func automaticSource(accounts: [Account]) -> Int? {
            let personal = accounts.indices.first { accounts[$0].isPersonal && self.available($0) > epsilon }
            if self.personalSelected, let personal { return personal }
            if let active = self.active, self.available(active) > epsilon { return active }
            return personal
        }

        func score(kappa: Double) -> Double { self.waste.reduce(0, +) + Double(self.actions) * kappa }
    }

    private static func candidates(_ state: State, accounts: [Account], pace: Pace, manual: Bool) -> [Int] {
        let rate = pace.rate(at: state.time)
        let automatic = state.automaticSource(accounts: accounts)
        return accounts.indices.filter {
            state.available($0) > epsilon && (manual || $0 == automatic)
        }.sorted { left, right in
            if left == right { return false }
            // Avoid a switch while automatic capacity remains unless capacity would be discarded.
            func risk(_ i: Int) -> Double {
                guard let topUp = state.topUps[i] else { return 0 }
                return max(0, state.balances[i] - rate * topUp.timeIntervalSince(state.time) / 3600)
            }
            if abs(risk(left) - risk(right)) > epsilon { return risk(left) > risk(right) }
            let autoLeft = left == automatic
            let autoRight = right == automatic
            if autoLeft != autoRight { return autoLeft }
            if left == state.active { return true }
            if right == state.active { return false }
            let leftTopUp = state.topUps[left] ?? .distantFuture
            let rightTopUp = state.topUps[right] ?? .distantFuture
            return leftTopUp == rightTopUp ? left < right : leftTopUp < rightTopUp
        }
    }

    private static func advance(
        _ input: State, source: Int?, accounts: [Account], pace: Pace, end: Date, manual: Bool) -> State
    {
        var state = input
        if let source, source != state.automaticSource(accounts: accounts) {
            state.personalSelected = accounts[source].isPersonal
            if !accounts[source].isPersonal { state.active = source }
            state.actions += 1
            state.events.append(Event(
                kind: .switchAccount, at: state.time, accountID: accounts[source].id,
                displayName: accounts[source].displayName, creditID: nil, unusedPercent: nil))
        }
        let rate = pace.rate(at: state.time)
        var next = min(end, pace.nextChange(after: state.time))
        for date in state.topUps.compactMap({ $0 }) + state.sessionEnds.compactMap({ $0 }) where date > state.time {
            next = min(next, date)
        }
        if let source, rate > 0 {
            next = min(next, state.time.addingTimeInterval(state.available(source) / rate * 3600))
        }
        for i in candidates(state, accounts: accounts, pace: pace, manual: manual) {
            if let topUp = state.topUps[i], topUp <= end,
               let deadline = pace.latestStart(consuming: state.available(i), before: topUp, after: state.time),
               deadline.timeIntervalSince(state.time) > 0.001
            {
                next = min(next, deadline)
            }
        }
        if manual {
            for credit in state.credits {
                if let expiry = credit.expires, expiry > state.time {
                    let deadline = max(state.time, expiry.addingTimeInterval(-300))
                    next = min(next, deadline > state.time ? deadline : expiry)
                }
            }
        }
        let demand = rate * next.timeIntervalSince(state.time) / 3600
        if let source {
            state.balances[source] = max(0, state.balances[source] - demand)
        } else if demand > epsilon {
            if state.runway == nil { state.runway = state.time }
            state.loss += demand
        }
        state.time = next
        // Natural top-ups happen before a redemption at exactly the same instant.
        for i in accounts.indices {
            if state.sessionEnds[i].map({ $0 <= next }) == true {
                state.sessionEnds[i] = nil
            }
            if let topUp = state.topUps[i], topUp <= next {
                if state.alive[i] {
                    let unused = state.balances[i]
                    state.waste[i] += unused
                    state.events.append(Event(
                        kind: .topUp, at: next, accountID: accounts[i].id,
                        displayName: accounts[i].displayName, creditID: nil,
                        unusedPercent: unused / accounts[i].capacity * 100))
                    state.balances[i] = accounts[i].capacity
                }
                state.topUps[i] = topUp.addingTimeInterval(week)
            }
        }
        if state.personalSelected, !accounts.indices.contains(where: { accounts[$0].isPersonal && state.available($0) > epsilon }) {
            state.personalSelected = false
        }
        return state
    }

    private static func redeemIfDue(_ input: State, accounts: [Account], pace: Pace) -> State {
        var state = input
        guard accounts.count == 1, state.alive[0] else { return state }
        while let credit = state.credits.first {
            if let expiry = credit.expires, expiry <= state.time {
                state.waste[0] += accounts[0].capacity
                state.events.append(Event(
                    kind: .creditExpiry, at: expiry, accountID: accounts[0].id,
                    displayName: accounts[0].displayName, creditID: credit.id, unusedPercent: 100))
                state.credits.removeFirst()
                state.creditMeasuredAt = state.time
                state.creditMeasuredBalance = state.balances[0]
                continue
            }
            let empty = state.balances[0] <= epsilon
            let deadline = credit.expires.map { $0.addingTimeInterval(-300) <= state.time } ?? false
            guard empty || deadline else { break }
            // Keep the natural weekly clock when a free refill is at most an hour away.
            if let topUp = state.topUps[0], topUp.timeIntervalSince(state.time) <= 3600 { break }
            let value = accounts[0].capacity - state.balances[0]
            // At 0% used a redemption has no value and must not move the weekly clock.
            guard value > epsilon else { break }
            let measuredAt = state.creditMeasuredAt
            let remaining = credit.expires.map { $0.timeIntervalSince(measuredAt) / 3600 }
            state.redemptions.append(Redemption(
                creditID: credit.id, at: state.time, expiresAt: credit.expires,
                valuePercent: value / accounts[0].capacity * 100,
                paceToUseBeforeExpiry: remaining.flatMap {
                    $0 > 0 ? state.creditMeasuredBalance / accounts[0].capacity * 100 / $0 : nil
                },
                paceMeasuredAt: measuredAt))
            state.events.append(Event(
                kind: .redeemCredit, at: state.time, accountID: accounts[0].id,
                displayName: accounts[0].displayName, creditID: credit.id,
                unusedPercent: state.balances[0] / accounts[0].capacity * 100))
            state.waste[0] += state.balances[0]
            state.balances[0] = accounts[0].capacity
            state.topUps[0] = state.time.addingTimeInterval(week)
            state.actions += 1
            state.credits.removeFirst()
            state.creditMeasuredAt = state.time
            state.creditMeasuredBalance = state.balances[0]
        }
        return state
    }

    private static func continuePlan(
        _ input: State, accounts: [Account], pace: Pace, end: Date, manual: Bool) -> State
    {
        var state = input
        while state.time < end {
            if manual { state = self.redeemIfDue(state, accounts: accounts, pace: pace) }
            let source = self.candidates(state, accounts: accounts, pace: pace, manual: manual).first
            state = self.advance(state, source: source, accounts: accounts, pace: pace, end: end, manual: manual)
        }
        return state
    }

    private struct Search {
        let accounts: [Account]
        let pace: Pace
        let end: Date
        let kappa: Double
        let provider: Provider
        let manual: Bool

        func solve(_ initial: State) -> State {
            if self.provider == .codex || !self.manual {
                return continuePlan(initial, accounts: self.accounts, pace: self.pace, end: self.end, manual: self.manual)
            }
            var best = continuePlan(initial, accounts: self.accounts, pace: self.pace, end: self.end, manual: self.manual)
            struct Key: Hashable {
                let time: Date
                let balances: [Double]
                let active: Int?
                let personalSelected: Bool
            }
            var visited: [Key: (loss: Double, score: Double)] = [:]
            // Retain the complete greedy plan if the event search exhausts its budget.
            var nodesRemaining = 4096
            func visit(_ state: State) {
                guard nodesRemaining > 0 else { return }
                nodesRemaining -= 1
                if state.loss > best.loss + epsilon { return }
                if abs(state.loss - best.loss) <= epsilon, state.score(kappa: self.kappa) > best.score(kappa: self.kappa) + epsilon {
                    return
                }
                let key = Key(
                    time: state.time, balances: state.balances, active: state.active,
                    personalSelected: state.personalSelected)
                if let previous = visited[key], previous.loss <= state.loss,
                   previous.score <= state.score(kappa: self.kappa) { return }
                visited[key] = (state.loss, state.score(kappa: self.kappa))
                if state.time >= self.end {
                    let lessLoss = state.loss < best.loss - epsilon
                    let sameLoss = abs(state.loss - best.loss) <= epsilon
                    if lessLoss || (sameLoss && state.score(kappa: self.kappa) < best.score(kappa: self.kappa) - epsilon) {
                        best = state
                    }
                    return
                }
                let choices = candidates(state, accounts: self.accounts, pace: self.pace, manual: self.manual)
                let sources: [Int?] = choices.isEmpty ? [nil] : choices.map(Optional.some)
                for source in sources {
                    visit(advance(
                        state, source: source, accounts: self.accounts, pace: self.pace, end: self.end, manual: self.manual))
                }
            }
            visit(initial)
            return best
        }
    }
}
