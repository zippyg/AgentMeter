import CodexBarCore
import Foundation
import Testing
@testable import AgentMeter

@MainActor
struct AgentMeterLaunchModeTests {
    @Test
    func `safe launch disables provider probes and secret migration`() {
        let mode = AgentMeterLaunchMode(
            environment: [
                AgentMeterLaunchMode.safeLaunchKey: "1",
            ],
            isLocalBuild: false)

        #expect(mode.safeLaunchEnabled)
        #expect(mode.disablesProviderProbes)
        #expect(mode.disablesSecretMigration)
        #expect(mode.disablesKeychainAccess)
        #expect(mode.startupBehavior == .testing)
        #expect(!mode.migratesSecretsOnLaunch)
        #expect(!mode.requestsNotificationAuthorizationOnStartup)
        #expect(mode.usesStatusItemAutosave)
    }

    @Test
    func `normal launch preserves default startup behavior without secret migration`() {
        let mode = AgentMeterLaunchMode(environment: [:], isLocalBuild: false)

        #expect(!mode.safeLaunchEnabled)
        #expect(!mode.disablesProviderProbes)
        #expect(!mode.disablesSecretMigration)
        #expect(!mode.disablesKeychainAccess)
        #expect(mode.startupBehavior == .automatic)
        #expect(!mode.migratesSecretsOnLaunch)
        #expect(mode.requestsNotificationAuthorizationOnStartup)
        #expect(mode.usesStatusItemAutosave)
    }

    @Test
    func `secret migration requires explicit opt in`() {
        let mode = AgentMeterLaunchMode(environment: [
            AgentMeterLaunchMode.enableSecretMigrationKey: "1",
        ])

        #expect(mode.migratesSecretsOnLaunch)
    }

    @Test
    func `local build keeps independent status item autosave by default`() {
        let mode = AgentMeterLaunchMode(environment: [:], isLocalBuild: true)

        #expect(mode.usesStatusItemAutosave)
    }

    @Test
    func `status item autosave explicit enable preserves local default`() {
        let mode = AgentMeterLaunchMode(
            environment: [
                AgentMeterLaunchMode.enableStatusItemAutosaveKey: "1",
            ],
            isLocalBuild: true)

        #expect(mode.usesStatusItemAutosave)
    }

    @Test
    func `status item autosave can be explicitly disabled`() {
        let mode = AgentMeterLaunchMode(
            environment: [
                AgentMeterLaunchMode.disableStatusItemAutosaveKey: "1",
            ],
            isLocalBuild: true)

        #expect(!mode.usesStatusItemAutosave)
    }

    @Test
    func `settings store can load config without migrating inline secrets`() throws {
        let suite = "AgentMeterLaunchModeTests-no-secret-migration"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(providers: [
            ProviderConfig(id: .codex, cookieHeader: "session=test-secret"),
        ]))

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            migrateSecretsOnLaunch: false)

        let codex = try #require(settings.configSnapshot.providerConfig(for: .codex))
        #expect(codex.inlineCookieHeader == "session=test-secret")
        #expect(codex.credentialReferences == nil)
    }
}
