import CodexBarCore
import SwiftUI

struct AgentMeterMenuSummaryModel: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UsageProvider
        let title: String
        let systemImageName: String
        let statusText: String
        let status: AgentMeterProviderStatus
        let usedPercent: Double?
        let sessionLine: String
        let weeklyLine: String
        let resetLine: String?
        let tokenLine: String?
        let sourceLine: String
        let updatedLine: String

        var heightFingerprint: String {
            [
                self.id.rawValue,
                self.statusText,
                self.usedPercent.map { String(format: "%.0f", $0) } ?? "nil",
                self.sessionLine,
                self.weeklyLine,
                self.resetLine ?? "nil",
                self.tokenLine ?? "nil",
                self.sourceLine,
                self.updatedLine,
            ].joined(separator: ":")
        }
    }

    static let providerOrder: [UsageProvider] = [.claude, .codex]

    let generatedLine: String
    let rows: [Row]

    init(snapshot: AgentMeterSnapshot, now: Date = .init()) {
        self.generatedLine = UsageFormatter.updatedString(from: snapshot.generatedAt, now: now)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.providers.map { ($0.id, $0) })
        self.rows = Self.providerOrder.compactMap { provider in
            byID[provider.rawValue].map { providerSnapshot in
                Self.row(provider: provider, snapshot: providerSnapshot, now: now)
            }
        }
    }

    var heightFingerprint: String {
        ([self.generatedLine] + self.rows.map(\.heightFingerprint)).joined(separator: "|")
    }

    private static func row(
        provider: UsageProvider,
        snapshot: AgentMeterProviderSnapshot,
        now: Date) -> Row
    {
        let session = snapshot.window(id: "session") ?? snapshot.windows.first
        let weekly = snapshot.window(id: "weekly") ?? snapshot.windows.dropFirst().first
        let effectiveStatus = snapshot.isStale(now: now) ? AgentMeterProviderStatus.stale : snapshot.status
        return Row(
            id: provider,
            title: snapshot.displayName,
            systemImageName: Self.systemImageName(for: provider),
            statusText: Self.statusText(effectiveStatus),
            status: effectiveStatus,
            usedPercent: Self.primaryUsed(session: session, weekly: weekly),
            sessionLine: Self.windowLine(title: "Session", window: session),
            weeklyLine: Self.windowLine(title: "Weekly", window: weekly),
            resetLine: Self.resetLine(session: session, weekly: weekly, now: now),
            tokenLine: Self.tokenLine(snapshot.tokenUsage),
            sourceLine: Self.sourceLine(snapshot.source),
            updatedLine: UsageFormatter.updatedString(from: snapshot.updatedAt, now: now))
    }

    private static func primaryUsed(
        session: AgentMeterUsageWindow?,
        weekly: AgentMeterUsageWindow?) -> Double?
    {
        [session, weekly].compactMap { self.usedPercent(for: $0) }.max()
    }

    private static func windowLine(title: String, window: AgentMeterUsageWindow?) -> String {
        guard let used = self.usedPercent(for: window) else { return "\(title): unavailable" }
        return "\(title): \(Self.percentString(used)) used"
    }

    private static func usedPercent(for window: AgentMeterUsageWindow?) -> Double? {
        guard let window else { return nil }
        if let used = window.usedPercent {
            return used
        }
        if let remaining = window.remainingPercent {
            return 100 - remaining
        }
        return nil
    }

    private static func resetLine(
        session: AgentMeterUsageWindow?,
        weekly: AgentMeterUsageWindow?,
        now: Date) -> String?
    {
        let windows = [session, weekly].compactMap(\.self)
        if let dated = windows
            .compactMap({ window in window.resetsAt.map { (date: $0, title: window.title) } })
            .min(by: { $0.date < $1.date })
        {
            return "\(dated.title) reset \(UsageFormatter.resetCountdownDescription(from: dated.date, now: now))"
        }
        guard let fallback = windows.compactMap(\.resetDescription).first?.nonEmpty else { return nil }
        return "Reset \(fallback)"
    }

    private static func tokenLine(_ tokenUsage: AgentMeterTokenUsageSummary?) -> String? {
        guard let tokenUsage else { return nil }

        var chunks: [String] = []
        if let cost = tokenUsage.sessionCostUSD {
            chunks.append("\(tokenUsage.sessionLabel): \(UsageFormatter.currencyString(cost, currencyCode: "USD"))")
        }
        if let tokens = tokenUsage.sessionTokens {
            chunks.append("\(UsageFormatter.tokenCountString(tokens)) tokens")
        }
        if chunks.isEmpty, let cost = tokenUsage.last30DaysCostUSD {
            chunks.append("\(tokenUsage.last30DaysLabel): \(UsageFormatter.currencyString(cost, currencyCode: "USD"))")
        }
        if chunks.isEmpty, let tokens = tokenUsage.last30DaysTokens {
            chunks.append("\(tokenUsage.last30DaysLabel): \(UsageFormatter.tokenCountString(tokens)) tokens")
        }
        return chunks.isEmpty ? nil : chunks.joined(separator: ", ")
    }

    private static func sourceLine(_ source: AgentMeterSourceDescriptor) -> String {
        "\(self.sourceConfidenceText(source.confidence)) source: \(source.label)"
    }

    private static func sourceConfidenceText(_ confidence: AgentMeterSourceConfidence) -> String {
        switch confidence {
        case .official:
            "Official"
        case .local:
            "Local"
        case .privateEndpoint:
            "Private"
        case .derived:
            "Derived"
        case .unknown:
            "Unknown"
        }
    }

    private static func statusText(_ status: AgentMeterProviderStatus) -> String {
        switch status {
        case .ok:
            "live"
        case .stale:
            "stale"
        case .unavailable:
            "unavailable"
        case .unauthenticated:
            "login needed"
        case .error:
            "error"
        }
    }

    private static func systemImageName(for provider: UsageProvider) -> String {
        switch provider {
        case .claude:
            "sparkles"
        case .codex:
            "terminal"
        default:
            "gauge.with.dots.needle.67percent"
        }
    }

    private static func percentString(_ percent: Double) -> String {
        String(format: "%.0f%%", min(max(percent, 0), 100))
    }
}

struct AgentMeterMenuSummaryView: View {
    let model: AgentMeterMenuSummaryModel
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("AgentMeter")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(self.model.generatedLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ForEach(Array(self.model.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider()
                }
                AgentMeterProviderSummaryRow(row: row)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 10)
        .frame(width: self.width, alignment: .leading)
    }
}

private struct AgentMeterProviderSummaryRow: View {
    let row: AgentMeterMenuSummaryModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                self.providerIcon
                Text(self.row.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(self.row.statusText)
                    .font(.caption2)
                    .foregroundStyle(self.statusColor)
                    .lineLimit(1)
            }

            if let usedPercent = self.row.usedPercent {
                ProgressView(value: usedPercent, total: 100)
                    .tint(self.accentColor)
            }

            HStack(spacing: 8) {
                Text(self.row.sessionLine)
                Text(self.row.weeklyLine)
            }
            .font(.caption)
            .lineLimit(1)

            if let resetLine = self.row.resetLine {
                Text(resetLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let tokenLine = self.row.tokenLine {
                Text(tokenLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text(self.row.sourceLine)
                Text(self.row.updatedLine)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        if self.row.id == .claude, let image = AgentMeterMascotIcon.claudeCreature() {
            AgentMeterClaudeMascotView(image: image)
                .frame(width: 18, height: 18)
        } else if let image = ProviderBrandIcon.image(for: self.row.id) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .foregroundStyle(self.accentColor)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        } else {
            Image(systemName: self.row.systemImageName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(self.accentColor)
                .frame(width: 18, height: 18)
        }
    }

    private var accentColor: Color {
        switch self.row.id {
        case .claude:
            Color(red: 0.78, green: 0.36, blue: 0.16)
        case .codex:
            Color(nsColor: .labelColor)
        default:
            .accentColor
        }
    }

    private var statusColor: Color {
        switch self.row.status {
        case .ok:
            Color(red: 0.08, green: 0.48, blue: 0.36)
        case .stale:
            Color(red: 0.72, green: 0.44, blue: 0.08)
        case .unavailable:
            .secondary
        case .unauthenticated:
            Color(red: 0.72, green: 0.44, blue: 0.08)
        case .error:
            .red
        }
    }
}

extension StatusItemController {
    func addAgentMeterSummaryIfNeeded(to menu: NSMenu, width: CGFloat) -> Bool {
        let model = AgentMeterMenuSummaryModel(snapshot: self.store.agentMeterLiveSnapshot())
        guard !model.rows.isEmpty else { return false }
        menu.addItem(self.makeMenuCardItem(
            AgentMeterMenuSummaryView(model: model, width: width),
            id: "agentMeterSummary",
            width: width,
            heightCacheScope: "agentmeter",
            heightCacheFingerprint: model.heightFingerprint))
        return true
    }
}

extension UsageStore {
    func agentMeterLiveSnapshot(now: Date = .init()) -> AgentMeterSnapshot {
        let providers = AgentMeterMenuSummaryModel.providerOrder.map { provider in
            self.agentMeterProviderSnapshot(provider: provider, now: now)
        }
        return AgentMeterSnapshot(generatedAt: now, providers: providers)
    }

    private func agentMeterProviderSnapshot(
        provider: UsageProvider,
        now: Date) -> AgentMeterProviderSnapshot
    {
        let metadata = self.metadata(for: provider)
        guard let snapshot = self.snapshots[provider] else {
            return AgentMeterProviderSnapshot(
                id: provider.rawValue,
                displayName: metadata.displayName,
                windows: [],
                source: self.agentMeterSourceDescriptor(provider: provider),
                status: self.errors[provider] == nil ? .unavailable : .error,
                updatedAt: now,
                staleAfter: nil)
        }

        let tokenSnapshot = self.tokenSnapshot(fromProviderSnapshot: snapshot, provider: provider)
            ?? self.tokenSnapshots[provider]
        return AgentMeterProviderSnapshot(
            id: provider.rawValue,
            displayName: metadata.displayName,
            accountLabel: snapshot.identity?.accountEmail,
            plan: snapshot.identity?.accountOrganization,
            windows: self.agentMeterWindows(provider: provider, snapshot: snapshot, metadata: metadata),
            spend: snapshot.providerCost.map(Self.agentMeterSpendSummary),
            tokenUsage: tokenSnapshot.map(Self.agentMeterTokenUsageSummary),
            creditsRemaining: provider == .codex ? self.credits?.remaining : nil,
            codeReviewRemainingPercent: nil,
            source: self.agentMeterSourceDescriptor(provider: provider),
            status: self.errors[provider] == nil ? .ok : .error,
            updatedAt: snapshot.updatedAt,
            staleAfter: snapshot.updatedAt.addingTimeInterval(15 * 60))
    }

    private func agentMeterWindows(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        metadata: ProviderMetadata) -> [AgentMeterUsageWindow]
    {
        var windows: [AgentMeterUsageWindow] = []
        if let primary = snapshot.primary {
            windows.append(AgentMeterUsageWindow(
                id: "session",
                title: metadata.sessionLabel,
                rateWindow: primary))
        }
        if let secondary = snapshot.secondary {
            windows.append(AgentMeterUsageWindow(
                id: "weekly",
                title: metadata.weeklyLabel,
                rateWindow: secondary))
        }
        if let tertiary = snapshot.tertiary {
            windows.append(AgentMeterUsageWindow(
                id: "tertiary",
                title: metadata.opusLabel ?? "Tertiary",
                rateWindow: tertiary))
        }
        for extra in snapshot.extraRateWindows ?? [] {
            windows.append(AgentMeterUsageWindow(
                id: extra.id,
                title: extra.title,
                usedPercent: extra.usageKnown ? extra.window.usedPercent : nil,
                remainingPercent: extra.usageKnown ? extra.window.remainingPercent : nil,
                resetsAt: extra.window.resetsAt,
                resetDescription: extra.window.resetDescription,
                windowMinutes: extra.window.windowMinutes))
        }
        return windows
    }

    private func agentMeterSourceDescriptor(provider: UsageProvider) -> AgentMeterSourceDescriptor {
        let label = self.sourceLabel(for: provider)
        return AgentMeterSourceDescriptor(
            confidence: Self.agentMeterSourceConfidence(label: label),
            label: label,
            detail: "Live menu projection")
    }

    private static func agentMeterSourceConfidence(label: String) -> AgentMeterSourceConfidence {
        let lower = label.lowercased()
        if lower.contains("api") || lower.contains("official") {
            return .official
        }
        if lower.contains("local") || lower.contains("cli") || lower.contains("log") {
            return .local
        }
        if lower.contains("web") || lower.contains("dashboard") || lower.contains("cookie") {
            return .privateEndpoint
        }
        return .derived
    }

    private static func agentMeterSpendSummary(_ cost: ProviderCostSnapshot) -> AgentMeterSpendSummary {
        AgentMeterSpendSummary(
            used: cost.used,
            limit: cost.limit,
            remaining: max(0, cost.limit - cost.used),
            currencyCode: cost.currencyCode,
            period: cost.period,
            resetsAt: cost.resetsAt)
    }

    private static func agentMeterTokenUsageSummary(
        _ snapshot: CostUsageTokenSnapshot) -> AgentMeterTokenUsageSummary
    {
        AgentMeterTokenUsageSummary(
            sessionCostUSD: snapshot.sessionCostUSD,
            sessionTokens: snapshot.sessionTokens,
            last30DaysCostUSD: snapshot.last30DaysCostUSD,
            last30DaysTokens: snapshot.last30DaysTokens,
            currencyCode: snapshot.currencyCode,
            sessionLabel: "Today",
            last30DaysLabel: snapshot.historyLabel ?? "\(snapshot.historyDays)d")
    }
}

extension AgentMeterProviderSnapshot {
    fileprivate func window(id: String) -> AgentMeterUsageWindow? {
        self.windows.first { $0.id == id }
    }

    fileprivate func isStale(now: Date) -> Bool {
        guard let staleAfter else { return false }
        return staleAfter < now
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
