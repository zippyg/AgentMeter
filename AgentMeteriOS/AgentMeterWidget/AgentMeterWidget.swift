import SwiftUI
import WidgetKit

struct AgentMeterWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: AgentMeterPhoneSnapshot
    let source: AgentMeterPhoneSnapshotSource
}

struct AgentMeterWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgentMeterWidgetEntry {
        AgentMeterWidgetEntry(
            date: Date(),
            snapshot: AgentMeterSampleData.snapshot(),
            source: .sample(AgentMeterPhoneSnapshotStore.defaultURL()))
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentMeterWidgetEntry) -> Void) {
        let result = AgentMeterPhoneSnapshotStore.loadOrSample()
        completion(AgentMeterWidgetEntry(date: Date(), snapshot: result.snapshot, source: result.source))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentMeterWidgetEntry>) -> Void) {
        let result = AgentMeterPhoneSnapshotStore.loadOrSample()
        let entry = AgentMeterWidgetEntry(date: Date(), snapshot: result.snapshot, source: result.source)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

struct AgentMeterWidget: Widget {
    let kind = "AgentMeterWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: self.kind, provider: AgentMeterWidgetProvider()) { entry in
            AgentMeterWidgetView(snapshot: entry.snapshot, source: entry.source)
        }
        .configurationDisplayName("AgentMeter")
        .description("Claude and Codex usage at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct AgentMeterWidgetView: View {
    let snapshot: AgentMeterPhoneSnapshot
    let source: AgentMeterPhoneSnapshotSource
    @Environment(\.widgetFamily) private var family
    @AppStorage(AgentMeterPhoneSettings.usageRangeKey, store: AgentMeterPhoneSettings.sharedDefaults)
    private var usageRangeRawValue = AgentMeterUsageRange.currentSession.rawValue

    private var insights: AgentMeterPhoneInsights {
        AgentMeterPhoneInsights(snapshot: self.snapshot)
    }

    private var selectedRange: AgentMeterUsageRange {
        AgentMeterUsageRange(rawValue: self.usageRangeRawValue) ?? .currentSession
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AgentMeterIdentityMark(size: 18)
                Text("AgentMeter")
                    .font(.headline)
                Spacer()
                Text(self.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(self.statusTint)
            }
            if self.family != .systemSmall {
                WidgetInsightsRow(insights: self.insights, range: self.selectedRange)
            }
            ForEach(self.snapshot.providers.prefix(2)) { provider in
                CompactProviderRow(provider: provider, range: self.selectedRange, generatedAt: self.snapshot.generatedAt)
            }
            if self.family == .systemLarge {
                WidgetDailyUsageChart(points: self.insights.combinedDailyUsage)
            }
            Spacer(minLength: 0)
            Text("Updated \(AgentMeterFormat.relative(self.snapshot.generatedAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .containerBackground(.background, for: .widget)
    }

    private var statusText: String {
        if self.snapshot.isEmpty { return "No data" }
        if self.snapshot.isSampleData { return "Sample" }
        if self.snapshot.isStale { return "Stale" }
        if self.snapshot.hasStaleProvider(reference: Date()) { return "Partial" }
        switch self.source {
        case .cache:
            return "Live"
        case .missing:
            return "No data"
        case .sample:
            return "Sample"
        }
    }

    private var statusTint: Color {
        switch self.statusText {
        case "Live":
            .green
        case "Partial":
            .yellow
        default:
            .orange
        }
    }
}

private struct WidgetInsightsRow: View {
    let insights: AgentMeterPhoneInsights
    let range: AgentMeterUsageRange

    private var totals: AgentMeterRangeTotals {
        self.insights.totals(for: self.range)
    }

    var body: some View {
        HStack(spacing: 12) {
            WidgetInsight(label: self.range.shortTitle, value: AgentMeterFormat.compactNumber(self.totals.tokens))
            WidgetInsight(
                label: "Est. cost",
                value: AgentMeterFormat.money(
                    self.totals.costUSD,
                    currencyCode: self.insights.currencyCode))
            WidgetInsight(label: "Peak", value: self.peakText)
        }
    }

    private var peakText: String {
        guard let usage = self.totals.peakUsage else { return "NA" }
        return "\(usage.displayName) \(AgentMeterFormat.percent(usage.usedPercent))"
    }
}

private struct WidgetInsight: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactProviderRow: View {
    let provider: AgentMeterPhoneProvider
    let range: AgentMeterUsageRange
    let generatedAt: Date

    private var usage: AgentMeterRangeUsage {
        self.provider.usage(for: self.range, generatedAt: self.generatedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                AgentMeterProviderLockup(
                    providerID: self.provider.id,
                    fallbackTitle: self.provider.displayName,
                    iconSize: 16,
                    wordmarkHeight: 13)
                Spacer()
                Text(AgentMeterFormat.percent(self.usage.usedPercent))
                    .font(.subheadline.monospacedDigit())
            }
            if let window = self.usage.window {
                WidgetPaceProjectionBar(window: window, generatedAt: self.generatedAt)
                if let projection = window.paceProjection(generatedAt: self.generatedAt) {
                    Text(projection.label)
                        .font(.caption2)
                        .foregroundStyle(projection.emptiesBeforeReset ? .orange : .secondary)
                }
            } else {
                Text("\(AgentMeterFormat.compactNumber(self.usage.tokens)) tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Weekly")
                Spacer()
                Text(AgentMeterFormat.percent(self.provider.weeklyWindow?.usedPercent))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct WidgetPaceProjectionBar: View {
    let window: AgentMeterPhoneUsageWindow
    let generatedAt: Date

    private var usedFraction: Double {
        min(max((self.window.usedPercent ?? 0) / 100, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(3, width * self.usedFraction))
                if let projection = self.window.paceProjection(generatedAt: self.generatedAt) {
                    Rectangle()
                        .fill(projection.emptiesBeforeReset ? Color.orange : Color.secondary)
                        .frame(width: 2)
                        .offset(x: min(max(0, width * projection.markerPercent), max(0, width - 2)))
                }
            }
        }
        .frame(height: 7)
    }
}

private struct WidgetDailyUsageChart: View {
    let points: [AgentMeterPhoneDailyUsagePoint]

    private var model: AgentMeterDailyUsageChartModel {
        AgentMeterDailyUsageChartModel(dailyUsage: self.points)
    }

    var body: some View {
        if self.model.hasData {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("7d trend")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(AgentMeterFormat.compactNumber(self.model.totalTokens))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    let chartHeight = max(1, proxy.size.height)
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(self.model.points) { point in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor.opacity(0.25 + (0.55 * point.normalizedHeight)))
                                .frame(height: max(3, chartHeight * point.normalizedHeight))
                        }
                    }
                }
                .frame(height: 34)
            }
        }
    }
}
