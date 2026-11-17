import Charts
import CodexBarCore
import SwiftUI

struct AllAccountsDashboardModel: Equatable {
    enum Window: String, CaseIterable, Identifiable {
        case today = "Today", week = "7d", thirtyDays = "30d", month = "This month"
        var id: String { self.rawValue }

        func start(now: Date) -> Date {
            let calendar = Calendar.current
            switch self {
            case .today: return calendar.startOfDay(for: now)
            case .month: return calendar.dateInterval(of: .month, for: now)?.start ?? now
            case .week: return calendar.date(byAdding: .day, value: -6, to: now) ?? now
            case .thirtyDays: return calendar.date(byAdding: .day, value: -29, to: now) ?? now
            }
        }

        /// How the readout names the whole range when no day is picked.
        var rangeTitle: String {
            switch self {
            case .today: "Today"
            case .week: "Last 7 days"
            case .thirtyDays: "Last 30 days"
            case .month: "This month"
            }
        }
    }

    enum Scope: String, CaseIterable {
        case overview, claude, codex

        var engines: Set<String> {
            self == .overview ? ["claude", "codex"] : [self.rawValue]
        }

        var title: String {
            switch self {
            case .overview: "This Mac · All accounts"
            case .claude: "This Mac · Claude"
            case .codex: "This Mac · Codex"
            }
        }
    }

    struct Row: Equatable, Identifiable {
        let id: String
        let label: String
        let tokens: Int
        let cost: Double
        var engine: String = ""
        var shade: Int = 0
        var status: String? = nil
        var privateLabel: String? = nil
    }

    struct ProviderDetail: Equatable, Identifiable {
        var id: String { self.row.id }
        let row: Row
        let users: [UserDetail]
        let models: [Row]
    }

    struct UserDetail: Equatable, Identifiable {
        var id: String { self.row.id }
        let row: Row
        let accounts: [Row]
        var accountModels: [String: [Row]] = [:]
    }

    struct Day: Equatable, Identifiable {
        let id: String
        let values: [Int]
        var costs: [Double] = []
    }

    let scope: Scope
    let tokens: Int
    let cost: Double
    let todayTokens: Int
    let todayCost: Double
    let days: [Day]
    let sources: [Row]
    let engines: [Row]
    let tokenTypes: [Row]
    let models: [Row]
    var subscriptions: [Row] = []
    var window: Window = .thirtyDays
    var providers: [ProviderDetail] = []
    /// Models with tokens but no rate, so their cost counts as zero. Never silently missing.
    var unpriced: [Row] = []

    /// Share of prompt tokens served from cache: cache read over uncached input, cache read and cache write.
    var cacheHitRate: Double? {
        let prompt = self.tokenTypes.filter { $0.id != "output" }.reduce(0) { $0 + $1.tokens }
        let read = self.tokenTypes.first { $0.id == "read" }?.tokens ?? 0
        return prompt > 0 ? Double(read) / Double(prompt) : nil
    }

    var unpricedTokens: Int { self.unpriced.reduce(0) { $0 + $1.tokens } }

    /// Chronological day keys. The chart pins its categorical x scale to these so a highlight mark
    /// drawn before the bars can never move its day to the front.
    var chartDomain: [String] { self.days.map(\.id) }

    var heightFingerprint: String {
        ([self.scope.rawValue, String(self.models.count), String(self.subscriptions.count)]
            + self.sources.map { "\($0.id):\($0.status ?? "")" })
            .joined(separator: "|")
    }

    static func dayKey(from date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    static func make(
        sources: [SharedCostUsage.Source],
        scope: Scope = .overview,
        exportFailures: Set<UsageProvider> = [],
        accountLabels: [String: String] = [:],
        accountKeyGroups: [[String]] = [],
        privateAccountLabels: [String: String] = [:],
        window: Window = .thirtyDays,
        now: Date = Date()) -> Self?
    {
        let sources = sources.filter { scope.engines.contains($0.usage.engine) }.sorted {
            ($0.usage.engine, $0.user) < ($1.usage.engine, $1.user)
        }
        guard !sources.isEmpty else { return nil }
        let today = Self.dayKey(from: now)
        let start = Self.dayKey(from: window.start(now: now))
        let sourceReports = sources.map { source in
            CostUsageDailyReport.merged([.init(data: source.stale ? [] : source.usage.report.data.filter {
                $0.date >= start && $0.date <= today
            }, summary: nil)])
        }
        let report = CostUsageDailyReport.merged(sourceReports)
        let current = report.data.first { $0.date == today }
        let summary = report.summary
        let userNames = Set(sources.map(\.user)).sorted()
        let rows = zip(sources, sourceReports).map { source, report -> Row in
            let totals = report.summary
            let failed = source.user == NSUserName()
                && exportFailures.contains { $0.rawValue == source.usage.engine }
            let status = [source.stale ? "stale, excluded" : nil, failed ? "export failed" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            return Row(
                id: "\(source.user)-\(source.usage.engine)",
                label: "\(source.user) \(source.usage.engine == "claude" ? "Claude" : "Codex")",
                tokens: totals?.totalTokens ?? 0, cost: totals?.totalCostUSD ?? 0,
                engine: source.usage.engine, shade: source.user == NSUserName() ? 0 : 1,
                status: status.isEmpty ? nil : status,
                privateLabel: "User \((userNames.firstIndex(of: source.user) ?? 0) + 1) · \(source.usage.engine == "claude" ? "Claude" : "Codex")")
        }
        let dayCount = Calendar.current.dateComponents(
            [.day], from: Calendar.current.startOfDay(for: window.start(now: now)),
            to: Calendar.current.startOfDay(for: now)).day ?? 0
        let days = (0...max(0, dayCount)).map { offset -> Day in
            let date = Calendar.current.date(byAdding: .day, value: offset, to: window.start(now: now)) ?? now
            let key = Self.dayKey(from: date)
            let entries = sourceReports.map { report in report.data.first { $0.date == key } }
            return Day(id: key, values: entries.map { $0?.totalTokens ?? 0 }, costs: entries.map { $0?.costUSD ?? 0 })
        }
        // Codex reports input with its cached part included; Claude reports uncached input.
        var tokenTotals = (input: 0, read: 0, write: 0, output: 0)
        for (source, sourceReport) in zip(sources, sourceReports) {
            for entry in sourceReport.data {
                let read = entry.cacheReadTokens ?? 0
                let input = entry.inputTokens ?? 0
                tokenTotals.input += source.usage.engine == "codex" ? max(0, input - read) : input
                tokenTotals.read += read
                tokenTotals.write += entry.cacheCreationTokens ?? 0
                tokenTotals.output += entry.outputTokens ?? 0
            }
        }
        // Per source and before any merge: merging an unpriced row into a priced one would hide it.
        var unpricedTotals: [String: Int] = [:]
        for source in sources where !source.stale {
            for entry in source.usage.report.data where entry.date >= start && entry.date <= today {
                for model in entry.modelBreakdowns ?? [] where model.costUSD == nil && (model.totalTokens ?? 0) > 0 {
                    unpricedTotals[model.modelName, default: 0] += model.totalTokens ?? 0
                }
            }
        }
        var modelTotals: [String: Row] = [:]
        for entry in report.data {
            for model in entry.modelBreakdowns ?? [] {
                let previous = modelTotals[model.modelName]
                modelTotals[model.modelName] = Row(
                    id: model.modelName, label: model.modelName,
                    tokens: (previous?.tokens ?? 0) + (model.totalTokens ?? 0),
                    cost: (previous?.cost ?? 0) + (model.costUSD ?? 0))
            }
        }
        // Resolve each user's slot keys before merging; fingerprints identify accounts across users.
        var subscriptionTotals: [String: Row] = [:]
        if scope != .codex {
            for (source, sourceReport) in zip(sources, sourceReports) where source.usage.engine == "claude" {
                for entry in sourceReport.data {
                    for account in entry.accountBreakdowns ?? [] {
                        let key = account.modelName
                        let canResolve = source.user == NSUserName() || key.hasPrefix("acct:")
                        let keys = canResolve ? accountKeyGroups.first { $0.contains(key) } ?? [key] : [key]
                        let identity = keys.sorted().joined(separator: "|")
                        let id = key == "unknown" ? "unknown" :
                            keys.contains(where: { $0.hasPrefix("acct:") }) ? identity : "\(source.user):\(identity)"
                        let label = canResolve ? accountLabels[key] ?? "Unattributed" :
                            key.hasPrefix("slot:") ? "\(source.user) slot \(key.dropFirst(5))" : "Unattributed"
                        let previous = subscriptionTotals[id]
                        subscriptionTotals[id] = Row(
                            id: "sub-" + id, label: label,
                            tokens: (previous?.tokens ?? 0) + (account.totalTokens ?? 0),
                            cost: (previous?.cost ?? 0) + (account.costUSD ?? 0), engine: "claude",
                            privateLabel: canResolve ? privateAccountLabels[key] : nil)
                    }
                }
            }
        }
        var usedLabels: Set<String> = []
        for id in subscriptionTotals.keys.sorted() {
            guard let row = subscriptionTotals[id], row.tokens > 0 else { continue }
            var label = row.label
            var number = 1
            while !usedLabels.insert(label).inserted {
                number += 1
                label = "\(row.label) (\(number))"
            }
            subscriptionTotals[id] = Row(
                id: row.id, label: label, tokens: row.tokens, cost: row.cost, engine: row.engine, privateLabel: row.privateLabel)
        }
        var sourceRows = rows
        for provider in exportFailures.sorted(by: { $0.rawValue < $1.rawValue })
            where scope.engines.contains(provider.rawValue)
                && !sources.contains(where: { $0.user == NSUserName() && $0.usage.engine == provider.rawValue })
        {
            sourceRows.append(Row(
                id: "failed-\(provider.rawValue)", label: "\(NSUserName()) \(provider == .claude ? "Claude" : "Codex")",
                tokens: 0, cost: 0, engine: provider.rawValue, shade: 1, status: "export failed"))
        }
        let engines: [Row] = ["claude", "codex"].filter { scope.engines.contains($0) }.map { engine in
            let totals = CostUsageDailyReport.merged(zip(sources, sourceReports).compactMap {
                $0.usage.engine == engine ? $1 : nil
            }).summary
            return Row(id: engine, label: engine == "claude" ? "Claude" : "Codex",
                       tokens: totals?.totalTokens ?? 0, cost: totals?.totalCostUSD ?? 0, engine: engine)
        }
        return Self(
            scope: scope, tokens: summary?.totalTokens ?? 0, cost: summary?.totalCostUSD ?? 0,
            todayTokens: current?.totalTokens ?? 0, todayCost: current?.costUSD ?? 0,
            days: days, sources: sourceRows,
            engines: engines,
            tokenTypes: [
                Row(id: "input", label: "Input", tokens: tokenTotals.input, cost: 0),
                Row(id: "output", label: "Output", tokens: tokenTotals.output, cost: 0),
                Row(id: "read", label: "Cache read", tokens: tokenTotals.read, cost: 0),
                Row(id: "write", label: "Cache write", tokens: tokenTotals.write, cost: 0),
            ],
            models: Array(modelTotals.values.sorted {
                $0.cost == $1.cost ? $0.id < $1.id : $0.cost > $1.cost
            }),
            subscriptions: subscriptionTotals.values.filter { $0.tokens > 0 }.sorted {
                $0.cost == $1.cost ? $0.id < $1.id : $0.cost > $1.cost
            }, window: window,
            providers: Self.providerDetails(sources: sources, reports: sourceReports, engines: engines,
                accountLabels: accountLabels, accountKeyGroups: accountKeyGroups,
                privateAccountLabels: privateAccountLabels),
            unpriced: unpricedTotals.map { Row(id: "unpriced-" + $0.key, label: $0.key, tokens: $0.value, cost: 0) }
                .sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens })
    }

    private static func providerDetails(
        sources: [SharedCostUsage.Source], reports: [CostUsageDailyReport], engines: [Row],
        accountLabels: [String: String], accountKeyGroups: [[String]], privateAccountLabels: [String: String]) -> [ProviderDetail]
    {
        let users = Set(sources.map(\.user)).sorted()
        return engines.map { engine in
            let matching = zip(sources, reports).filter { $0.0.usage.engine == engine.id }
            let details = users.compactMap { user -> UserDetail? in
                let owned = matching.filter { $0.0.user == user }
                guard !owned.isEmpty else { return nil }
                let entries = owned.flatMap { $0.1.data }
                let total = CostUsageDailyReport.merged(owned.map { $0.1 }).summary
                let row = Row(id: "\(engine.id):\(user)", label: user,
                    tokens: total?.totalTokens ?? 0, cost: total?.totalCostUSD ?? 0, engine: engine.id,
                    status: owned.allSatisfy { $0.0.stale } ? "stale, excluded" : nil,
                    privateLabel: "User \((users.firstIndex(of: user) ?? 0) + 1)")
                var accounts: [String: Row] = [:]
                var accountModels: [String: [CostUsageDailyReport.ModelBreakdown]] = [:]
                for account in entries.flatMap({ $0.accountBreakdowns ?? [] }) {
                    let key = account.modelName
                    let canResolve = engine.id == "claude" && (user == NSUserName() || key.hasPrefix("acct:"))
                    let keys = canResolve ? accountKeyGroups.first { $0.contains(key) } ?? [key] : [key]
                    let identity = keys.sorted().joined(separator: "|")
                    accountModels["\(row.id):\(identity)", default: []] += account.modelBreakdowns ?? []
                    let previous = accounts[identity]
                    let label = canResolve ? accountLabels[key] ?? "Unattributed" :
                        key.hasPrefix("slot:") ? "\(user) slot \(key.dropFirst(5))" : "Unattributed"
                    accounts[identity] = Row(id: "\(row.id):\(identity)", label: label,
                        tokens: (previous?.tokens ?? 0) + (account.totalTokens ?? 0),
                        cost: (previous?.cost ?? 0) + (account.costUSD ?? 0), engine: engine.id,
                        privateLabel: canResolve ? privateAccountLabels[key] : nil)
                }
                var accountRows = accounts.keys.sorted().enumerated().map { index, key in
                    let account = accounts[key]!
                    let fallback = "\(engine.label) account \(index + 1)"
                    return Row(id: account.id, label: engine.id == "codex" && accounts.count == 1 ? "Codex account" :
                            account.label == "Unattributed" && key != "unknown" ? fallback : account.label,
                        tokens: account.tokens, cost: account.cost, engine: account.engine,
                        privateLabel: engine.id == "codex" && accounts.count == 1 ? "Codex account" :
                            account.privateLabel ?? (key == "unknown" ? "Unattributed" : fallback))
                }
                let tokens = row.tokens - accountRows.reduce(0) { $0 + $1.tokens }
                let cost = row.cost - accountRows.reduce(0) { $0 + $1.cost }
                // A missing account split is reported as unallocated counters, never assigned to the current login.
                if tokens > 0 || cost > 0.000001 || accountRows.isEmpty {
                    let codexAccount = engine.id == "codex" && accountRows.isEmpty
                    accountRows.append(Row(id: "\(row.id):unattributed", label: codexAccount ? "Codex account" : "Unattributed",
                        tokens: max(0, tokens), cost: max(0, cost), engine: engine.id,
                        status: nil,
                        privateLabel: codexAccount ? "Codex account" : "Unattributed"))
                }
                let nestedModels = Dictionary(uniqueKeysWithValues: accountRows.map { account in
                    let recorded = accountModels[account.id] ?? []
                    let models = recorded.isEmpty && accountRows.count == 1
                        ? entries.flatMap { $0.modelBreakdowns ?? [] } : recorded
                    return (account.id, Self.modelRows(models, parent: account))
                })
                return UserDetail(row: row, accounts: accountRows, accountModels: nestedModels)
            }
            var models: [String: Row] = [:]
            for model in matching.flatMap({ $0.1.data }).flatMap({ $0.modelBreakdowns ?? [] }) {
                let previous = models[model.modelName]
                models[model.modelName] = Row(id: "\(engine.id):\(model.modelName)", label: model.modelName,
                    tokens: (previous?.tokens ?? 0) + (model.totalTokens ?? 0),
                    cost: (previous?.cost ?? 0) + (model.costUSD ?? 0), engine: engine.id)
            }
            var modelRows = models.values.sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
            let tokens = engine.tokens - modelRows.reduce(0) { $0 + $1.tokens }
            let cost = engine.cost - modelRows.reduce(0) { $0 + $1.cost }
            if tokens > 0 || cost > 0.000001 || modelRows.isEmpty {
                modelRows.append(Row(id: "\(engine.id):unattributed", label: "Unattributed model",
                    tokens: max(0, tokens), cost: max(0, cost), engine: engine.id))
            }
            return ProviderDetail(row: engine, users: details, models: modelRows)
        }
    }

    private static func modelRows(_ models: [CostUsageDailyReport.ModelBreakdown], parent: Row) -> [Row] {
        var totals: [String: Row] = [:]
        for model in models {
            let previous = totals[model.modelName]
            totals[model.modelName] = Row(id: "\(parent.id):\(model.modelName)", label: model.modelName,
                tokens: (previous?.tokens ?? 0) + (model.totalTokens ?? 0),
                cost: (previous?.cost ?? 0) + (model.costUSD ?? 0), engine: parent.engine)
        }
        var rows = totals.values.sorted { $0.tokens == $1.tokens ? $0.id < $1.id : $0.tokens > $1.tokens }
        let tokens = parent.tokens - rows.reduce(0) { $0 + $1.tokens }
        let cost = parent.cost - rows.reduce(0) { $0 + $1.cost }
        if tokens > 0 || cost > 0.000001 || rows.isEmpty {
            rows.append(Row(id: "\(parent.id):unknown-model", label: "Model unavailable",
                tokens: max(0, tokens), cost: max(0, cost), engine: parent.engine))
        }
        return rows
    }
}

struct AllAccountsUsageCard: View {
    let model: AllAccountsDashboardModel
    let width: CGFloat
    var showsDetails = false
    var hideNames = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsedGroups: Set<String> = []
    @State private var hoveredDay: String?
    @State private var pinnedDay: String?
    @State private var focusedSource: String?

    private var secondaryText: Color { Color(white: self.colorScheme == .dark ? 0.72 : 0.28) }

    private var compact: Bool { self.model.scope == .overview && !self.showsDetails }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "desktopcomputer").foregroundStyle(self.secondaryText)
                Text(self.model.scope.title).font(.headline)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageFormatter.tokenCountString(self.model.tokens))
                    .font(.system(size: self.compact ? 17 : self.showsDetails ? 19 : 18, weight: .semibold))
                Text("tokens").font(self.showsDetails ? .subheadline : .caption).foregroundStyle(self.secondaryText)
                Spacer(minLength: 4)
                Text(UsageFormatter.usdString(self.model.cost)).font(.system(size: self.showsDetails ? 16 : 15, weight: .semibold))
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            Text(self.showsDetails ? "\(self.model.window.rangeTitle) · API-equivalent" : "API-equivalent estimate")
                .font(self.showsDetails ? .caption : .caption2).foregroundStyle(self.secondaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if !self.showsDetails {
                HStack(spacing: 4) {
                    Text("Today").foregroundStyle(self.secondaryText)
                    Text("\(UsageFormatter.tokenCountString(self.model.todayTokens)) tokens")
                    Text("·").foregroundStyle(self.secondaryText)
                    Text(UsageFormatter.usdString(self.model.todayCost))
                }
                .font(.caption).monospacedDigit().lineLimit(1)
            }

            if self.compact {
                HStack(spacing: 12) {
                    ForEach(self.model.engines) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            self.legend(row)
                            Text(
                                "\(UsageFormatter.tokenCountString(row.tokens)) · \(UsageFormatter.usdString(row.cost))")
                                .font((self.showsDetails ? Font.subheadline : Font.caption).weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if self.showsDetails {
                self.dayReadout
                // A single day has nothing to compare; the readout above already is today.
                if self.model.window != .today { self.interactiveChart }
            } else {
                self.dailyChart
            }
            if !self.compact {
                if !self.showsDetails {
                    HStack(spacing: 10) {
                        ForEach(self.model.sources.filter { !$0.id.hasPrefix("failed-") }) { row in
                            self.legend(row)
                        }
                    }
                }
                self.tokenBreakdown
                if self.showsDetails { self.provenance }
                Divider()
                ForEach(self.model.providers) { provider in
                    DisclosureGroup(isExpanded: self.expansion(provider.id)) {
                        ForEach(provider.users) { user in
                            DisclosureGroup(isExpanded: self.expansion(user.id)) {
                                ForEach(user.accounts) { account in
                                    DisclosureGroup(isExpanded: self.expansion(account.id)) {
                                        ForEach(user.accountModels[account.id] ?? []) { model in
                                            self.usageRow(model).padding(.leading, 14)
                                        }
                                    } label: { self.usageRow(account) }
                                    .padding(.leading, 14)
                                }
                            } label: { self.usageRow(user.row) }
                            .padding(.leading, 14)
                        }
                    } label: { self.usageRow(provider.row, source: true) }
                }
            } else {
                ForEach(self.model.sources.filter { $0.status != nil }) { row in
                    Text("\(self.displayLabel(row)) · \(row.status ?? "")")
                        .font(self.showsDetails ? .caption : .caption2).foregroundStyle(self.secondaryText)
                }
            }
        }
        .padding(.horizontal, self.showsDetails ? 0 : UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, self.showsDetails ? 0 : 12)
        .frame(width: self.width, alignment: .leading)
        .foregroundStyle(.primary)
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { !self.collapsedGroups.contains(id) }, set: {
            if $0 { self.collapsedGroups.remove(id) } else { self.collapsedGroups.insert(id) }
        })
    }

    private var dailyChart: some View {
        Chart {
            ForEach(self.model.days) { day in
                ForEach(Array(day.values.enumerated()), id: \.offset) { index, tokens in
                    BarMark(x: .value("Day", day.id), y: .value("Tokens", tokens))
                        .foregroundStyle(self.color(self.model.sources[index]))
                        .accessibilityLabel("\(day.id), \(self.displayLabel(self.model.sources[index]))")
                        .accessibilityValue("\(UsageFormatter.tokenCountString(tokens)) tokens")
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .frame(height: self.compact ? 36 : 58)
        .overlay(alignment: .bottom) { Rectangle().fill(.secondary.opacity(0.2)).frame(height: 1) }
        .overlay(alignment: .topLeading) {
            if self.model.tokens == 0 {
                Text("No tokens in this period").font(self.showsDetails ? .caption : .caption2).foregroundStyle(self.secondaryText)
            }
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text(self.model.days.first.map { UsagePoolViewModel.axisDateText($0.id) } ?? "")
                Spacer()
                Text("Today")
            }
            .font(.system(size: self.showsDetails ? 10 : 9)).foregroundStyle(self.secondaryText).offset(y: 13)
        }
        .padding(.bottom, 13)
    }

    private var activeDay: String? { self.hoveredDay ?? self.pinnedDay }

    private var chartSeries: [Int] {
        self.model.sources.indices.filter { index in
            let row = self.model.sources[index]
            return !row.id.hasPrefix("failed-") && (self.focusedSource == nil || self.focusedSource == row.id)
        }
    }

    /// Today by default; the hovered or clicked day otherwise. Fixed rows keep the chart from jumping.
    /// The selected range by default; a hovered or pinned day replaces it, and says so.
    /// Fixed rows keep the chart from jumping as the pointer moves.
    private var dayReadout: some View {
        let day = self.activeDay.flatMap { id in self.model.days.first { $0.id == id } }
        let series = self.chartSeries
        let tokens = day.map { day in series.reduce(0) { $0 + (day.values[safe: $1] ?? 0) } }
        let cost = day.map { day in series.reduce(0.0) { $0 + (day.costs[safe: $1] ?? 0) } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let day {
                    Text("Selected: \(UsagePoolViewModel.weekdayDateText(day.id))").fontWeight(.semibold)
                    if self.pinnedDay != nil {
                        Button { self.pinnedDay = nil; self.hoveredDay = nil } label: {
                            Label("Clear", systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(self.secondaryText)
                        .help("Back to \(self.model.window.rangeTitle)")
                    }
                    Spacer(minLength: 4)
                    Text("\(UsageFormatter.tokenCountString(tokens ?? 0)) tokens")
                    Text(UsageFormatter.usdString(cost ?? 0)).foregroundStyle(self.secondaryText)
                } else {
                    Text("\(self.model.window.rangeTitle) by source").fontWeight(.semibold)
                    Spacer(minLength: 4)
                }
            }
            .font(.subheadline)
            // Each series row doubles as the legend: click to show only that series, again for all.
            ForEach(self.model.sources.indices.filter { !self.model.sources[$0].id.hasPrefix("failed-") }, id: \.self) { index in
                self.seriesRow(index, day: day)
            }
        }
        .monospacedDigit()
    }

    private func seriesRow(_ index: Int, day: AllAccountsDashboardModel.Day?) -> some View {
        let row = self.model.sources[index]
        let selected = self.focusedSource == row.id
        let dimmed = self.focusedSource != nil && !selected
        return Button {
            self.focusedSource = selected ? nil : row.id
        } label: {
            HStack(spacing: 6) {
                Circle().fill(self.color(row)).frame(width: 7, height: 7)
                Text(self.displayLabel(row)).foregroundStyle(self.secondaryText).lineLimit(1)
                if selected {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(self.color(row))
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                Text(UsageFormatter.tokenCountString(day.map { $0.values[safe: index] ?? 0 } ?? row.tokens))
                Text(UsageFormatter.usdString(day.map { $0.costs[safe: index] ?? 0 } ?? row.cost))
                    .foregroundStyle(self.secondaryText).frame(minWidth: 56, alignment: .trailing)
            }
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(selected ? self.color(row).opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(dimmed ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(selected ? "Show all series" : "Show only \(self.displayLabel(row)) in the chart")
    }

    private var interactiveChart: some View {
        Chart {
            if let activeDay {
                RectangleMark(x: .value("Day", activeDay), width: .ratio(1))
                    .foregroundStyle(Color.primary.opacity(0.08))
            }
            ForEach(self.model.days) { day in
                ForEach(self.chartSeries, id: \.self) { index in
                    let row = self.model.sources[index]
                    BarMark(x: .value("Day", day.id), y: .value("Tokens", day.values[safe: index] ?? 0), width: .ratio(0.72))
                        .foregroundStyle(self.color(row))
                        .opacity(self.activeDay == nil || self.activeDay == day.id ? 1 : 0.45)
                        .accessibilityLabel("\(UsagePoolViewModel.weekdayDateText(day.id)), \(self.displayLabel(row))")
                        .accessibilityValue(
                            "\(UsageFormatter.tokenCountString(day.values[safe: index] ?? 0)) tokens, "
                                + UsageFormatter.usdString(day.costs[safe: index] ?? 0))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: self.model.chartDomain)
        .chartYScale(domain: 0...max(1, self.tallestDay))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel {
                    if let tokens = value.as(Int.self) { Text(UsageFormatter.tokenCountString(tokens)) }
                }
                .font(.system(size: 10)).foregroundStyle(self.secondaryText)
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location): self.hoveredDay = self.day(at: location, proxy: proxy, geometry: geometry)
                        case .ended: self.hoveredDay = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        let day = self.day(at: value.location, proxy: proxy, geometry: geometry)
                        self.pinnedDay = day == self.pinnedDay ? nil : day
                    })
            }
        }
        .frame(height: 118)
        .overlay(alignment: .topLeading) {
            if self.model.tokens == 0 {
                Text("No tokens in this period").font(.caption).foregroundStyle(self.secondaryText)
            }
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text(self.model.days.first.map { UsagePoolViewModel.axisDateText($0.id) } ?? "")
                Spacer()
                Text("Today")
            }
            .font(.system(size: 10)).foregroundStyle(self.secondaryText).offset(y: 14)
            .padding(.trailing, 34)
        }
        .padding(.bottom, 14)
        .onChange(of: self.model.window) { _, _ in
            self.pinnedDay = nil
            self.hoveredDay = nil
        }
        .help("Hover for a day's tokens and cost. Click a bar to pin it.")
    }

    /// Fits the scale to the tallest visible stack so the bars use the chart's height.
    private var tallestDay: Int {
        self.model.days.map { day in self.chartSeries.reduce(0) { $0 + (day.values[safe: $1] ?? 0) } }.max() ?? 0
    }

    private func day(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard let plot = proxy.plotFrame else { return nil }
        let frame = geometry[plot]
        guard frame.contains(CGPoint(x: location.x, y: frame.midY)) else { return nil }
        return proxy.value(atX: location.x - frame.origin.x, as: String.self)
    }

    private var tokenBreakdown: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Token mix").font(self.showsDetails ? .subheadline : .caption).foregroundStyle(self.secondaryText)
            GeometryReader { geometry in
                let total = max(1, self.model.tokenTypes.reduce(0) { $0 + $1.tokens })
                HStack(spacing: 0) {
                    ForEach(Array(self.model.tokenTypes.enumerated()), id: \.offset) { index, row in
                        self.tokenColor(index)
                            .frame(width: geometry.size.width * CGFloat(row.tokens) / CGFloat(total))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 6)
            HStack(spacing: 4) {
                ForEach(Array(self.model.tokenTypes.enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Circle().fill(self.tokenColor(index)).frame(width: 6, height: 6)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                            Text(self.displayLabel(row)).foregroundStyle(self.secondaryText)
                        }
                        Text(UsageFormatter.tokenCountString(row.tokens)).fontWeight(.medium)
                    }
                    .font(.system(size: self.showsDetails ? 11 : 10)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Where the dollars come from, and which tokens have no price, so a zero never means a missing rate.
    private var provenance: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let rate = self.model.cacheHitRate {
                Text("Cache hit \(Int((rate * 100).rounded()))%")
            }
            if self.model.unpriced.isEmpty {
                Text("Priced at models.dev rates")
            } else {
                Text("Unpriced, counted as $0: " + self.model.unpriced.prefix(3).map {
                    "\($0.label) \(UsageFormatter.tokenCountString($0.tokens))"
                }.joined(separator: ", ") + (self.model.unpriced.count > 3 ? ", and more" : ""))
                .foregroundStyle(Color.orange)
            }
        }
        .font(.caption).foregroundStyle(self.secondaryText).lineLimit(2)
    }

    private func legend(_ row: AllAccountsDashboardModel.Row) -> some View {
        HStack(spacing: 4) {
            Circle().fill(self.color(row)).frame(width: 6, height: 6)
            Text(self.displayLabel(row)).font(.system(size: self.showsDetails ? 11 : 10)).foregroundStyle(self.secondaryText).lineLimit(1)
        }
    }

    private func usageRow(_ row: AllAccountsDashboardModel.Row, source: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if source { Circle().fill(self.color(row)).frame(width: 5, height: 5) }
                Text(self.displayLabel(row)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(UsageFormatter.tokenCountString(row.tokens)).foregroundStyle(self.secondaryText)
                Text(UsageFormatter.usdString(row.cost)).frame(minWidth: 48, alignment: .trailing)
            }
            .font(.system(size: self.showsDetails ? 12 : 11)).monospacedDigit()
            if let status = row.status {
                Label(status, systemImage: "exclamationmark.triangle")
                    .font(.system(size: self.showsDetails ? 11 : 10)).foregroundStyle(self.secondaryText)
            }
        }
    }

    func displayLabel(_ row: AllAccountsDashboardModel.Row) -> String {
        guard self.hideNames else {
            return UsagePoolPresentation.displayName(row.label,
                index: ([self.model.subscriptions, self.model.sources, self.model.models]
                    + self.model.providers.flatMap { provider in
                        [provider.models] + provider.users.flatMap { user in
                            [user.accounts] + Array(user.accountModels.values)
                        }
                    }).lazy.compactMap { rows in rows.firstIndex { $0.id == row.id } }.first ?? 0)
        }
        if let label = row.privateLabel { return label }
        if let index = self.model.sources.firstIndex(where: { $0.id == row.id }) {
            return "Source \(index + 1) · \(row.engine == "claude" ? "Claude" : "Codex")"
        }
        if let index = self.model.subscriptions.firstIndex(where: { $0.id == row.id }) {
            return "Login \(index + 1)"
        }
        return row.label
    }

    func color(_ row: AllAccountsDashboardModel.Row) -> Color {
        let base = UsageMenuCardView.Model.progressColor(for: row.engine == "claude" ? .claude : .codex)
        if row.engine == "claude", row.shade != 0 {
            return self.colorScheme == .dark
                ? Color(red: 1, green: 0.75, blue: 0.48) : Color(red: 0.55, green: 0.25, blue: 0.08)
        }
        return base.opacity(row.shade == 0 ? 1 : 0.55)
    }

    func tokenColor(_ index: Int) -> Color {
        let tones = self.colorScheme == .dark ? [0.90, 0.72, 0.54, 0.36] : [0.25, 0.43, 0.61, 0.79]
        return Color(white: tones[index % tones.count])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { self.indices.contains(index) ? self[index] : nil }
}
