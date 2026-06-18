import AppKit
import CodexBarCore
import Testing
@testable import AgentMeter

@MainActor
@Suite(.serialized)
struct StatusItemControllerSplitLifecycleTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        .system
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusItemControllerSplitLifecycleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func containsHostingView(_ view: NSView) -> Bool {
        if String(describing: type(of: view)).contains("NSHostingView") {
            return true
        }
        return view.subviews.contains { self.containsHostingView($0) }
    }

    private func makeSplitController() throws -> (SettingsStore, StatusItemController) {
        try self.makeController(enabledProviders: [.codex, .claude], mergeIcons: false)
    }

    private func makeController(
        enabledProviders: [UsageProvider],
        mergeIcons: Bool)
        throws -> (SettingsStore, StatusItemController)
    {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = mergeIcons
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            if let metadata = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: false)
            }
        }
        for provider in enabledProviders {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(registry.metadata[provider]),
                enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        return (settings, controller)
    }

    @Test
    func `merged mode removes split provider status items`() throws {
        let (settings, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.statusItems[.codex] != nil)
        #expect(controller.statusItems[.claude] != nil)

        settings.mergeIcons = true
        controller.handleProviderConfigChange(reason: "test")

        #expect(controller.statusItem.isVisible == true)
        #expect(controller.statusItems.isEmpty)
    }

    @Test
    func `merged mode keeps a single provider on the app status item`() throws {
        let (_, controller) = try self.makeController(enabledProviders: [.codex], mergeIcons: true)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.shouldMergeIcons)
        #expect(controller.statusItem.isVisible)
        #expect(controller.statusItems.isEmpty)
        #expect(controller.statusItem.button?.image != nil)
    }

    @Test
    func `merged mode stays visible with no enabled providers`() throws {
        let (_, controller) = try self.makeController(enabledProviders: [], mergeIcons: true)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.shouldMergeIcons)
        #expect(controller.statusItem.isVisible)
        #expect(controller.statusItems.isEmpty)
        #expect(controller.statusItem.button?.image != nil)
    }

    @Test
    func `menu bar icons stay appkit hosted`() throws {
        let (settings, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        let codexButton = try #require(controller.statusItems[.codex]?.button)
        #expect(codexButton.image != nil)
        #expect(!self.containsHostingView(codexButton))

        settings.mergeIcons = true
        controller.handleProviderConfigChange(reason: "test")

        let mergedButton = try #require(controller.statusItem.button)
        #expect(mergedButton.image != nil)
        #expect(!self.containsHostingView(mergedButton))
    }

    @Test
    func `status items publish stable manager identity`() throws {
        let (_, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        let codexButton = try #require(controller.statusItems[.codex]?.button)
        let claudeButton = try #require(controller.statusItems[.claude]?.button)

        #expect(controller.statusItem.autosaveName == "com.zain.agentmeter.menu")
        #expect(controller.statusItems[.codex]?.autosaveName == "com.zain.agentmeter.menu.codex")
        #expect(controller.statusItems[.claude]?.autosaveName == "com.zain.agentmeter.menu.claude")
        #expect(controller.statusItem.length == NSStatusItem.variableLength)
        #expect(controller.statusItem.button?.accessibilityIdentifier() == "AgentMeter.StatusItem")
        #expect(codexButton.accessibilityIdentifier() == "AgentMeter.StatusItem.codex")
        #expect(claudeButton.accessibilityIdentifier() == "AgentMeter.StatusItem.claude")
        #expect(controller.statusItem.button?.accessibilityTitle() == "AgentMeter")
        #expect(codexButton.accessibilityTitle() == "AgentMeter")
        #expect(claudeButton.accessibilityTitle() == "AgentMeter")
    }

    @Test
    func `status item identity returns stable autosave names`() {
        #expect(StatusItemController.StatusItemIdentity.merged.autosaveName ==
            "com.zain.agentmeter.menu")
        #expect(StatusItemController.StatusItemIdentity.provider(.codex).autosaveName ==
            "com.zain.agentmeter.menu.codex")
        #expect(StatusItemController.StatusItemIdentity.provider(.claude).autosaveName ==
            "com.zain.agentmeter.menu.claude")
    }

    @Test
    func `merged status item construction leaves preferred position unset`() throws {
        let (settings, controller) = try self.makeController(enabledProviders: [.codex], mergeIcons: true)
        defer { controller.releaseStatusItemsForTesting() }
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(
            autosaveName: StatusItemController.StatusItemIdentity.merged.autosaveName)

        #expect(settings.userDefaults.object(forKey: key) == nil)
    }

    @Test
    func `status item defaults migration moves legacy AgentMeter keys`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-migrate-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(128, forKey: "NSStatusItem Preferred Position com.zain.agentmeter.mac")
        defaults.set(true, forKey: "NSStatusItem Visible com.zain.agentmeter.mac")
        defaults.set(true, forKey: "NSStatusItem VisibleCC com.zain.agentmeter.mac")

        let changedKeys = MenuBarStatusItemDefaultsRepair.migrateLegacyStatusItemDefaults(
            defaults: defaults,
            autosaveName: StatusItemController.StatusItemIdentity.merged.autosaveName,
            legacyAutosaveNames: StatusItemController.StatusItemIdentity.merged.legacyAutosaveNames)

        #expect(changedKeys.contains("NSStatusItem Preferred Position com.zain.agentmeter.mac"))
        #expect(defaults.object(forKey:
            "NSStatusItem Preferred Position com.zain.agentmeter.menu") == nil)
        #expect(defaults.bool(forKey: "NSStatusItem Visible com.zain.agentmeter.menu"))
        #expect(defaults.bool(forKey: "NSStatusItem VisibleCC com.zain.agentmeter.menu"))
        #expect(defaults.object(forKey: "NSStatusItem Preferred Position com.zain.agentmeter.mac") == nil)
        #expect(defaults.object(forKey: "NSStatusItem Visible com.zain.agentmeter.mac") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC com.zain.agentmeter.mac") == nil)
    }

    @Test
    func `status item defaults migration moves previous local identity keys`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-migrate-local-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(128, forKey: "NSStatusItem Preferred Position com.zain.agentmeter.local")
        defaults.set(true, forKey: "NSStatusItem Visible com.zain.agentmeter.local")
        defaults.set(true, forKey: "NSStatusItem VisibleCC com.zain.agentmeter.local")

        let changedKeys = MenuBarStatusItemDefaultsRepair.migrateLegacyStatusItemDefaults(
            defaults: defaults,
            autosaveName: StatusItemController.StatusItemIdentity.merged.autosaveName,
            legacyAutosaveNames: StatusItemController.StatusItemIdentity.merged.legacyAutosaveNames)

        #expect(changedKeys.contains("NSStatusItem Preferred Position com.zain.agentmeter.local"))
        #expect(defaults.object(forKey:
            "NSStatusItem Preferred Position com.zain.agentmeter.menu") == nil)
        #expect(defaults.bool(forKey: "NSStatusItem Visible com.zain.agentmeter.menu"))
        #expect(defaults.bool(forKey: "NSStatusItem VisibleCC com.zain.agentmeter.menu"))
        #expect(defaults.object(forKey: "NSStatusItem Preferred Position com.zain.agentmeter.local") == nil)
        #expect(defaults.object(forKey: "NSStatusItem Visible com.zain.agentmeter.local") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC com.zain.agentmeter.local") == nil)
    }

    @Test
    func `status item placement preflight leaves fresh install placement unset`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-missing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "com.zain.agentmeter.mac")

        #expect(!MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac"))
        #expect(defaults.object(forKey: key) == nil)
    }

    @Test
    func `status item placement preflight preserves missing new key when legacy item placement exists`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-legacy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(42, forKey: "NSStatusItem Preferred Position Item-0")
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "com.zain.agentmeter.mac")

        #expect(!MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac",
            legacyDefaultItemIndex: 0))

        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.double(forKey: "NSStatusItem Preferred Position Item-0") == 42)
    }

    @Test
    func `status item placement preflight clears suspicious matching legacy placement`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-legacy-high-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(11298, forKey: "NSStatusItem Preferred Position Item-0")
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "com.zain.agentmeter.mac")

        #expect(MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac",
            legacyDefaultItemIndex: 0,
            maximumPreferredPosition: 3000))

        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.object(forKey: "NSStatusItem Preferred Position Item-0") == nil)
    }

    @Test
    func `status item placement preflight preserves missing new key when mixed legacy placements exist`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-legacy-mixed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(42, forKey: "NSStatusItem Preferred Position Item-0")
        defaults.set(11298, forKey: "NSStatusItem Preferred Position Item-1")
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "com.zain.agentmeter.mac")

        #expect(!MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac",
            legacyDefaultItemIndex: 0))

        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.double(forKey: "NSStatusItem Preferred Position Item-0") == 42)
        #expect(defaults.double(forKey: "NSStatusItem Preferred Position Item-1") == 11298)
    }

    @Test
    func `status item placement preflight clears provider matching suspicious legacy placement`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-provider-mixed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(42, forKey: "NSStatusItem Preferred Position Item-0")
        defaults.set(11298, forKey: "NSStatusItem Preferred Position Item-1")
        let key = MenuBarStatusItemPlacementPreflight
            .preferredPositionKey(autosaveName: "com.zain.agentmeter.mac.codex")

        #expect(MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac.codex",
            legacyDefaultItemIndex: 1,
            maximumPreferredPosition: 3000))

        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.double(forKey: "NSStatusItem Preferred Position Item-0") == 42)
        #expect(defaults.object(forKey: "NSStatusItem Preferred Position Item-1") == nil)
    }

    @Test
    func `status item placement preflight leaves provider key unset when only merged legacy placement exists`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-provider-single-legacy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(42, forKey: "NSStatusItem Preferred Position Item-0")
        let key = MenuBarStatusItemPlacementPreflight
            .preferredPositionKey(autosaveName: "com.zain.agentmeter.mac.codex")

        #expect(!MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac.codex",
            legacyDefaultItemIndex: 1))

        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.double(forKey: "NSStatusItem Preferred Position Item-0") == 42)
    }

    @Test
    func `status item placement preflight preserves provider key with matching legacy placement`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-provider-matching-legacy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(42, forKey: "NSStatusItem Preferred Position Item-0")
        defaults.set(58, forKey: "NSStatusItem Preferred Position Item-1")
        let key = MenuBarStatusItemPlacementPreflight
            .preferredPositionKey(autosaveName: "com.zain.agentmeter.mac.codex")

        #expect(!MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac.codex",
            legacyDefaultItemIndex: 1))

        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.double(forKey: "NSStatusItem Preferred Position Item-0") == 42)
        #expect(defaults.double(forKey: "NSStatusItem Preferred Position Item-1") == 58)
    }

    @Test
    func `status item placement preflight clears suspicious high position`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-high-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "com.zain.agentmeter.mac")
        defaults.set(11298, forKey: key)

        #expect(MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac",
            maximumPreferredPosition: 3000))

        #expect(defaults.object(forKey: key) == nil)
    }

    @Test
    func `status item placement preflight clears old forced zero position`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-zero-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "com.zain.agentmeter.mac")
        defaults.set(0, forKey: key)

        #expect(MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac"))

        #expect(defaults.object(forKey: key) == nil)
    }

    @Test
    func `status item placement preflight clears left edge position`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-left-edge-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "com.zain.agentmeter.mac")
        defaults.set(2, forKey: key)

        #expect(MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac"))

        #expect(defaults.object(forKey: key) == nil)
    }

    @Test
    func `status item placement preflight clears malformed position`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-malformed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "com.zain.agentmeter.mac")
        defaults.set("not-a-position", forKey: key)

        #expect(MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac"))

        #expect(defaults.object(forKey: key) == nil)
    }

    @Test
    func `status item placement preflight preserves reasonable position`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-preserve-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "com.zain.agentmeter.mac")
        defaults.set(42, forKey: key)

        #expect(!MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac"))

        #expect(defaults.double(forKey: key) == 42)
    }

    @Test
    func `status item placement preflight preserves large display position`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-placement-preserve-large-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = MenuBarStatusItemPlacementPreflight.preferredPositionKey(autosaveName: "com.zain.agentmeter.mac")
        defaults.set(2500, forKey: key)

        #expect(!MenuBarStatusItemPlacementPreflight.prepare(
            defaults: defaults,
            autosaveName: "com.zain.agentmeter.mac",
            maximumPreferredPosition: 2560))

        #expect(defaults.double(forKey: key) == 2500)
    }

    @Test
    func `status item defaults repair removes only legacy AgentMeter hidden keys`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-repair-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "NSStatusItem VisibleCC Item-0")
        defaults.set(0, forKey: "NSStatusItem VisibleCC Item-12")
        defaults.set(false, forKey: "NSStatusItem VisibleCC com.zain.agentmeter.local")
        defaults.set(false, forKey: "NSStatusItem VisibleCC com.zain.agentmeter.mac")
        defaults.set(false, forKey: "NSStatusItem Visible agentmeter-merged")
        defaults.set(false, forKey: "NSStatusItem Visible com.zain.agentmeter.menu")
        defaults.set(false, forKey: "NSStatusItem Visible com.zain.agentmeter.statusitem.v5-merged")
        defaults.set(true, forKey: "NSStatusItem VisibleCC Item-1")
        defaults.set(false, forKey: "NSStatusItem VisibleCC com.apple.clock")
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        let repairedKeys = MenuBarStatusItemDefaultsRepair.repairHiddenVisibilityDefaultsIfNeeded(defaults: defaults)

        #expect(repairedKeys == [
            "NSStatusItem Visible agentmeter-merged",
            "NSStatusItem Visible com.zain.agentmeter.menu",
            "NSStatusItem Visible com.zain.agentmeter.statusitem.v5-merged",
            "NSStatusItem VisibleCC com.zain.agentmeter.local",
            "NSStatusItem VisibleCC com.zain.agentmeter.mac",
        ])
        #expect(defaults.object(forKey: "NSStatusItem Visible agentmeter-merged") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC Item-0") != nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC Item-12") != nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC com.zain.agentmeter.local") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC com.zain.agentmeter.mac") == nil)
        #expect(defaults.object(forKey: "NSStatusItem Visible com.zain.agentmeter.menu") == nil)
        #expect(defaults.object(forKey: "NSStatusItem Visible com.zain.agentmeter.statusitem.v5-merged") == nil)
        #expect(defaults.bool(forKey: "NSStatusItem VisibleCC Item-1"))
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC com.apple.clock") != nil)

        defaults.set(false, forKey: "NSStatusItem VisibleCC Item-2")
        defaults.set(false, forKey: "NSStatusItem VisibleCC agentmeter-merged")
        defaults.set(false, forKey: "NSStatusItem Visible com.zain.agentmeter.mac")
        #expect(MenuBarStatusItemDefaultsRepair.repairHiddenVisibilityDefaultsIfNeeded(defaults: defaults) == [
            "NSStatusItem Visible com.zain.agentmeter.mac",
            "NSStatusItem VisibleCC agentmeter-merged",
        ])
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC Item-2") != nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC agentmeter-merged") == nil)
        #expect(defaults.object(forKey: "NSStatusItem Visible com.zain.agentmeter.mac") == nil)
    }

    @Test
    func `status item diagnostics writes sanitized geometry`() throws {
        let (_, controller) = try self.makeController(enabledProviders: [.codex], mergeIcons: true)
        defer { controller.releaseStatusItemsForTesting() }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-item-diagnostics-\(UUID().uuidString).json")
        StatusItemDiagnosticsWriter.fileURLOverrideForTesting = fileURL
        defer {
            StatusItemDiagnosticsWriter.fileURLOverrideForTesting = nil
            try? FileManager.default.removeItem(at: fileURL)
        }

        controller.writeStatusItemDiagnostics(reason: "test")

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(StatusItemDiagnosticsPayload.self, from: data)
        let merged = try #require(payload.items.first { $0.identity == "merged" })
        #expect(payload.schemaVersion == 3)
        #expect(payload.reason == "test")
        #expect(payload.bundleIdentifier == Bundle.main.bundleIdentifier ?? "com.zain.agentmeter.menu")
        #expect(payload.enabledProviders.contains("codex"))
        #expect(payload.loginItemStatus == "testing")
        #expect(merged.autosaveName == "com.zain.agentmeter.menu")
        #expect(merged.accessibilityIdentifier == "AgentMeter.StatusItem")
        #expect(merged.hasButton)
        #expect(merged.hasImage)
        #expect(merged.isBlocked == MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: StatusItemVisibilitySnapshot(
            isVisible: merged.isVisible,
            hasButton: merged.hasButton,
            hasWindow: merged.hasWindow,
            hasScreen: merged.hasScreen,
            isOnMainScreen: merged.isOnMainScreen,
            isInMainScreenFrame: merged.isInMainScreenFrame,
            isInMenuExtraRegion: merged.isInMenuExtraRegion,
            buttonWidth: CGFloat(merged.buttonWidth),
            windowHeight: CGFloat(merged.windowHeight ?? 0))))
        let payloadString = try #require(String(bytes: data, encoding: .utf8))
        #expect(!payloadString.localizedCaseInsensitiveContains("bearer "))
    }
}
