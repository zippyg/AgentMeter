import Charts
import CodexBarCore
import SwiftUI

struct AllAccountsDashboardModel: Equatable {
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
    }

    struct Day: Equatable, Identifiable {
        let id: String
        let values: [Int]
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
        now: Date = Date()) -> Self?
    {
        let sources = sources.filter { scope.engines.contains($0.usage.engine) }.sorted {
            ($0.usage.engine, $0.user) < ($1.usage.engine, $1.user)
        }
        guard !sources.isEmpty else { return nil }
        let report = SharedCostUsage.mergedReport(sources: sources, now: now)
        let today = Self.dayKey(from: now)
        let current = report.data.first { $0.date == today }
        let summary = report.summary
        let rows = sources.map { source -> Row in
            let totals = SharedCostUsage.mergedReport(sources: [source], now: now).summary
            let failed = source.user == NSUserName()
                && exportFailures.contains { $0.rawValue == source.usage.engine }
            let status = [source.stale ? "stale, excluded" : nil, failed ? "export failed" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            return Row(
                id: "\(source.user)-\(source.usage.engine)",
                label: "\(source.user) \(source.usage.engine == "claude" ? "Claude" : "Codex")",
                tokens: totals?.totalTokens ?? 0, cost: totals?.totalCostUSD ?? 0,
                engine: source.usage.engine, shade: source.user == NSUserName() ? 0 : 1,
                status: status.isEmpty ? nil : status)
        }
        let sourceReports = sources.map { SharedCostUsage.mergedReport(sources: [$0], now: now) }
        let days = (-29...0).map { offset -> Day in
            let date = Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
            let key = Self.dayKey(from: date)
            return Day(id: key, values: sourceReports.map { report in
                report.data.first { $0.date == key }?.totalTokens ?? 0
            })
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
                            cost: (previous?.cost ?? 0) + (account.costUSD ?? 0), engine: "claude")
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
                id: row.id, label: label, tokens: row.tokens, cost: row.cost, engine: row.engine)
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
            let totals = SharedCostUsage.mergedReport(
                sources: sources.filter { $0.usage.engine == engine }, now: now).summary
            return Row(id: engine, label: engine == "claude" ? "Claude" : "Codex",
                       tokens: totals?.totalTokens ?? 0, cost: totals?.totalCostUSD ?? 0, engine: engine)
        }
        return Self(
            scope: scope, tokens: summary?.totalTokens ?? 0, cost: summary?.totalCostUSD ?? 0,
            todayTokens: current?.totalTokens ?? 0, todayCost: current?.costUSD ?? 0,
            days: days, sources: sourceRows,
            engines: engines,
            tokenTypes: [
                Row(id: "input", label: "Input", tokens: summary?.totalInputTokens ?? 0, cost: 0),
                Row(id: "output", label: "Output", tokens: summary?.totalOutputTokens ?? 0, cost: 0),
                Row(id: "read", label: "Cache read", tokens: summary?.cacheReadTokens ?? 0, cost: 0),
                Row(id: "write", label: "Cache write", tokens: summary?.cacheCreationTokens ?? 0, cost: 0),
            ],
            models: Array(modelTotals.values.sorted {
                $0.cost == $1.cost ? $0.id < $1.id : $0.cost > $1.cost
            }.prefix(3)),
            subscriptions: subscriptionTotals.values.filter { $0.tokens > 0 }.sorted {
                $0.cost == $1.cost ? $0.id < $1.id : $0.cost > $1.cost
            })
    }
}

struct AllAccountsUsageCard: View {
    let model: AllAccountsDashboardModel
    let width: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var compact: Bool { self.model.scope == .overview }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                Text(self.model.scope.title).font(.headline)
                Spacer(minLength: 0)
                Text("30 DAYS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageFormatter.tokenCountString(self.model.tokens))
                    .font(.system(size: self.compact ? 28 : 30, weight: .semibold, design: .rounded))
                Text("tokens").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(UsageFormatter.usdString(self.model.cost)).font(.title3.weight(.semibold))
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            Text("API-equivalent estimate").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: 4) {
                Text("Today").foregroundStyle(.secondary)
                Text("\(UsageFormatter.tokenCountString(self.model.todayTokens)) tokens")
                Text("·").foregroundStyle(.secondary)
                Text(UsageFormatter.usdString(self.model.todayCost))
            }
            .font(.caption).monospacedDigit().lineLimit(1)

            if self.compact {
                HStack(spacing: 12) {
                    ForEach(self.model.engines) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            self.legend(row)
                            Text(
                                "\(UsageFormatter.tokenCountString(row.tokens)) · \(UsageFormatter.usdString(row.cost))")
                                .font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            self.dailyChart
            if !self.compact {
                HStack(spacing: 10) {
                    ForEach(self.model.sources.filter { !$0.id.hasPrefix("failed-") }) { row in
                        self.legend(row)
                    }
                }
                self.tokenBreakdown
                if !self.model.models.isEmpty {
                    Divider()
                    Text("TOP MODELS · 30D").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(self.model.models) { row in self.usageRow(row) }
                }
                Divider()
                ForEach(self.model.sources) { row in self.usageRow(row, source: true) }
                if self.model.subscriptions.count > 1
                    || self.model.subscriptions.first.map({ $0.label != "Unattributed" }) == true
                {
                    Divider()
                    Text("BY SUBSCRIPTION · 30D").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(self.model.subscriptions) { row in self.usageRow(row) }
                }
            } else {
                ForEach(self.model.sources.filter { $0.status != nil }) { row in
                    Text("\(row.label) · \(row.status ?? "")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
        .foregroundStyle(.primary)
    }

    private var dailyChart: some View {
        Chart {
            ForEach(self.model.days) { day in
                ForEach(Array(day.values.enumerated()), id: \.offset) { index, tokens in
                    BarMark(x: .value("Day", day.id), y: .value("Tokens", tokens))
                        .foregroundStyle(self.color(self.model.sources[index]))
                        .accessibilityLabel("\(day.id), \(self.model.sources[index].label)")
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
                Text("No tokens in the last 30 days").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .bottom) {
            HStack {
                Text(String(self.model.days.first?.id.suffix(5) ?? ""))
                Spacer()
                Text("Today")
            }
            .font(.system(size: 9)).foregroundStyle(.secondary).offset(y: 13)
        }
        .padding(.bottom, 13)
    }

    private var tokenBreakdown: some View {
        VStack(alignment: .leading, spacing: 5) {
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
                            Circle().fill(self.tokenColor(index)).frame(width: 4, height: 4)
                            Text(row.label).foregroundStyle(.secondary)
                        }
                        Text(UsageFormatter.tokenCountString(row.tokens)).fontWeight(.medium)
                    }
                    .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func legend(_ row: AllAccountsDashboardModel.Row) -> some View {
        HStack(spacing: 4) {
            Circle().fill(self.color(row)).frame(width: 6, height: 6)
            Text(row.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func usageRow(_ row: AllAccountsDashboardModel.Row, source: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if source { Circle().fill(self.color(row)).frame(width: 5, height: 5) }
                Text(row.label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(UsageFormatter.tokenCountString(row.tokens)).foregroundStyle(.secondary)
                Text(UsageFormatter.usdString(row.cost)).frame(minWidth: 48, alignment: .trailing)
            }
            .font(.system(size: 11)).monospacedDigit()
            if let status = row.status {
                Label(status, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ row: AllAccountsDashboardModel.Row) -> Color {
        if row.engine == "claude" {
            return row.shade == 0 ? Color(red: 0.82, green: 0.39, blue: 0.20)
                : Color(red: 0.95, green: 0.65, blue: 0.40)
        }
        if self.colorScheme == .dark {
            return row.shade == 0 ? Color(white: 0.92) : Color(white: 0.57)
        }
        return row.shade == 0 ? Color(white: 0.28) : Color(white: 0.61)
    }

    private func tokenColor(_ index: Int) -> Color {
        [Color.orange, Color.blue, Color.teal, Color.purple][index]
    }
}
