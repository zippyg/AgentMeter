import CodexBarCore
import Foundation
import Testing
@testable import AgentMeter

@MainActor
struct SettingsStoreAdditionalTests {
    @Test
    @MainActor
    func `antigravity two pool migration preserves released metric meaning`() {
        let primaryDefaults = UserDefaults(suiteName: #function + ".primary")!
        primaryDefaults.removePersistentDomain(forName: #function + ".primary")
        primaryDefaults.set(
            [UsageProvider.antigravity.rawValue: MenuBarMetricPreference.primary.rawValue],
            forKey: "menuBarMetricPreferences")

        let primarySettings = SettingsStore(userDefaults: primaryDefaults)

        #expect(primarySettings.menuBarMetricPreference(for: .antigravity) == .secondary)
        #expect(primaryDefaults.bool(forKey: "antigravityTwoPoolMetricPreferenceMigrated"))

        let secondaryDefaults = UserDefaults(suiteName: #function + ".secondary")!
        secondaryDefaults.removePersistentDomain(forName: #function + ".secondary")
        secondaryDefaults.set(
            [UsageProvider.antigravity.rawValue: MenuBarMetricPreference.secondary.rawValue],
            forKey: "menuBarMetricPreferences")

        let secondarySettings = SettingsStore(userDefaults: secondaryDefaults)

        #expect(secondarySettings.menuBarMetricPreference(for: .antigravity) == .primary)

        let reloadedSettings = SettingsStore(userDefaults: secondaryDefaults)
        #expect(reloadedSettings.menuBarMetricPreference(for: .antigravity) == .primary)

        let tertiaryDefaults = UserDefaults(suiteName: #function + ".tertiary")!
        tertiaryDefaults.removePersistentDomain(forName: #function + ".tertiary")
        tertiaryDefaults.set(
            [UsageProvider.antigravity.rawValue: MenuBarMetricPreference.tertiary.rawValue],
            forKey: "menuBarMetricPreferences")

        let tertiarySettings = SettingsStore(userDefaults: tertiaryDefaults)

        #expect(tertiarySettings.menuBarMetricPreference(for: .antigravity) == .primary)

        let migratedDefaults = UserDefaults(suiteName: #function + ".migrated")!
        migratedDefaults.removePersistentDomain(forName: #function + ".migrated")
        migratedDefaults.set(
            [UsageProvider.antigravity.rawValue: MenuBarMetricPreference.primary.rawValue],
            forKey: "menuBarMetricPreferences")
        migratedDefaults.set(true, forKey: "antigravityTwoPoolMetricPreferenceMigrated")

        let migratedSettings = SettingsStore(userDefaults: migratedDefaults)

        #expect(migratedSettings.menuBarMetricPreference(for: .antigravity) == .primary)
    }

    @Test
    func `menu bar metric preference handles zai and average`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-metric")

        #expect(settings.menuBarMetricPreference(for: .zai) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .automatic)

        settings.setMenuBarMetricPreference(.secondary, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .secondary)

        settings.setMenuBarMetricPreference(.tertiary, for: .zai)
        #expect(settings.menuBarMetricPreference(for: .zai) == .tertiary)
        #expect(settings.menuBarMetricPreference(for: .zai, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsTertiary(for: .zai, snapshot: nil) == false)

        settings.setMenuBarMetricPreference(.average, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .gemini)
        #expect(settings.menuBarMetricPreference(for: .gemini) == .average)

        settings.setMenuBarMetricPreference(.tertiary, for: .codex)
        #expect(settings.menuBarMetricPreference(for: .codex) == .automatic)

        settings.setMenuBarMetricPreference(.tertiary, for: .cursor)
        #expect(settings.menuBarMetricPreference(for: .cursor) == .tertiary)
        #expect(settings.menuBarMetricPreference(for: .cursor, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsTertiary(for: .cursor, snapshot: nil) == false)

        settings.setMenuBarMetricPreference(.extraUsage, for: .cursor)
        #expect(settings.menuBarMetricPreference(for: .cursor) == .extraUsage)
        #expect(settings.menuBarMetricPreference(for: .cursor, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsExtraUsage(for: .cursor, snapshot: nil) == false)

        settings.setMenuBarMetricPreference(.extraUsage, for: .claude)
        #expect(settings.menuBarMetricPreference(for: .claude) == .extraUsage)
        #expect(settings.menuBarMetricPreference(for: .claude, snapshot: nil) == .automatic)
        #expect(settings.menuBarMetricSupportsExtraUsage(for: .claude, snapshot: nil) == false)

        settings.setMenuBarMetricPreference(.tertiary, for: .perplexity)
        #expect(settings.menuBarMetricPreference(for: .perplexity) == .tertiary)
        #expect(settings.menuBarMetricPreference(for: .perplexity, snapshot: nil) == .tertiary)
        #expect(settings.menuBarMetricSupportsTertiary(for: .perplexity, snapshot: nil))

        settings.setMenuBarMetricPreference(.tertiary, for: .gemini)
        #expect(settings.menuBarMetricPreference(for: .gemini) == .automatic)
    }

    @Test
    func `menu bar metric preference restricts open router to automatic or primary`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-openrouter-metric")

        settings.setMenuBarMetricPreference(.secondary, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .automatic)

        settings.setMenuBarMetricPreference(.average, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .automatic)

        settings.setMenuBarMetricPreference(.primary, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .primary)

        settings.setMenuBarMetricPreference(.tertiary, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .automatic)

        settings.setMenuBarMetricPreference(.extraUsage, for: .openrouter)
        #expect(settings.menuBarMetricPreference(for: .openrouter) == .automatic)
    }

    @Test
    func `menu bar metric preference restricts text only balance providers to automatic`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-text-only-metric")

        for provider in [UsageProvider.deepseek, .mistral, .kimik2] {
            settings.setMenuBarMetricPreference(.primary, for: provider)
            #expect(settings.menuBarMetricPreference(for: provider) == .automatic)

            settings.setMenuBarMetricPreference(.secondary, for: provider)
            #expect(settings.menuBarMetricPreference(for: provider) == .automatic)
        }
    }

    @Test
    func `minimax auth mode uses stored values`() throws {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-minimax")
        settings.minimaxAPIToken = "api-token-fixture"
        settings.minimaxCookieHeader = "cookie=value"

        #expect(settings.minimaxAuthMode(environment: [:]) == .apiToken)
        let configured = try #require(settings.configSnapshot.providerConfig(for: .minimax))
        #expect(configured.credentialReferences?.apiKey != nil)
        #expect(configured.credentialReferences?.cookieHeader != nil)

        settings.minimaxAPIToken = ""
        let cleared = try #require(settings.configSnapshot.providerConfig(for: .minimax))
        #expect(cleared.credentialReferences?.apiKey == nil)
        #expect(cleared.credentialReferences?.cookieHeader != nil)
        #expect(settings.minimaxAPIToken.isEmpty)
        #expect(settings.minimaxAuthMode(environment: [:]) == .cookie)
    }

    @Test
    func `token accounts set manual cookie source when required`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-token-accounts")

        settings.addTokenAccount(provider: .claude, label: "Primary", token: "token-1")

        #expect(settings.tokenAccounts(for: .claude).count == 1)
        #expect(settings.claudeCookieSource == .manual)
    }

    @Test
    func `ollama token accounts set manual cookie source when required`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-ollama-token-accounts")

        settings.addTokenAccount(provider: .ollama, label: "Primary", token: "session=token-1")

        #expect(settings.tokenAccounts(for: .ollama).count == 1)
        #expect(settings.ollamaCookieSource == .manual)
    }

    @Test
    func `agentmeter defaults favor used bars brand icon and primary providers`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-agentmeter-defaults")

        #expect(settings.usageBarsShowUsed)
        #expect(!settings.showOptionalCreditsAndExtraUsage)
        #expect(settings.menuBarShowsBrandIconWithPercent)
        #expect(settings.menuBarShowsHighestUsage)

        settings.applyAgentMeterPersonalDefaultsIfNeeded()

        let enabled = settings.enabledProvidersOrdered(metadataByProvider: ProviderDescriptorRegistry.metadata)
        #expect(enabled.contains(.codex))
        #expect(enabled.contains(.claude))
        #expect(!enabled.contains(.gemini))
        #expect(!enabled.contains(.antigravity))
        #expect(!settings.openAIWebAccessEnabled)
        #expect(!settings.claudeWebExtrasEnabled)
        #expect(settings.codexCookieSource == .off)
        #expect(settings.claudeCookieSource == .off)
        #expect(settings.mergedOverviewSelectedProviders == [.codex, .claude])
        #expect(settings.mergedMenuLastSelectedWasOverview)
        #expect(settings.launchAtLogin)
        #expect(settings.userDefaults.bool(forKey: "agentMeterLaunchAtLoginDefaultAppliedV1"))
    }

    @Test
    func `agentmeter launch at login migration respects an existing explicit preference`() {
        let settings = Self.makeSettingsStore(suite: "SettingsStoreAdditionalTests-agentmeter-launch-existing")
        settings.userDefaults.set(false, forKey: "launchAtLogin")

        settings.applyAgentMeterPersonalDefaultsIfNeeded()

        #expect(!settings.launchAtLogin)
        #expect(settings.userDefaults.bool(forKey: "agentMeterLaunchAtLoginDefaultAppliedV1"))
    }

    @Test
    func `agentmeter primary provider migration disables google providers once`() throws {
        let settings = Self.makeSettingsStore(
            suite: "SettingsStoreAdditionalTests-agentmeter-primary-migration")
        let geminiMeta = try #require(ProviderDescriptorRegistry.metadata[.gemini])
        let antigravityMeta = try #require(ProviderDescriptorRegistry.metadata[.antigravity])

        settings.userDefaults.set(true, forKey: "agentMeterDefaultsAppliedV1")
        settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: true)
        settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        settings.mergedOverviewSelectedProviders = [.gemini, .antigravity]
        settings.selectedMenuProvider = .gemini

        settings.applyAgentMeterPersonalDefaultsIfNeeded()

        let enabled = settings.enabledProvidersOrdered(metadataByProvider: ProviderDescriptorRegistry.metadata)
        #expect(enabled.contains(.codex))
        #expect(enabled.contains(.claude))
        #expect(!enabled.contains(.gemini))
        #expect(!enabled.contains(.antigravity))
        #expect(settings.mergedOverviewSelectedProviders == [.codex, .claude])
        #expect(settings.selectedMenuProvider == .codex)
    }

    @Test
    func `agentmeter primary provider migration does not override later manual toggles`() throws {
        let settings = Self.makeSettingsStore(
            suite: "SettingsStoreAdditionalTests-agentmeter-manual-provider-toggle")
        let geminiMeta = try #require(ProviderDescriptorRegistry.metadata[.gemini])
        let antigravityMeta = try #require(ProviderDescriptorRegistry.metadata[.antigravity])

        settings.userDefaults.set(true, forKey: "agentMeterDefaultsAppliedV1")
        settings.userDefaults.set(true, forKey: "agentMeterPrimaryProviderDefaultsAppliedV1")
        settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: true)
        settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)
        settings.mergedOverviewSelectedProviders = [.gemini, .antigravity]
        settings.selectedMenuProvider = .antigravity

        settings.applyAgentMeterPersonalDefaultsIfNeeded()

        let enabled = settings.enabledProvidersOrdered(metadataByProvider: ProviderDescriptorRegistry.metadata)
        #expect(enabled.contains(.gemini))
        #expect(enabled.contains(.antigravity))
        #expect(settings.mergedOverviewSelectedProviders == [.gemini, .antigravity])
        #expect(settings.selectedMenuProvider == .antigravity)
    }

    @Test
    func `agentmeter manual restore resets view defaults without changing auth source choices`() throws {
        let settings = Self.makeSettingsStore(
            suite: "SettingsStoreAdditionalTests-agentmeter-manual-restore")
        let codexMeta = try #require(ProviderDescriptorRegistry.metadata[.codex])
        let claudeMeta = try #require(ProviderDescriptorRegistry.metadata[.claude])
        let geminiMeta = try #require(ProviderDescriptorRegistry.metadata[.gemini])
        let antigravityMeta = try #require(ProviderDescriptorRegistry.metadata[.antigravity])

        settings.usageBarsShowUsed = false
        settings.showOptionalCreditsAndExtraUsage = true
        settings.menuBarShowsBrandIconWithPercent = false
        settings.menuBarShowsHighestUsage = false
        settings.switcherShowsIcons = false
        settings.openAIWebAccessEnabled = true
        settings.claudeWebExtrasEnabled = true
        settings.mergedMenuLastSelectedWasOverview = false
        settings.mergedOverviewSelectedProviders = [.gemini, .antigravity]
        settings.selectedMenuProvider = .antigravity
        settings.codexCookieSource = .manual
        settings.claudeCookieSource = .manual
        settings.addTokenAccount(provider: .claude, label: "Primary", token: "token-fixture")
        settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: false)
        settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: false)
        settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: true)
        settings.setProviderEnabled(provider: .antigravity, metadata: antigravityMeta, enabled: true)

        settings.restoreAgentMeterViewDefaults()

        let enabled = settings.enabledProvidersOrdered(metadataByProvider: ProviderDescriptorRegistry.metadata)
        #expect(settings.usageBarsShowUsed)
        #expect(!settings.showOptionalCreditsAndExtraUsage)
        #expect(settings.menuBarShowsBrandIconWithPercent)
        #expect(settings.menuBarShowsHighestUsage)
        #expect(settings.switcherShowsIcons)
        #expect(settings.openAIWebAccessEnabled)
        #expect(settings.claudeWebExtrasEnabled)
        #expect(settings.mergedOverviewSelectedProviders == [.codex, .claude])
        #expect(settings.mergedMenuLastSelectedWasOverview)
        #expect(settings.selectedMenuProvider == .codex)
        #expect(enabled.contains(.codex))
        #expect(enabled.contains(.claude))
        #expect(!enabled.contains(.gemini))
        #expect(!enabled.contains(.antigravity))
        #expect(settings.codexCookieSource == .manual)
        #expect(settings.claudeCookieSource == .manual)
        #expect(settings.tokenAccounts(for: .claude).count == 1)
    }

    @Test
    func `detects token cost usage sources from filesystem`() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let jsonl = sessions.appendingPathComponent("usage.jsonl")
        try Data("{}".utf8).write(to: jsonl)
        defer { try? fm.removeItem(at: root) }

        let env = ["CODEX_HOME": root.path]

        #expect(SettingsStore.hasAnyTokenCostUsageSources(env: env, fileManager: fm))
    }

    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
    }
}
