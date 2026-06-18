import CodexBarCore
import SwiftUI

@MainActor
struct GlobalQuotaWarningSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { self.settings.quotaWarningWindowEnabled(.session) },
                    set: { self.settings.setQuotaWarningWindowEnabled(.session, enabled: $0) }))
                {
                    Text(L("quota_warning_session_capitalized"))
                        .font(.footnote)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { self.settings.quotaWarningWindowEnabled(.weekly) },
                    set: { self.settings.setQuotaWarningWindowEnabled(.weekly, enabled: $0) }))
                {
                    Text(L("quota_warning_weekly_capitalized"))
                        .font(.footnote)
                }
                .toggleStyle(.checkbox)
            }

            self.windowThresholdField(.session)
            self.windowThresholdField(.weekly)

            Toggle(isOn: self.$settings.quotaWarningSoundEnabled) {
                Text(L("quota_warning_sound"))
                    .font(.footnote)
            }
            .toggleStyle(.checkbox)

            Divider().padding(.vertical, 2)

            Toggle(isOn: self.$settings.rateLimitSoundEnabled) {
                Text("Play a sound when you hit a rate limit")
                    .font(.footnote)
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Text("Volume")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Slider(value: self.$settings.rateLimitSoundVolume, in: 0...1)
                    .frame(width: 140)
                    .disabled(!self.settings.rateLimitSoundEnabled)
                Button("Test") {
                    RateLimitSoundPlayer.shared.play(volume: self.settings.rateLimitSoundVolume)
                }
                .controlSize(.small)
            }
            .padding(.leading, 20)
        }
        .padding(.leading, 20)
    }

    private func windowThresholdField(_ window: QuotaWarningWindow) -> some View {
        QuotaWarningThresholdField(
            title: String(format: L("quota_warning_window_warn_at"), window.localizedCapitalizedDisplayName),
            subtitle: "Session and weekly windows warn at this used percentage unless a provider overrides them.",
            thresholds: { self.settings.quotaWarningThresholds(window) },
            setThresholds: { self.settings.setQuotaWarningThresholds(window, thresholds: $0) })
            .disabled(!self.settings.quotaWarningWindowEnabled(window))
            .opacity(!self.settings.quotaWarningWindowEnabled(window) ? 0.55 : 1)
    }
}

@MainActor
struct ProviderQuotaWarningSettingsView: View {
    let provider: UsageProvider
    @Bindable var settings: SettingsStore

    var body: some View {
        ProviderSettingsSection(title: L("quota_warnings_title")) {
            Text(L("quota_warning_provider_inherits"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            self.windowRow(.session)
            self.windowRow(.weekly)
        }
    }

    private func windowRow(_ window: QuotaWarningWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { self.settings.hasQuotaWarningOverride(provider: self.provider, window: window) },
                set: { isOn in
                    if isOn {
                        self.settings.setQuotaWarningOverride(
                            provider: self.provider,
                            window: window,
                            thresholds: self.settings.quotaWarningThresholds(window),
                            enabled: self.settings.quotaWarningWindowEnabled(window))
                    } else {
                        self.settings.setQuotaWarningOverride(
                            provider: self.provider,
                            window: window,
                            thresholds: nil,
                            enabled: nil)
                    }
                })) {
                    Text(String(format: L("quota_warning_customize_thresholds"), window.localizedDisplayName))
                        .font(.subheadline.weight(.semibold))
                }
                .toggleStyle(.checkbox)

            if self.settings.hasQuotaWarningOverride(provider: self.provider, window: window) {
                Toggle(isOn: Binding(
                    get: { self.settings.quotaWarningEnabled(provider: self.provider, window: window) },
                    set: {
                        self.settings.setQuotaWarningWindowEnabled(
                            provider: self.provider,
                            window: window,
                            enabled: $0)
                    })) {
                        Text(String(format: L("quota_warning_enable_warnings"), window.localizedDisplayName))
                            .font(.footnote)
                    }
                    .toggleStyle(.checkbox)
                        .padding(.leading, 20)

                if self.settings.quotaWarningEnabled(provider: self.provider, window: window) {
                    QuotaWarningThresholdField(
                        title: String(
                            format: L("quota_warning_window_warn_at"),
                            window.localizedCapitalizedDisplayName),
                        subtitle: "",
                        thresholds: {
                            self.settings.resolvedQuotaWarningThresholds(provider: self.provider, window: window)
                        },
                        setThresholds: {
                            self.settings.setQuotaWarningThresholds(
                                provider: self.provider,
                                window: window,
                                thresholds: $0)
                        })
                        .padding(.leading, 20)
                } else {
                    Text(L("quota_warning_off"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            } else {
                Text(String(format: L("quota_warning_inherited"), Self.thresholdText(
                    self.settings.quotaWarningThresholds(window),
                    enabled: self.settings.quotaWarningWindowEnabled(window))))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    private static func thresholdText(_ thresholds: [Int], enabled: Bool) -> String {
        guard enabled else { return L("quota_warning_off") }
        let text = QuotaWarningThresholds.active(thresholds).map { "\($0)%" }.joined(separator: ", ")
        return text.isEmpty ? L("quota_warning_depleted_only") : text
    }
}

extension QuotaWarningWindow {
    fileprivate var localizedDisplayName: String {
        switch self {
        case .session: L("quota_warning_session")
        case .weekly: L("quota_warning_weekly")
        }
    }

    fileprivate var localizedCapitalizedDisplayName: String {
        switch self {
        case .session: L("quota_warning_session_capitalized")
        case .weekly: L("quota_warning_weekly_capitalized")
        }
    }
}

@MainActor
private struct QuotaWarningThresholdField: View {
    let title: String
    let subtitle: String
    let thresholds: () -> [Int]
    let setThresholds: ([Int]) -> Void

    @State private var usedText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(self.title)
                    .font(.footnote.weight(.semibold))
                    .frame(width: 110, alignment: .leading)

                TextField("95", text: self.$usedText)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .frame(width: 56)
                    .onChange(of: self.usedText) { _, value in
                        self.usedText = Self.filteredIntegerText(value)
                    }
                    .onSubmit { self.commit() }

                Text("% used")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button(L("apply")) { self.commit() }
                    .controlSize(.small)
            }

            if !self.subtitle.isEmpty {
                Text(self.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { self.updateText(from: self.thresholds()) }
        .onChange(of: self.thresholds()) { _, value in
            self.updateText(from: value)
        }
    }

    private func commit() {
        guard let used = Self.integer(from: self.usedText), (1...99).contains(used) else {
            self.updateText(from: self.thresholds())
            return
        }
        let remaining = QuotaWarningThresholds.clamped(100 - used)
        self.setThresholds([remaining])
        self.updateText(from: [remaining])
    }

    private func updateText(from thresholds: [Int]) {
        // Show the most urgent active warning as a used-percent.
        if let remaining = QuotaWarningThresholds.active(thresholds).min() {
            self.usedText = String(100 - remaining)
        } else {
            self.usedText = ""
        }
    }

    private static func integer(from text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        return Int(text)
    }

    private static func filteredIntegerText(_ text: String) -> String {
        String(text.filter(\.isNumber).prefix(2))
    }
}
