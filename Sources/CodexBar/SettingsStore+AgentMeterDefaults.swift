import CodexBarCore
import Foundation

extension SettingsStore {
    private static let agentMeterDefaultsAppliedKey = "agentMeterDefaultsAppliedV1"
    private static let agentMeterPrimaryProviderDefaultsAppliedKey = "agentMeterPrimaryProviderDefaultsAppliedV1"
    private static let agentMeterLaunchAtLoginDefaultAppliedKey = "agentMeterLaunchAtLoginDefaultAppliedV1"
    private static let launchAtLoginKey = "launchAtLogin"

    func applyAgentMeterPersonalDefaultsIfNeeded() {
        if !self.userDefaults.bool(forKey: Self.agentMeterDefaultsAppliedKey) {
            self.applyAgentMeterViewDefaults(resetAuthSources: true)
            self.userDefaults.set(true, forKey: Self.agentMeterDefaultsAppliedKey)
        }

        self.applyAgentMeterLaunchAtLoginDefaultIfNeeded()
        self.applyAgentMeterPrimaryProviderDefaultsIfNeeded()
    }

    func restoreAgentMeterViewDefaults() {
        self.applyAgentMeterViewDefaults(resetAuthSources: false)
        self.userDefaults.set(true, forKey: Self.agentMeterDefaultsAppliedKey)
        self.userDefaults.set(true, forKey: Self.agentMeterPrimaryProviderDefaultsAppliedKey)
    }

    private func applyAgentMeterPrimaryProviderDefaultsIfNeeded() {
        guard !self.userDefaults.bool(forKey: Self.agentMeterPrimaryProviderDefaultsAppliedKey) else { return }

        self.applyAgentMeterPrimaryProviderDefaults()
        self.userDefaults.set(true, forKey: Self.agentMeterPrimaryProviderDefaultsAppliedKey)
    }

    private func applyAgentMeterLaunchAtLoginDefaultIfNeeded() {
        guard !self.userDefaults.bool(forKey: Self.agentMeterLaunchAtLoginDefaultAppliedKey) else { return }

        if self.userDefaults.object(forKey: Self.launchAtLoginKey) == nil {
            self.launchAtLogin = true
        }
        self.userDefaults.set(true, forKey: Self.agentMeterLaunchAtLoginDefaultAppliedKey)
    }

    private func applyAgentMeterViewDefaults(resetAuthSources: Bool) {
        self.usageBarsShowUsed = true
        self.showOptionalCreditsAndExtraUsage = false
        self.menuBarShowsBrandIconWithPercent = true
        self.menuBarShowsHighestUsage = true
        self.switcherShowsIcons = true
        self.mergedMenuLastSelectedWasOverview = true
        self.mergedOverviewSelectedProviders = [.codex, .claude]
        self.selectedMenuProvider = .codex
        self.applyAgentMeterPrimaryProviderDefaults()

        if resetAuthSources {
            self.openAIWebAccessEnabled = false
            self.claudeWebExtrasEnabled = false
            self.updateProviderConfig(provider: .codex) { entry in
                entry.cookieSource = .off
            }
            self.updateProviderConfig(provider: .claude) { entry in
                entry.cookieSource = .off
            }
        }
    }

    private func applyAgentMeterPrimaryProviderDefaults() {
        self.updateProviderConfig(provider: .codex) { entry in
            entry.enabled = true
        }
        self.updateProviderConfig(provider: .claude) { entry in
            entry.enabled = true
        }
        self.updateProviderConfig(provider: .gemini) { entry in
            entry.enabled = false
        }
        self.updateProviderConfig(provider: .antigravity) { entry in
            entry.enabled = false
        }

        let selectedOverview = Set(self.mergedOverviewSelectedProviders)
        if selectedOverview.isEmpty ||
            selectedOverview.contains(.gemini) ||
            selectedOverview.contains(.antigravity)
        {
            self.mergedOverviewSelectedProviders = [.codex, .claude]
        }
        if self.selectedMenuProvider == .gemini || self.selectedMenuProvider == .antigravity {
            self.selectedMenuProvider = .codex
        }
    }
}
