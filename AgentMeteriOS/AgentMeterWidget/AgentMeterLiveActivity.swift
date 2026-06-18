import SwiftUI
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit

@available(iOSApplicationExtension 16.2, *)
struct AgentMeterLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentMeterActivityAttributes.self) { context in
            AgentMeterLiveActivityView(snapshot: context.state.snapshot)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.accentColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    providerIslandLine(
                        context.state.snapshot.providers.first { $0.id == "claude" },
                        generatedAt: context.state.snapshot.generatedAt)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    providerIslandLine(
                        context.state.snapshot.providers.first { $0.id == "codex" },
                        generatedAt: context.state.snapshot.generatedAt)
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

    private func providerIslandLine(_ provider: AgentMeterActivityProvider?, generatedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                AgentMeterProviderIcon(providerID: provider?.id ?? "", size: 12)
                Text(provider?.displayName ?? "NA")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            AgentMeterActivityWindowMiniLine(title: "S", window: provider?.sessionWindow, generatedAt: generatedAt)
            AgentMeterActivityWindowMiniLine(title: "W", window: provider?.weeklyWindow, generatedAt: generatedAt)
        }
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct AgentMeterLiveActivityView: View {
    let snapshot: AgentMeterActivitySnapshot

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
                ForEach(self.snapshot.providers.prefix(2)) { provider in
                    AgentMeterActivityProviderColumn(
                        provider: provider,
                        generatedAt: self.snapshot.generatedAt)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentMeterProviderLockup(
                providerID: self.provider.id,
                fallbackTitle: self.provider.displayName,
                iconSize: 14,
                wordmarkHeight: 12)
            AgentMeterActivityWindowLine(title: "Session", window: self.provider.sessionWindow, generatedAt: self.generatedAt)
            AgentMeterActivityWindowLine(title: "Weekly", window: self.provider.weeklyWindow, generatedAt: self.generatedAt)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct AgentMeterActivityWindowLine: View {
    let title: String
    let window: AgentMeterActivityWindow?
    let generatedAt: Date

    private var phoneWindow: AgentMeterPhoneUsageWindow? {
        self.window?.phoneWindow()
    }

    var body: some View {
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
            AgentMeterActivityPaceBar(window: self.phoneWindow, generatedAt: self.generatedAt, height: 5)
        }
    }

    private var trailingText: String {
        let percent = AgentMeterFormat.percent(self.window?.usedPercent)
        guard let phoneWindow,
              let reset = AgentMeterFormat.resetMetricText(
                resetsAt: phoneWindow.resetsAt,
                resetDescription: phoneWindow.resetDescription,
                from: self.generatedAt)
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
    let generatedAt: Date

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
        guard let phoneWindow = self.window?.phoneWindow() else { return nil }
        return AgentMeterFormat.resetMetricText(
            resetsAt: phoneWindow.resetsAt,
            resetDescription: phoneWindow.resetDescription,
            from: self.generatedAt)
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct AgentMeterActivityPaceBar: View {
    let window: AgentMeterPhoneUsageWindow?
    let generatedAt: Date
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
                if let projection = self.window?.paceProjection(generatedAt: self.generatedAt) {
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
