import CodexBarCore
import Foundation
import Testing
@testable import AgentMeter

@MainActor
struct UsageStoreWidgetSnapshotTests {
    @Test
    func `widget snapshot includes antigravity grouped usage rows`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-grouped"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))

        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-grouped-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(entry.usageRows?.map(\.id) == ["primary", "secondary"])
        #expect(entry.usageRows?.map(\.title) == ["Gemini", "Claude + GPT"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [90, 80])
    }

    @Test
    func `widget snapshot includes antigravity quota summary rows`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-quota-summary"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 27, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Session",
                    window: RateWindow(usedPercent: 9, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Weekly",
                    window: RateWindow(usedPercent: 18, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude + GPT Session",
                    window: RateWindow(usedPercent: 27, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude + GPT Weekly",
                    window: RateWindow(usedPercent: 36, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))

        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-quota-summary-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(entry.usageRows?.map(\.title) == [
            "Gemini Session",
            "Gemini Weekly",
            "Claude + GPT Session",
            "Claude + GPT Weekly",
        ])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [91, 82, 73, 64])
    }

    @Test
    func `widget snapshot labels antigravity compact fallback with model name`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-compact-fallback"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = try AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Experimental Model",
                    modelId: "MODEL_PLACEHOLDER_NEW",
                    remainingFraction: 0.36,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)
            .toUsageSnapshot()
        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-compact-fallback-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(entry.primary == nil)
        #expect(entry.usageRows?.map(\.id) == ["antigravity-compact-fallback-MODEL_PLACEHOLDER_NEW"])
        #expect(entry.usageRows?.map(\.title) == ["Experimental Model"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [36])
    }

    @Test
    func `widget snapshot excludes mimo balance from quota rows`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-mimo-balance"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            updatedAt: Date())
            .toUsageSnapshot()
        store._setSnapshotForTesting(snapshot, provider: .mimo)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "mimo-balance-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .mimo })
        #expect(entry.primary == nil)
        #expect(entry.secondary == nil)
        #expect(entry.usageRows?.isEmpty == true)
    }

    @Test
    func `widget persistence also emits agentmeter summary`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-agentmeter-summary"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: "resets in 1h"),
                secondary: RateWindow(
                    usedPercent: 10,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(86400),
                    resetDescription: "resets tomorrow"),
                tertiary: nil,
                updatedAt: now),
            provider: .codex)

        var widgetSnapshots: [WidgetSnapshot] = []
        var agentMeterSnapshots: [AgentMeterSnapshot] = []
        var phoneSnapshots: [AgentMeterPhoneSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        store._test_agentMeterSnapshotSaveOverride = { agentMeterSnapshots.append($0) }
        store._test_agentMeterPhoneSnapshotSaveOverride = { phoneSnapshots.append($0) }
        defer {
            store._test_widgetSnapshotSaveOverride = nil
            store._test_agentMeterSnapshotSaveOverride = nil
            store._test_agentMeterPhoneSnapshotSaveOverride = nil
        }

        store.persistWidgetSnapshot(reason: "agentmeter-summary-test")
        await store.widgetSnapshotPersistTask?.value

        #expect(widgetSnapshots.count == 1)
        let provider = try #require(agentMeterSnapshots.last?.providers.first { $0.id == "codex" })
        #expect(provider.displayName == "Codex")
        #expect(provider.windows.map(\.id) == ["session", "weekly"])
        #expect(provider.source.confidence == .derived)
        #expect(provider.windows.first?.remainingPercent == 60)

        let phoneProvider = try #require(phoneSnapshots.last?.providers.first { $0.id == "codex" })
        #expect(phoneProvider.displayName == "Codex")
        #expect(phoneProvider.windows.map(\.id) == ["session", "weekly"])
        #expect(phoneProvider.windows.first?.usedPercent == 40)
        #expect(phoneProvider.source.confidence == .derived)
    }

    @Test
    func `agentmeter summary persistence preserves previous providers during transient empty refresh`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-agentmeter-empty-repair"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        try settings.setProviderEnabled(
            provider: .codex,
            metadata: #require(ProviderDescriptorRegistry.metadata[.codex]),
            enabled: true)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let previousUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = AgentMeterSnapshot(
            snapshotSequence: 12,
            generatedAt: previousUpdatedAt,
            providers: [
                AgentMeterProviderSnapshot(
                    id: "codex",
                    displayName: "Codex",
                    windows: [
                        AgentMeterUsageWindow(
                            id: "session",
                            title: "Session",
                            usedPercent: 32,
                            remainingPercent: 68,
                            resetsAt: nil,
                            resetDescription: nil,
                            windowMinutes: 300),
                    ],
                    source: AgentMeterSourceDescriptor(confidence: .local, label: "fixture"),
                    status: .ok,
                    updatedAt: previousUpdatedAt,
                    staleAfter: previousUpdatedAt.addingTimeInterval(900)),
            ])

        var agentMeterSnapshots: [AgentMeterSnapshot] = []
        var phoneSnapshots: [AgentMeterPhoneSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { _ in }
        store._test_agentMeterSnapshotLoadOverride = { previous }
        store._test_agentMeterSnapshotSaveOverride = { agentMeterSnapshots.append($0) }
        store._test_agentMeterPhoneSnapshotSaveOverride = { phoneSnapshots.append($0) }
        defer {
            store._test_widgetSnapshotSaveOverride = nil
            store._test_agentMeterSnapshotLoadOverride = nil
            store._test_agentMeterSnapshotSaveOverride = nil
            store._test_agentMeterPhoneSnapshotSaveOverride = nil
        }

        store.persistWidgetSnapshot(reason: "agentmeter-empty-repair-test")
        await store.widgetSnapshotPersistTask?.value

        let provider = try #require(agentMeterSnapshots.last?.providers.first)
        #expect(agentMeterSnapshots.last?.providers.map(\.id) == ["codex"])
        #expect(provider.status == .stale)
        #expect(provider.windows.first?.usedPercent == 32)
        #expect(provider.staleAfter == agentMeterSnapshots.last?.generatedAt)
        #expect(provider.nextRefreshAt != nil)
        #expect(provider.lastError?.contains("No fresh provider snapshots") == true)

        let phoneProvider = try #require(phoneSnapshots.last?.providers.first)
        #expect(phoneSnapshots.last?.providers.map(\.id) == ["codex"])
        #expect(phoneProvider.status == .stale)
        #expect(phoneProvider.windows.first?.usedPercent == 32)
    }
}
