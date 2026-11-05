import AppKit
import CodexBarCore
import Testing
@testable import AgentMeter

@MainActor
@Suite(.serialized)
struct StatusMenuTabNavigationTests {
    @Test
    func `merged switcher handles tab navigation with wraparound`() throws {
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let (settings, controller, menu) = try self.makeControllerAndMenu()
        defer { controller.releaseStatusItemsForTesting() }

        #expect(try controller.handleProviderSwitcherTrackingEvent(Self.tabKeyEvent(), menu: menu))
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .codex)

        #expect(try controller.handleProviderSwitcherTrackingEvent(Self.tabKeyEvent(isARepeat: true), menu: menu))
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)

        #expect(try controller.handleProviderSwitcherTrackingEvent(Self.tabKeyEvent(), menu: menu))
        #expect(settings.mergedMenuLastSelectedWasOverview == true)

        #expect(try controller.handleProviderSwitcherTrackingEvent(
            Self.tabKeyEvent(modifiers: [.shift], isARepeat: true),
            menu: menu))
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)
    }

    @Test
    func `tab navigation rejects modified and non-key-down events`() throws {
        #expect(try StatusItemMenu.providerSwitcherTabNavigationDirection(for: Self.tabKeyEvent()) == .next)
        #expect(
            try StatusItemMenu.providerSwitcherTabNavigationDirection(
                for: Self.tabKeyEvent(modifiers: [.shift])) == .previous)

        for modifiers: NSEvent.ModifierFlags in [[.command], [.option], [.control], [.function], [.command, .shift]] {
            #expect(
                try StatusItemMenu.providerSwitcherTabNavigationDirection(
                    for: Self.tabKeyEvent(modifiers: modifiers)) == nil)
        }
        #expect(
            try StatusItemMenu.providerSwitcherTabNavigationDirection(
                for: Self.tabKeyEvent(type: .keyUp)) == nil)
        #expect(
            try StatusItemMenu.providerSwitcherTabNavigationDirection(
                for: Self.tabKeyEvent(keyCode: 49)) == nil)

        let menu = StatusItemMenu()
        let switcherItem = NSMenuItem()
        switcherItem.view = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: true,
            width: 320,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { _ in })
        menu.addItem(switcherItem)
        #expect(try menu.performKeyEquivalent(with: Self.tabKeyEvent()) == false)

        let (settings, controller, trackedMenu) = try self.makeControllerAndMenu()
        defer { controller.releaseStatusItemsForTesting() }
        for modifiers: NSEvent.ModifierFlags in [[.command], [.option], [.control], [.function], [.command, .shift]] {
            #expect(try !controller.handleProviderSwitcherTrackingEvent(
                Self.tabKeyEvent(modifiers: modifiers, isARepeat: true),
                menu: trackedMenu))
            #expect(settings.mergedMenuLastSelectedWasOverview == true)
            #expect(settings.selectedMenuProvider == .codex)
        }
    }

    @Test
    func `closing merged menu removes tab tracking monitor`() throws {
        let (_, controller, menu) = try self.makeControllerAndMenu()
        defer { controller.releaseStatusItemsForTesting() }

        let menuID = ObjectIdentifier(menu)
        #expect(controller.openMenus[menuID] === menu)
        #expect(controller.providerSwitcherShortcutEventMonitor != nil)
        #expect(controller.providerSwitcherShortcutMenuID == menuID)

        controller.menuDidClose(menu)

        #expect(controller.openMenus[menuID] == nil)
        #expect(controller.providerSwitcherShortcutEventMonitor == nil)
        #expect(controller.providerSwitcherShortcutMenuID == nil)
    }

    private func makeControllerAndMenu() throws -> (
        settings: SettingsStore,
        controller: StatusItemController,
        menu: StatusItemMenu)
    {
        let suite = "StatusMenuTabNavigationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.menuWillOpen(menu)
        #expect(menu.items.first?.view is ProviderSwitcherView)
        return (settings, controller, menu)
    }

    private static func tabKeyEvent(
        type: NSEvent.EventType = .keyDown,
        modifiers: NSEvent.ModifierFlags = [],
        isARepeat: Bool = false,
        keyCode: UInt16 = 48) throws -> NSEvent
    {
        try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: isARepeat,
            keyCode: keyCode))
    }
}
