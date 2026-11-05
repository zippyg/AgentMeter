import AppKit
import CodexBarCore
import Testing
@testable import AgentMeter

@MainActor
struct AppDelegateTests {
    @Test
    func `builds status controller after launch`() {
        AppDelegate.sessionIsActiveProvider = { true }
        defer { AppDelegate.sessionIsActiveProvider = { SessionActivityMonitor.currentSessionIsActive() } }

        let appDelegate = AppDelegate()
        let sessionNotificationCenter = NotificationCenter()
        appDelegate.sessionActivityNotificationCenter = sessionNotificationCenter
        var factoryCalls = 0
        var ttyShutdowns = 0
        let dummyStatusController = DummyStatusController()
        let managedCodexAccountCoordinator = ManagedCodexAccountCoordinator()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "AppDelegateTests"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionActivityMonitor: SessionActivityMonitor(notificationCenter: NotificationCenter()))
        store.terminateTTYProcessesForSessionQuiesce = {}
        let account = fetcher.loadAccountInfo()
        let promotionCoordinator = CodexAccountPromotionCoordinator(
            settingsStore: settings,
            usageStore: store,
            managedAccountCoordinator: managedCodexAccountCoordinator)
        appDelegate.terminateActiveProcessesForAppShutdown = {
            ttyShutdowns += 1
        }

        // Install a test factory that records invocations without touching NSStatusBar.
        StatusItemController.factory = { _, _, _, _, _, receivedManagedCoordinator, receivedPromotionCoordinator in
            factoryCalls += 1
            #expect(receivedManagedCoordinator === managedCodexAccountCoordinator)
            #expect(receivedPromotionCoordinator === promotionCoordinator)
            return dummyStatusController
        }
        defer { StatusItemController.factory = StatusItemController.defaultFactory }

        // configure should not eagerly construct the status controller
        appDelegate.configure(.init(
            store: store,
            settings: settings,
            account: account,
            selection: PreferencesSelection(),
            managedCodexAccountCoordinator: managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: promotionCoordinator,
            launchMode: AgentMeterLaunchMode(environment: [:])))
        #expect(factoryCalls == 0)

        // construction happens once after launch
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(factoryCalls == 1)

        // idempotent on subsequent calls
        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(factoryCalls == 1)

        // production termination should ask the status controller to detach AppKit status/menu state
        appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(dummyStatusController.shutdowns == 1)
        #expect(ttyShutdowns == 1)
    }

    @Test
    func `does not build session owned app work until session becomes active`() {
        let sessionState = AppDelegateSessionState(active: false)
        AppDelegate.sessionIsActiveProvider = { sessionState.active }
        defer { AppDelegate.sessionIsActiveProvider = { SessionActivityMonitor.currentSessionIsActive() } }

        let appDelegate = AppDelegate()
        let sessionNotificationCenter = NotificationCenter()
        appDelegate.sessionActivityNotificationCenter = sessionNotificationCenter
        var factoryCalls = 0
        var ttyShutdowns = 0
        let dummyStatusController = DummyStatusController()
        let managedCodexAccountCoordinator = ManagedCodexAccountCoordinator()

        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "AppDelegateInactiveSessionTests"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionActivityMonitor: SessionActivityMonitor(notificationCenter: NotificationCenter()))
        store.terminateTTYProcessesForSessionQuiesce = {}
        let account = fetcher.loadAccountInfo()
        let promotionCoordinator = CodexAccountPromotionCoordinator(
            settingsStore: settings,
            usageStore: store,
            managedAccountCoordinator: managedCodexAccountCoordinator)
        appDelegate.terminateActiveProcessesForAppShutdown = {
            ttyShutdowns += 1
        }

        StatusItemController.factory = { _, _, _, _, _, _, _ in
            factoryCalls += 1
            return dummyStatusController
        }
        defer { StatusItemController.factory = StatusItemController.defaultFactory }

        appDelegate.configure(.init(
            store: store,
            settings: settings,
            account: account,
            selection: PreferencesSelection(),
            managedCodexAccountCoordinator: managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: promotionCoordinator,
            launchMode: AgentMeterLaunchMode(environment: [:])))

        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(factoryCalls == 0)

        sessionState.active = true
        sessionNotificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil)
        #expect(factoryCalls == 1)

        sessionNotificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil)
        #expect(factoryCalls == 1)

        sessionNotificationCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil)
        #expect(dummyStatusController.shutdowns == 1)

        sessionState.active = true
        sessionNotificationCenter.post(
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil)
        #expect(factoryCalls == 2)

        appDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(ttyShutdowns == 1)
    }

    @Test
    func `session resign cancels delayed status controller startup`() async {
        let sessionState = AppDelegateSessionState(active: true)
        AppDelegate.sessionIsActiveProvider = { sessionState.active }
        defer { AppDelegate.sessionIsActiveProvider = { SessionActivityMonitor.currentSessionIsActive() } }

        let appDelegate = AppDelegate()
        let sessionNotificationCenter = NotificationCenter()
        appDelegate.sessionActivityNotificationCenter = sessionNotificationCenter
        appDelegate.statusControllerStartupDelayOverride = 0.1
        var factoryCalls = 0
        let managedCodexAccountCoordinator = ManagedCodexAccountCoordinator()
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "AppDelegateDelayedStartupTests"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            sessionActivityMonitor: SessionActivityMonitor(notificationCenter: NotificationCenter()))
        store.terminateTTYProcessesForSessionQuiesce = {}
        let promotionCoordinator = CodexAccountPromotionCoordinator(
            settingsStore: settings,
            usageStore: store,
            managedAccountCoordinator: managedCodexAccountCoordinator)

        StatusItemController.factory = { _, _, _, _, _, _, _ in
            factoryCalls += 1
            return DummyStatusController()
        }
        defer { StatusItemController.factory = StatusItemController.defaultFactory }

        appDelegate.configure(.init(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            selection: PreferencesSelection(),
            managedCodexAccountCoordinator: managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: promotionCoordinator,
            launchMode: AgentMeterLaunchMode(environment: [:])))

        appDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(factoryCalls == 0)

        sessionState.active = false
        sessionNotificationCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(factoryCalls == 0)
    }
}

@MainActor
private final class DummyStatusController: StatusItemControlling {
    private(set) var shutdowns = 0

    func openMenuFromShortcut() {}
    func runLoginFlowFromSettings(provider _: UsageProvider) async {}
    func prepareForAppShutdown() {
        self.shutdowns += 1
    }
}

@MainActor
private final class AppDelegateSessionState {
    var active: Bool

    init(active: Bool) {
        self.active = active
    }
}
