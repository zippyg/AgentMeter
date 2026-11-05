import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit

@available(iOSApplicationExtension 16.2, *)
struct AgentMeterLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentMeterActivityAttributes.self) { context in
            AgentMeterLiveActivityView(snapshot: context.state.snapshot, isActivityStale: context.isStale)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.accentColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    providerIslandLine(
                        context.state.snapshot.providers.first { ($0.providerID ?? $0.id) == "claude" && $0.isActiveCLI == true }
                            ?? context.state.snapshot.providers.first { ($0.providerID ?? $0.id) == "claude" },
                        isActivityStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    providerIslandLine(
                        context.state.snapshot.providers.first { $0.id == "codex" },
                        isActivityStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 4) {
                        AgentMeterIdentityMark(size: 13)
                        Text("AgentMeter")
                            .font(.caption2.weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("AgentMeter")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Updated \(AgentMeterFormat.relative(context.state.updatedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                AgentMeterActivityGlyph(size: 16)
            } compactTrailing: {
                Text(AgentMeterFormat.percent(context.state.snapshot.peakSessionUsedPercent))
                    .font(.caption2.weight(.semibold).monospacedDigit())
            } minimal: {
                AgentMeterActivityGlyph(size: 16)
            }
        }
    }

    private func providerIslandLine(
        _ provider: AgentMeterActivityProvider?,
        isActivityStale: Bool)
        -> some View
    {
        let referenceDate = Date()
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                AgentMeterProviderIcon(providerID: provider?.id ?? "", size: 12)
                Text(provider?.displayName ?? "NA")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            AgentMeterActivityWindowMiniLine(
                title: "S",
                window: provider?.sessionWindow,
                isStale: provider?.isStale(
                    reference: referenceDate,
                    activityIsStale: isActivityStale) ?? isActivityStale,
                referenceDate: referenceDate)
            AgentMeterActivityWindowMiniLine(
                title: "W",
                window: provider?.weeklyWindow,
                isStale: provider?.isStale(
                    reference: referenceDate,
                    activityIsStale: isActivityStale) ?? isActivityStale,
                referenceDate: referenceDate)
        }
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct AgentMeterLiveActivityView: View {
    let snapshot: AgentMeterActivitySnapshot
    let isActivityStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AgentMeterIdentityMark(size: 18)
                Text("AgentMeter")
                    .font(.headline)
                Spacer()
                Text("Claude + Codex")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(self.snapshot.providers) { provider in
                    AgentMeterActivityProviderColumn(
                        provider: provider,
                        generatedAt: self.snapshot.generatedAt,
                        isActivityStale: self.isActivityStale)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct AgentMeterActivityProviderColumn: View {
    let provider: AgentMeterActivityProvider
    let generatedAt: Date
    let isActivityStale: Bool

    var body: some View {
        let referenceDate = Date()
        let isStale = self.provider.isStale(
            reference: referenceDate,
            activityIsStale: self.isActivityStale)
        let observationDate = self.provider.updatedAt ?? self.generatedAt
        VStack(alignment: .leading, spacing: 6) {
            AgentMeterProviderLockup(
                providerID: self.provider.id,
                fallbackTitle: self.provider.displayName,
                iconSize: 14,
                wordmarkHeight: 12)
            AgentMeterActivityWindowLine(
                title: "Session",
                window: self.provider.sessionWindow,
                observationDate: observationDate,
                isStale: isStale,
                referenceDate: referenceDate)
            AgentMeterActivityWindowLine(
                title: "Weekly",
                window: self.provider.weeklyWindow,
                observationDate: observationDate,
                isStale: isStale,
                referenceDate: referenceDate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct AgentMeterActivityWindowLine: View {
    let title: String
    let window: AgentMeterActivityWindow?
    let observationDate: Date
    let isStale: Bool
    let referenceDate: Date

    private var phoneWindow: AgentMeterPhoneUsageWindow? {
        self.window?.phoneWindow()
    }

    var body: some View {
        let projection = self.isStale ? nil : self.phoneWindow?.paceProjection(
            observedAt: self.observationDate,
            referenceDate: self.referenceDate)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(self.title)
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 4)
                Text(self.trailingText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            AgentMeterActivityPaceBar(
                window: self.phoneWindow,
                projection: projection,
                height: 5)
        }
    }

    private var trailingText: String {
        let percent = AgentMeterFormat.percent(self.window?.usedPercent)
        guard !self.isStale,
              let phoneWindow,
              let reset = AgentMeterFormat.resetMetricText(
                resetsAt: phoneWindow.resetsAt,
                resetDescription: phoneWindow.resetDescription,
                from: self.referenceDate)
        else {
            return "\(percent) used"
        }
        return "\(percent) • \(reset)"
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct AgentMeterActivityWindowMiniLine: View {
    let title: String
    let window: AgentMeterActivityWindow?
    let isStale: Bool
    let referenceDate: Date

    var body: some View {
        HStack(spacing: 3) {
            Text(self.title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(AgentMeterFormat.percent(self.window?.usedPercent))
                .font(.caption2.monospacedDigit())
            if let reset = self.resetText {
                Text(reset)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var resetText: String? {
        guard !self.isStale, let phoneWindow = self.window?.phoneWindow() else { return nil }
        return AgentMeterFormat.resetMetricText(
            resetsAt: phoneWindow.resetsAt,
            resetDescription: phoneWindow.resetDescription,
            from: self.referenceDate)
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct AgentMeterActivityPaceBar: View {
    let window: AgentMeterPhoneUsageWindow?
    let projection: AgentMeterPaceProjection?
    let height: CGFloat

    private var usedFraction: Double {
        min(max((self.window?.usedPercent ?? 0) / 100, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(self.height, width * self.usedFraction))
                if let projection {
                    Rectangle()
                        .fill(projection.emptiesBeforeReset ? Color.red : Color.secondary)
                        .frame(width: 2)
                        .offset(x: min(max(0, width * projection.markerPercent), max(0, width - 2)))
                }
            }
        }
        .frame(height: self.height)
    }
}

private struct AgentMeterActivityGlyph: View {
    let size: CGFloat

    var body: some View {
        AgentMeterIdentityMark(size: self.size)
    }
}
#endif
