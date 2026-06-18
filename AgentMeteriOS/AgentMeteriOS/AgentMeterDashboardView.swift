import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit
#endif

private enum AgentMeterAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct AgentMeterDashboardView: View {
    private static let pairingCodeAlphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let pairingCodeLength = 12

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AgentMeterPhoneSettings.usageRangeKey, store: AgentMeterPhoneSettings.sharedDefaults)
    private var usageRangeRawValue = AgentMeterUsageRange.currentSession.rawValue
    @AppStorage(AgentMeterPhoneSettings.appearanceKey, store: AgentMeterPhoneSettings.sharedDefaults)
    private var appearanceRawValue = AgentMeterAppearance.system.rawValue
    @StateObject private var model = AgentMeterSnapshotModel()
    @State private var activityStatus = "Not running"
    @State private var isImportingSnapshot = false
    @State private var pairingCode = ""
    #if DEBUG
    @State private var didHandleLaunchAutomation = false
    private static let autostartLiveActivityEnvironmentKey = "AGENTMETER_AUTOSTART_LIVE_ACTIVITY"
    #endif

    private var snapshot: AgentMeterPhoneSnapshot {
        self.model.snapshot
    }

    private var insights: AgentMeterPhoneInsights {
        AgentMeterPhoneInsights(snapshot: self.snapshot)
    }

    private var selectedRange: AgentMeterUsageRange {
        AgentMeterUsageRange(rawValue: self.usageRangeRawValue) ?? .currentSession
    }

    private var selectedAppearance: AgentMeterAppearance {
        AgentMeterAppearance(rawValue: self.appearanceRawValue) ?? .system
    }

    private var isBridgeLive: Bool {
        self.model.bridgeMessage.hasPrefix("Live")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryHeader
                    pairingPanel
                    UsageRangePicker(selection: self.$usageRangeRawValue)
                    InsightsGrid(
                        insights: self.insights,
                        range: self.selectedRange,
                        generatedAt: self.snapshot.generatedAt)
                    providerGrid
                    liveActivityControls
                }
                .padding(18)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("AgentMeter")
            .preferredColorScheme(self.selectedAppearance.colorScheme)
            .onAppear {
                self.model.refresh()
                self.model.startBridgeSync()
                self.handleLaunchAutomationIfNeeded()
            }
            .onOpenURL { url in
                if self.model.handlePairingURL(url) {
                    return
                }
                if self.model.importSnapshot(from: url) {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
            .onChange(of: self.snapshot.snapshotSequence) { _, _ in
                self.updateLiveActivitySilently()
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Appearance", selection: self.$appearanceRawValue) {
                            ForEach(AgentMeterAppearance.allCases) { appearance in
                                Text(appearance.title).tag(appearance.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "circle.lefthalf.filled")
                    }
                    Button {
                        self.isImportingSnapshot = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Button {
                        self.model.refreshFromBridgeOrCache()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .fileImporter(
                isPresented: self.$isImportingSnapshot,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                if case let .success(urls) = result,
                   let url = urls.first,
                   self.model.importSnapshot(from: url) {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AgentMeterIdentityMark(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude + Codex")
                        .font(.headline)
                    Text("Updated \(AgentMeterFormat.relative(self.snapshot.generatedAt))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusPill
            }
            Label(self.model.sourceMessage, systemImage: self.snapshot.isSampleData || self.snapshot.isEmpty ? "exclamationmark.triangle" : "externaldrive")
                .font(.footnote)
                .foregroundStyle(self.snapshot.isSampleData || self.snapshot.isEmpty ? .orange : .secondary)
            Label(self.model.bridgeMessage, systemImage: "antenna.radiowaves.left.and.right")
                .font(.footnote)
                .foregroundStyle(self.model.bridgeMessage.hasPrefix("Live") ? .green : .secondary)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var pairingPanel: some View {
        if let invitation = self.model.pendingPairingInvitation {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pair \(invitation.serviceName)")
                    .font(.headline)
                Text("Enter the one-time code shown on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Code", text: self.$pairingCode)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .textFieldStyle(.roundedBorder)
                    Button("Pair") {
                        self.model.completePendingPairing(code: self.pairingCode)
                        self.pairingCode = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.model.isCompletingPairing || self.normalizedPairingCode.count != Self.pairingCodeLength)
                    Button("Cancel") {
                        self.pairingCode = ""
                        self.model.cancelPendingPairing()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var normalizedPairingCode: String {
        self.pairingCode.uppercased().filter { character in
            Self.pairingCodeAlphabet.contains(character)
        }
    }

    private var statusPill: some View {
        Text(self.statusText)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(self.statusPillTint.opacity(0.18))
            .foregroundStyle(self.statusPillTint)
            .clipShape(Capsule())
    }

    private var statusText: String {
        if self.snapshot.isEmpty { return "No data" }
        if self.snapshot.isSampleData { return "Sample" }
        if self.isBridgeLive, !self.snapshot.isStale { return "Live" }
        if self.snapshot.isStale { return "Stale" }
        if self.snapshot.hasStaleProvider(reference: Date()) { return "Partial" }
        return self.isBridgeLive ? "Live" : "Cached"
    }

    private var statusPillTint: Color {
        if self.statusText == "Stale" || self.snapshot.isSampleData || self.snapshot.isEmpty {
            return .orange
        }
        if self.statusText == "Partial" {
            return .yellow
        }
        return self.isBridgeLive ? .green : .secondary
    }

    private var providerGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: self.providerCardMinimumWidth), spacing: 12)], spacing: 12) {
            ForEach(self.snapshot.providers) { provider in
                ProviderCard(provider: provider, range: self.selectedRange, generatedAt: self.snapshot.generatedAt)
            }
        }
    }

    private var providerCardMinimumWidth: CGFloat {
        self.dynamicTypeSize.isAccessibilitySize ? 560 : 310
    }

    @ViewBuilder
    private var liveActivityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live Activity")
                .font(.headline)
            Text(self.activityStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Start") {
                    self.startLiveActivity()
                }
                .buttonStyle(.borderedProminent)
                Button("Update") {
                    self.updateLiveActivity()
                }
                .buttonStyle(.bordered)
                Button("End") {
                    self.endLiveActivity()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func handleLaunchAutomationIfNeeded() {
        #if DEBUG
        guard !self.didHandleLaunchAutomation,
              Self.isEnabled(ProcessInfo.processInfo.environment[Self.autostartLiveActivityEnvironmentKey])
        else {
            return
        }
        self.didHandleLaunchAutomation = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            self.startLiveActivity()
        }
        #endif
    }

    #if DEBUG
    private static func isEnabled(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        default:
            return false
        }
    }
    #endif

    private func startLiveActivity() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else {
            self.activityStatus = "Requires iOS 16.2 or later"
            return
        }
        Task {
            self.model.refresh()
            do {
                let state = AgentMeterActivityAttributes.ContentState(
                    snapshot: AgentMeterActivitySnapshot(snapshot: self.snapshot),
                    updatedAt: Date())
                for activity in Activity<AgentMeterActivityAttributes>.activities {
                    await activity.end(
                        ActivityContent(state: state, staleDate: Date()),
                        dismissalPolicy: .immediate)
                }
                _ = try Activity<AgentMeterActivityAttributes>.request(
                    attributes: AgentMeterActivityAttributes(title: "AgentMeter"),
                    content: ActivityContent(state: state, staleDate: self.snapshot.generatedAt.addingTimeInterval(15 * 60)),
                    pushType: nil)
                self.activityStatus = "Running locally (1 activity)"
            } catch {
                self.activityStatus = "Start failed: \(error.localizedDescription)"
            }
        }
        #else
        self.activityStatus = "ActivityKit unavailable"
        #endif
    }

    private func updateLiveActivity() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else {
            self.activityStatus = "Requires iOS 16.2 or later"
            return
        }
        Task {
            self.model.refresh()
            let state = AgentMeterActivityAttributes.ContentState(
                snapshot: AgentMeterActivitySnapshot(snapshot: self.snapshot),
                updatedAt: Date())
            let activities = Activity<AgentMeterActivityAttributes>.activities
            guard !activities.isEmpty else {
                self.activityStatus = "No running activity"
                return
            }
            for activity in activities {
                await activity.update(ActivityContent(
                    state: state,
                    staleDate: self.snapshot.generatedAt.addingTimeInterval(15 * 60)))
            }
            self.activityStatus = "Updated \(Self.activityCountText(activities.count))"
        }
        #else
        self.activityStatus = "ActivityKit unavailable"
        #endif
    }

    private func updateLiveActivitySilently() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else { return }
        Task {
            let activities = Activity<AgentMeterActivityAttributes>.activities
            guard !activities.isEmpty else { return }
            let state = AgentMeterActivityAttributes.ContentState(
                snapshot: AgentMeterActivitySnapshot(snapshot: self.snapshot),
                updatedAt: Date())
            for activity in activities {
                await activity.update(ActivityContent(
                    state: state,
                    staleDate: self.snapshot.generatedAt.addingTimeInterval(15 * 60)))
            }
            self.activityStatus = "Updated \(Self.activityCountText(activities.count))"
        }
        #endif
    }

    private func endLiveActivity() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *) else {
            self.activityStatus = "Requires iOS 16.2 or later"
            return
        }
        Task {
            let state = AgentMeterActivityAttributes.ContentState(
                snapshot: AgentMeterActivitySnapshot(snapshot: self.snapshot),
                updatedAt: Date())
            let activities = Activity<AgentMeterActivityAttributes>.activities
            guard !activities.isEmpty else {
                self.activityStatus = "No running activity"
                return
            }
            for activity in activities {
                await activity.end(ActivityContent(state: state, staleDate: Date()), dismissalPolicy: .immediate)
            }
            self.activityStatus = "Ended \(Self.activityCountText(activities.count))"
        }
        #else
        self.activityStatus = "ActivityKit unavailable"
        #endif
    }

    private static func activityCountText(_ count: Int) -> String {
        count == 1 ? "1 activity" : "\(count) activities"
    }
}

private struct UsageRangePicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metric window")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Metric window", selection: self.$selection) {
                ForEach(AgentMeterUsageRange.allCases) { range in
                    Text(range.shortTitle).tag(range.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct InsightsGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let insights: AgentMeterPhoneInsights
    let range: AgentMeterUsageRange
    let generatedAt: Date

    private var totals: AgentMeterRangeTotals {
        self.insights.totals(for: self.range)
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: self.tileMinimumWidth), spacing: 10)], spacing: 10) {
            InsightTile(
                title: "\(self.range.shortTitle) tokens",
                value: AgentMeterFormat.compactNumber(self.totals.tokens),
                systemImage: "number")
            InsightTile(
                title: "\(self.range.shortTitle) cost",
                value: AgentMeterFormat.money(
                    self.totals.costUSD,
                    currencyCode: self.insights.currencyCode),
                systemImage: "creditcard")
            InsightTile(
                title: "Peak",
                value: self.peakText,
                systemImage: "gauge.with.dots.needle.67percent")
            InsightTile(
                title: "Next reset",
                value: self.resetText,
                systemImage: "clock.arrow.circlepath")
        }
    }

    private var tileMinimumWidth: CGFloat {
        self.dynamicTypeSize.isAccessibilitySize ? 220 : 145
    }

    private var peakText: String {
        guard let usage = self.totals.peakUsage else { return "NA" }
        return "\(usage.displayName) \(AgentMeterFormat.percent(usage.usedPercent))"
    }

    private var resetText: String {
        guard let reset = self.insights.nextReset else { return "NA" }
        let text = AgentMeterFormat.resetMetricText(
            resetsAt: reset.resetsAt,
            resetDescription: reset.resetDescription,
            from: self.generatedAt)
        return [reset.displayName, text].compactMap(\.self).joined(separator: " ")
    }
}

private struct InsightTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: self.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24, alignment: .leading)
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            Text(self.value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ProviderCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var wordmarkHeight: CGFloat = 18
    let provider: AgentMeterPhoneProvider
    let range: AgentMeterUsageRange
    let generatedAt: Date

    private var rangeUsage: AgentMeterRangeUsage {
        self.provider.usage(for: self.range, generatedAt: self.generatedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AgentMeterProviderLockup(
                    providerID: self.provider.id,
                    fallbackTitle: self.provider.displayName,
                    iconSize: 22,
                    wordmarkHeight: self.wordmarkHeight)
                Spacer()
                Text(self.displayStatus.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(self.displayStatus == .ok ? .green : .orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            ForEach(self.provider.windows) { window in
                UsageWindowRow(window: window, generatedAt: self.generatedAt)
            }
            SelectedRangePanel(provider: self.provider, range: self.range, usage: self.rangeUsage, generatedAt: self.generatedAt)
            DailyUsageChart(provider: self.provider)
            Divider()
            LazyVGrid(columns: self.valueTileColumns, alignment: .leading, spacing: 10) {
                ValueTile(title: "\(self.range.shortTitle) cost", value: AgentMeterFormat.money(
                    self.rangeUsage.costUSD,
                    currencyCode: self.provider.tokenUsage?.currencyCode ?? "USD"))
                ValueTile(title: "\(self.range.shortTitle) tokens", value: AgentMeterFormat.compactNumber(self.rangeUsage.tokens))
                ValueTile(title: "Source", value: self.provider.source.confidence.rawValue)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var valueTileColumns: [GridItem] {
        let minimumWidth: CGFloat = self.dynamicTypeSize.isAccessibilitySize ? 170 : 88
        return [GridItem(.adaptive(minimum: minimumWidth), spacing: 10)]
    }

    private var displayStatus: AgentMeterPhoneProviderStatus {
        self.provider.displayStatus(reference: Date())
    }
}

private struct UsageWindowRow: View {
    let window: AgentMeterPhoneUsageWindow
    let generatedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(self.window.title)
                Spacer()
                Text("\(AgentMeterFormat.percent(self.window.usedPercent)) used")
                    .foregroundStyle(.secondary)
            }
            PaceProjectionBar(window: self.window, generatedAt: self.generatedAt)
            if let resetText = AgentMeterFormat.resetText(for: self.window, from: self.generatedAt) {
                Text(resetText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let projection = self.window.paceProjection(generatedAt: self.generatedAt) {
                Text(projection.label)
                    .font(.caption)
                    .foregroundStyle(projection.emptiesBeforeReset ? .orange : .secondary)
            }
        }
        .font(.subheadline)
    }
}

private struct SelectedRangePanel: View {
    let provider: AgentMeterPhoneProvider
    let range: AgentMeterUsageRange
    let usage: AgentMeterRangeUsage
    let generatedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(self.range.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(AgentMeterFormat.compactNumber(self.usage.tokens)) tokens")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let window = self.usage.window {
                PaceProjectionBar(window: window, generatedAt: self.generatedAt)
                if let projection = window.paceProjection(generatedAt: self.generatedAt) {
                    Text(projection.label)
                        .font(.caption2)
                        .foregroundStyle(projection.emptiesBeforeReset ? .orange : .secondary)
                }
            } else {
                Text("No quota window in the current snapshot")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PaceProjectionBar: View {
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
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(4, width * self.usedFraction))
                if let projection = self.window.paceProjection(generatedAt: self.generatedAt) {
                    Rectangle()
                        .fill(projection.emptiesBeforeReset ? Color.orange : Color.secondary)
                        .frame(width: 2)
                        .offset(x: min(max(0, width * projection.markerPercent), max(0, width - 2)))
                }
            }
        }
        .frame(height: 8)
    }
}

private struct DailyUsageChart: View {
    let provider: AgentMeterPhoneProvider

    private var model: AgentMeterDailyUsageChartModel {
        AgentMeterDailyUsageChartModel(dailyUsage: self.provider.dailyUsage)
    }

    var body: some View {
        if self.model.hasData {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Daily tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(AgentMeterFormat.compactNumber(self.model.totalTokens))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    let chartHeight = max(1, proxy.size.height - 16)
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(self.model.points) { point in
                            VStack(spacing: 4) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.25 + (0.6 * point.normalizedHeight)))
                                    .frame(height: max(3, chartHeight * point.normalizedHeight))
                                Text(point.shortLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .frame(width: 22)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 64)
            }
        }
    }
}

private struct ValueTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            Text(self.value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
