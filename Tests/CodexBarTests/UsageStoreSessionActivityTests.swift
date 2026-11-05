import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import AgentMeter

@MainActor
struct UsageStoreSessionActivityTests {
    @Test
    func `session monitor serializes rapid workspace notifications`() {
        let center = NotificationCenter()
        let state = ActiveSessionState(false)
        let monitor = SessionActivityMonitor(notificationCenter: center, activeStateProvider: { state.active })
        let store = Self.makeStore(sessionActivityMonitor: monitor)
        store.terminateTTYProcessesForSessionQuiesce = {}
        defer { TTYCommandRunner.resumeActiveProcessesAfterSessionActivation() }

        #expect(store.sessionIsActive == false)

        state.active = true
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        #expect(store.sessionIsActive == true)

        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        #expect(store.sessionIsActive == false)

        state.active = true
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        state.active = false
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        #expect(store.sessionIsActive == false)
    }

    @Test
    func `inactive session blocks provider refresh work`() async {
        let store = Self.makeStore()
        var calls: [UsageProvider] = []
        store._test_providerRefreshOverride = { provider in
            calls.append(provider)
        }
        store.sessionIsActive = false

        await store.runRefresh(startupConnectivityRetryAttempt: nil)

        #expect(calls.isEmpty)
        #expect(store.isRefreshing == false)
    }

    private static func makeStore(sessionActivityMonitor: SessionActivityMonitor? = nil) -> UsageStore {
        let suite = "UsageStoreSessionActivityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.costUsageEnabled = false
        settings.openAIWebAccessEnabled = false
        settings.codexCookieSource = .off
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        return UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            sessionActivityMonitor: sessionActivityMonitor,
            environmentBase: [:])
    }
}

@MainActor
private final class ActiveSessionState {
    var active: Bool

    init(_ active: Bool) {
        self.active = active
    }
}
