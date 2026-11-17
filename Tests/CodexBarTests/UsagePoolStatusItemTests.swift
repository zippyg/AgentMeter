import AppKit
import CodexBarCore
import Testing
@testable import AgentMeter

@MainActor
@Suite(.serialized)
struct UsagePoolStatusItemTests {
    @Test(arguments: [1, 2]) func existingCacheReadUsesEngineDecoderAndKeepsUnknownsExplicit(schema: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent(".claude-swap-backup")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try Data("""
        {"schemaVersion":\(schema),"accounts":{"1":{"fetchedAt":1793958600,"lastGood":{
          "seven_day":{"pct":65,"resets_at":"2026-11-09T19:00:00Z"}}}}}
        """.utf8).write(to: root.appendingPathComponent("cache/usage.json"))
        try Data(#"{"activeAccountNumber":1,"accounts":{"1":{},"2":{}}}"#.utf8)
            .write(to: root.appendingPathComponent("sequence.json"))
        try Data(#"{"enabled":false}"#.utf8).write(to: root.appendingPathComponent("umbrella.json"))
        let accounts = UsageStore.readUsagePoolClaudeCache(home: directory, now: UsagePoolPopoverTests.now)
        #expect(accounts.count == 2)
        #expect(accounts.first?.weekly?.usedPercent == 65)
        #expect(accounts.first?.isActive == true)
        #expect(accounts.last?.refusedSince != nil)
        #expect(accounts.allSatisfy { $0.session == nil })
        #expect(UsageStore.readUsagePoolClaudeCache(home: directory.appendingPathComponent("missing")).isEmpty)
    }

    @Test func liveClaudeCacheHydratesThePoolWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["AGENTMETER_LOCAL_CACHE_QA"] == "1" else { return }
        let now = Date()
        let accounts = UsageStore.readUsagePoolClaudeCache(now: now)
        #expect(!accounts.isEmpty)
        #expect(accounts.contains { $0.weekly != nil })
        let state = UsagePoolPresentation()
        state.update(accounts: accounts, codex: nil, sources: [], now: now)
        #expect(state.model.claude != nil)
        #expect(state.errors.isEmpty)
    }

    /// Drives the real panel, not the tracking stand-in: placement under a real status button, the single
    /// glass surface, the key monitor while shown, and monitor cleanup on every kind of close.
    /// The panel is transparent and ignores the mouse, and is never made key, so nothing on screen changes.
    @Test func productionPanelPresentsUnderItsButtonAndRemovesMonitorsOnClose() async throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        try await Self.waitForStatusWindows(of: [item])
        let button = try #require(item.button)
        let panel = UsagePoolPanel()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        let host = UsagePoolKeyView(rootView: UsagePoolPopoverView(state: UsagePoolPresentation()))
        var handled = 0
        var closes: [Int?] = []
        panel.handleKey = { _ in handled += 1; return true }
        panel.onClose = { closes.append($0) }
        panel.setContent(host, size: NSSize(width: 380, height: 300))
        var hostsKeyView = panel.contentView?.subviews.contains { $0 === host } == true
        if #available(macOS 26.0, *), let glass = panel.contentView as? NSGlassEffectView {
            hostsKeyView = hostsKeyView || glass.contentView === host
        }
        #expect(hostsKeyView)

        // Local monitors run inside NSApplication.sendEvent, before the event reaches any window.
        func sendKey() {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, characters: "r", charactersIgnoringModifiers: "r",
                isARepeat: false, keyCode: 15) else { return }
            NSApp.sendEvent(event)
        }

        panel.show(relativeTo: button.bounds, of: button, makeKey: false)
        #expect(panel.isShown)
        // A test process's status window may never be placed in the menu bar; check placement only once
        // it is on a screen (an unplaced anchor still lands inside the visible frame, never offscreen).
        if let window = button.window, window.frame.height > 0, let menuBarBottom = window.screen?.visibleFrame.maxY,
           window.frame.minY >= menuBarBottom - 1 {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            #expect(panel.frame.maxY <= anchor.minY - UsagePoolPanel.gapBelowMenuBar + 0.5)
            if let visible = window.screen?.visibleFrame {
                #expect(panel.frame.minX >= visible.minX + 8 - 0.5 && panel.frame.maxX <= visible.maxX - 8 + 0.5)
                #expect(panel.frame.minY >= visible.minY + 8 - 0.5)
            }
        }
        if let visible = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })?.visibleFrame {
            #expect(visible.contains(panel.frame))
        }
        sendKey()
        #expect(handled == 1)
        panel.performClose(nil)
        #expect(!panel.isShown)
        #expect(closes.count == 1 && closes[0] == nil)
        sendKey()
        #expect(handled == 1)
        panel.performClose(nil)
        #expect(closes.count == 1)

        // Losing key closes too, and also leaves no monitor behind.
        panel.show(relativeTo: button.bounds, of: button, makeKey: false)
        sendKey()
        #expect(handled == 2)
        panel.resignKey()
        #expect(!panel.isShown)
        #expect(closes.count == 2)
        sendKey()
        #expect(handled == 2)
    }

    @Test func nativePopoverAttachmentAndKeyEvents() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "UsagePoolStatusItemTests-\(UUID().uuidString)")!
        let settings = SettingsStore(
            userDefaults: defaults, configStore: testConfigStore(suiteName: "UsagePoolStatusItemTests"),
            zaiTokenStore: NoopZaiTokenStore(), syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store, settings: settings, account: fetcher.loadAccountInfo(), updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(), statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }
        #expect(controller.statusItem.menu == nil)
        #expect(controller.statusItem.button?.target === controller)
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
        }
        for (code, character, tab) in [(18, "1", UsagePoolViewModel.Tab.overview),
                                        (19, "2", .claude), (20, "3", .codex), (21, "4", .spend)] {
            #expect(controller.handleUsagePoolKey(try key(UInt16(code), character)))
            #expect(controller.usagePoolPresentation.tab == tab)
        }
        #expect(controller.handleUsagePoolKey(try key(124, "")))
        #expect(controller.usagePoolPresentation.tab == .overview)
        #expect(controller.handleUsagePoolKey(try key(123, "")))
        #expect(controller.usagePoolPresentation.tab == .spend)
        #expect(controller.handleUsagePoolKey(try key(19, "2", modifiers: .command)))
        #expect(controller.usagePoolPresentation.tab == .claude)
        #expect(controller.handleUsagePoolKey(try key(48, "\t")))
        #expect(controller.usagePoolPresentation.tab == .codex)
        #expect(controller.handleUsagePoolKey(try key(48, "\t", modifiers: .shift)))
        #expect(controller.usagePoolPresentation.tab == .claude)
        let button = try #require(controller.statusItem.button)
        controller.updateIcons()
        let nativeTitle = button.title
        let nativeLength = controller.statusItem.length
        controller.refreshUsagePoolPresentation()
        #expect(button.title == nativeTitle)
        #expect(controller.statusItem.length == nativeLength)
        #expect(nativeTitle.isEmpty)
        #expect(nativeLength == NSStatusItem.squareLength)
        #expect(!controller.handleUsagePoolKey(try key(7, "x")))
        #expect(!controller.handleUsagePoolKey(try key(15, "r", modifiers: .option)))
        let settingsRequests = SettingsRequestCapture()
        let windowsBeforeSettings = Set(NSApp.windows.map(ObjectIdentifier.init))
        let observer = NotificationCenter.default.addObserver(forName: .codexbarOpenSettings, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { settingsRequests.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<10 {
            controller.showSettingsGeneral()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        #expect(settingsRequests.count == 10)
        // Settings must open no window here. Status-bar windows are process-wide and other suites running
        // in parallel create their own, so this controller's are found by attribution: any status-bar
        // window whose buttons target this controller. There must be exactly one per item it tracks, so an
        // orphan duplicate item the controller made and lost track of still fails.
        let newWindows = NSApp.windows.filter {
            !windowsBeforeSettings.contains(ObjectIdentifier($0)) && !Self.isStatusBarWindow($0)
        }
        #expect(newWindows.isEmpty, "\(newWindows.map { String(describing: type(of: $0)) })")
        try await Self.waitForStatusWindows(of: [controller.statusItem] + Array(controller.statusItems.values))
        let ownItems = [controller.statusItem] + Array(controller.statusItems.values)
        let ownWindows = Set(ownItems.compactMap { $0.button?.window }.map(ObjectIdentifier.init))
        let attributed = Set(Self.statusBarWindows(targeting: controller).map(ObjectIdentifier.init))
        #expect(ownWindows.count == ownItems.count)
        #expect(attributed == ownWindows, "\(attributed.count) status-bar windows target this controller, \(ownItems.count) items")
        var popovers: [TrackingPoolPanel] = []
        controller.makeUsagePoolPanel = {
            let popover = TrackingPoolPanel()
            popovers.append(popover)
            return popover
        }
        controller.toggleUsagePool(nil)
        let first = try #require(popovers.first)
        #expect(first.isShown)
        // One surface: the glass view (or its fallback) wraps the hosting view directly.
        let surface = try #require(first.contentView)
        var hostsKeyView = surface.subviews.contains { $0 is UsagePoolKeyView }
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            hostsKeyView = hostsKeyView || glass.contentView is UsagePoolKeyView
        }
        #expect(hostsKeyView)
        #expect(first.canBecomeKey && !first.canBecomeMain)
        #expect(first.styleMask.contains(.nonactivatingPanel) && !first.styleMask.contains(.titled))
        #expect(UsagePoolKeyView(rootView: UsagePoolPopoverView(state: UsagePoolPresentation())).acceptsFirstMouse(for: nil))
        controller.toggleUsagePool(nil)
        #expect(!first.isShown)
        #expect(controller.usagePoolPanel == nil)
        controller.toggleUsagePool(nil)
        #expect(popovers.count == 2)
        #expect(popovers[1].isShown)
        // A stale close from the previous panel never clears the current one.
        first.onClose?(nil)
        #expect(controller.usagePoolPanel === popovers[1])
        #expect(controller.handleUsagePoolKey(try key(53, "")))
        #expect(!popovers[1].isShown)
        #expect(controller.usagePoolPanel == nil)
        #expect(controller.usagePoolDismissingClick == nil)
        // Rapid intentional reopen after an explicit close is never suppressed.
        controller.toggleUsagePool(button)
        #expect(popovers.count == 3)
        // A click elsewhere in the app dismissed it; a different event (here none) reopens at once.
        popovers[2].dismissByClickAway(click: 4242)
        #expect(controller.usagePoolPanel == nil)
        #expect(controller.usagePoolDismissingClick == 4242)
        controller.toggleUsagePool(button)
        #expect(popovers.count == 4)
        #expect(controller.usagePoolDismissingClick == nil)
        // The keyboard shortcut after a click-away close reopens straight away.
        popovers[3].dismissByClickAway(click: 4243)
        controller.openMenuFromShortcut()
        #expect(popovers.count == 5 && popovers[4].isShown)
        #expect(controller.closeOpenMenusFromShortcutIfNeeded())
        controller._test_manualRefreshOperation = {}
        #expect(controller.handleUsagePoolKey(try key(15, "r")))
        #expect(controller.manualRefreshTask != nil)
        controller.toggleUsagePool(nil)
        #expect(popovers.count == 6)
        for _ in 0..<50 {
            #expect(controller.closeOpenMenusFromShortcutIfNeeded())
            controller.openMenuFromShortcut()
            #expect(controller.usagePoolPanel?.isShown == true)
        }
        #expect(popovers.count == 56)
        controller.prepareForAppShutdown()
        #expect(!popovers[55].isShown)
        #expect(controller.usagePoolPanel == nil)
        controller.toggleUsagePool(nil)
        #expect(popovers.count == 56)
    }
}

extension UsagePoolStatusItemTests {
    static func isStatusBarWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)) == "NSStatusBarWindow"
    }

    /// Status-bar windows holding a button whose target is `controller`.
    static func statusBarWindows(targeting controller: AnyObject) -> [NSWindow] {
        func buttons(in view: NSView) -> [NSStatusBarButton] {
            ((view as? NSStatusBarButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons(in:))
        }
        return NSApp.windows.filter { window in
            guard self.isStatusBarWindow(window), let root = window.contentView?.superview ?? window.contentView else {
                return false
            }
            return buttons(in: root).contains { $0.target === controller }
        }
    }

    /// Status items get their window asynchronously; wait briefly so the check sees settled state.
    static func waitForStatusWindows(of items: [NSStatusItem]) async throws {
        for _ in 0..<50 where items.contains(where: { $0.button?.window == nil }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

@MainActor
private final class TrackingPoolPanel: UsagePoolPanel {
    private var simulatedShown = false
    override var isShown: Bool { self.simulatedShown }

    override func show(relativeTo rect: NSRect, of view: NSView, makeKey: Bool) {
        self.simulatedShown = true
    }

    override func performClose(_ sender: Any?) {
        guard self.simulatedShown else { return }
        self.simulatedShown = false
        self.onClose?(nil)
    }

    func dismissByClickAway(click: Int) {
        self.simulatedShown = false
        self.onClose?(click)
    }
}

@MainActor
private final class SettingsRequestCapture {
    var count = 0
}
