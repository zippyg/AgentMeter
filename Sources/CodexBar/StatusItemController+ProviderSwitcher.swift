import AppKit
import CodexBarCore

struct PendingProviderSwitcherRebuild {
    let menu: NSMenu
    let provider: UsageProvider?
}

/// Handles provider-switcher keyboard shortcuts and overview scrolling while the merged
/// status menu is open. `NSMenu` tracking pulls events itself, so local event monitors,
/// Carbon dispatcher handlers, registered hot keys (tracking pushes a hotkey-disable mode),
/// and `menuHasKeyEquivalent` never see these events. Peeking the queue from a run-loop
/// observer is the only delivery path.
///
/// The peek itself must not disturb the tracking session: `NSApp.nextEvent` re-enters the
/// event loop in the mode it is given, and re-entering `.eventTracking` dispatches the menu
/// session's own timers and sources mid-observer. When that landed during menu setup or amid
/// rapid claimed key repeats, it killed the session and left a zombie menu on screen that no
/// longer dequeued events: clicks sat in the queue for tens of seconds while the cursor
/// beach-balled. Three guards prevent that: peeks run in a private run-loop mode with no
/// sources or timers registered (the queue is mode-agnostic, so matching still works), the
/// peek only starts once the tracking loop is confirmed pumping, and mouse clicks are not
/// monitored at all (`ProviderSwitcherView` handles those via its own `mouseDown`/`mouseUp`
/// overrides), so the monitor never dequeues a click meant for AppKit.
///
/// Every tracking pass peeks; there is deliberately no cheaper pre-check. An earlier gate
/// skipped the peek unless the `CGEventSource` session key counters had advanced, assuming
/// they move before the `NSEvent` is queued. On macOS 27.2 the counter lags the queued event
/// by up to ~200 ms, so the gate stayed shut while the key was pending and the menu consumed
/// Tab, Cmd-number and arrow keys itself. An empty peek in the private mode costs ~10-20 us.
@MainActor
final class ProviderSwitcherShortcutEventMonitor {
    private let callback: @MainActor (NSEvent) -> Bool
    private let observer: CFRunLoopObserver
    private let trackingState = ProviderSwitcherMenuTrackingState()
    private var isActive = false

    /// A run-loop mode nothing else registers sources or timers in, so running the loop in
    /// this mode while polling the event queue cannot dispatch menu-session work re-entrantly.
    private static let peekMode = RunLoop.Mode("com.zain.agentmeter.switcher-peek")

    init(
        events: NSEvent.EventTypeMask,
        callback: @escaping @MainActor (NSEvent) -> Bool)
    {
        self.callback = callback
        let trackingState = self.trackingState

        self.observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeSources.rawValue,
            true,
            0)
        { [events, callback, trackingState] _, _ in
            MainActor.assumeIsolated {
                guard trackingState.isTrackingActive else { return }
                while let event = NSApp.nextEvent(
                    matching: events,
                    until: .distantPast,
                    inMode: Self.peekMode,
                    dequeue: false)
                {
                    guard callback(event) else { break }
                    _ = NSApp.nextEvent(
                        matching: events,
                        until: .distantPast,
                        inMode: Self.peekMode,
                        dequeue: true)
                }
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            self.stop()
        }
    }

    func start() {
        guard !self.isActive else { return }
        CFRunLoopAddObserver(
            RunLoop.main.getCFRunLoop(),
            self.observer,
            CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        self.isActive = true
        // The menus this monitors are shown via `popUpMenuPositioningItem`, which posts no
        // NSMenu tracking notifications. Arm the gate from a block queued in the tracking
        // run-loop mode instead: it can only execute once the menu's tracking session is alive
        // and pumping the run loop, which keeps peeks away from menu setup.
        let trackingState = self.trackingState
        RunLoop.main.perform(inModes: [.eventTracking]) {
            MainActor.assumeIsolated {
                trackingState.isTrackingActive = true
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func stop() {
        self.trackingState.isTrackingActive = false
        guard self.isActive else { return }
        CFRunLoopRemoveObserver(
            RunLoop.main.getCFRunLoop(),
            self.observer,
            CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        self.isActive = false
    }
}

/// Tracks whether an `NSMenu` tracking session is currently alive, so the shortcut monitor
/// only touches the event queue while AppKit is actually pumping it.
@MainActor
private final class ProviderSwitcherMenuTrackingState {
    var isTrackingActive = false
}

@MainActor
private final class ProviderSwitcherTrackingRunLoopOperation {
    private var operation: (@MainActor () -> Void)?

    init(operation: @escaping @MainActor () -> Void) {
        self.operation = operation
    }

    func run() {
        guard let operation = self.operation else { return }
        self.operation = nil
        operation()
    }
}

@MainActor
enum ProviderSwitcherTrackingRunLoopScheduler {
    static func schedule(_ operation: @escaping @MainActor () -> Void) {
        let pending = ProviderSwitcherTrackingRunLoopOperation(operation: operation)
        let runLoop = CFRunLoopGetMain()
        // Main-actor tasks can starve while AppKit owns the modal menu loop. Queue in both modes so the
        // rebuild runs during tracking, with the default mode as a fallback if tracking ends first.
        let modes = [
            RunLoop.Mode.eventTracking.rawValue,
            RunLoop.Mode.default.rawValue,
        ]
        for mode in modes {
            CFRunLoopPerformBlock(runLoop, mode as CFString) {
                MainActor.assumeIsolated {
                    pending.run()
                }
            }
        }
        CFRunLoopWakeUp(runLoop)
    }
}

extension StatusItemController {
    func installProviderSwitcherShortcutMonitorIfNeeded(for menu: NSMenu) {
        guard self.isMenuRefreshEnabled,
              self.shouldMergeIcons,
              menu.items.first?.view is ProviderSwitcherView
        else {
            return
        }

        self.removeProviderSwitcherShortcutMonitor()
        self.resetOverviewScrollAccumulation()
        let monitor = ProviderSwitcherShortcutEventMonitor(
            events: [.keyDown, .keyUp, .scrollWheel])
        { [weak self, weak menu] event in
            guard let self,
                  let menu,
                  self.openMenus[ObjectIdentifier(menu)] != nil,
                  menu.items.first?.view is ProviderSwitcherView
            else {
                return false
            }

            return self.handleProviderSwitcherTrackingEvent(event, menu: menu)
        }
        monitor.start()
        self.providerSwitcherShortcutEventMonitor = monitor
        self.providerSwitcherShortcutMenuID = ObjectIdentifier(menu)
    }

    func removeProviderSwitcherShortcutMonitor() {
        self.providerSwitcherShortcutEventMonitor?.stop()
        self.providerSwitcherShortcutEventMonitor = nil
        self.providerSwitcherShortcutMenuID = nil
        self.clearProviderSwitcherPointerInteraction()
    }

    func providerSwitcherContentStartIndex(in menu: NSMenu) -> Int {
        menu.items.first?.view is ProviderSwitcherView ? 2 : 0
    }

    @discardableResult
    func handleProviderSwitcherShortcut(_ event: NSEvent, menu: NSMenu) -> Bool {
        if let direction = StatusItemMenu.providerSwitcherTabNavigationDirection(for: event) {
            self.navigateProviderSwitcher(direction, menu: menu)
            return true
        }
        if let index = StatusItemMenu.providerSelectionIndex(for: event) {
            return self.selectProviderSwitcherSegment(at: index, menu: menu)
        }
        if let direction = StatusItemMenu.providerNavigationDirection(for: event) {
            self.navigateProviderSwitcher(direction, menu: menu)
            return true
        }
        return false
    }

    @discardableResult
    func handleProviderSwitcherTrackingEvent(_ event: NSEvent, menu: NSMenu) -> Bool {
        switch event.type {
        case .keyDown:
            return self.handleProviderSwitcherShortcut(event, menu: menu)
        case .leftMouseDown:
            guard let switcher = menu.items.first?.view as? ProviderSwitcherView else { return false }
            self.beginProviderSwitcherPointerInteraction(in: menu)
            let handled = switcher.handleMenuTrackingMouseDown(event)
            if !handled {
                self.clearProviderSwitcherPointerInteraction(in: menu)
            }
            return handled
        case .leftMouseUp:
            guard self.providerSwitcherPointerInteractionMenuID == ObjectIdentifier(menu) else {
                return false
            }
            guard let switcher = menu.items.first?.view as? ProviderSwitcherView else {
                self.clearProviderSwitcherPointerInteraction(in: menu)
                return true
            }
            _ = switcher.handleMenuTrackingMouseUp(event)
            self.finishProviderSwitcherPointerInteraction(in: menu)
            return true
        case .scrollWheel:
            return self.handleOverviewScrollWheel(event, menu: menu)
        default:
            return false
        }
    }

    func requestProviderSwitcherMenuRebuild(_ menu: NSMenu, provider: UsageProvider?) {
        guard self.providerSwitcherPointerInteractionMenuID == ObjectIdentifier(menu) else {
            self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: provider)
            return
        }
        self.pendingProviderSwitcherPointerRebuild = PendingProviderSwitcherRebuild(
            menu: menu,
            provider: provider)
    }

    private func beginProviderSwitcherPointerInteraction(in menu: NSMenu) {
        let menuID = ObjectIdentifier(menu)
        if self.providerSwitcherPointerInteractionMenuID != menuID {
            self.pendingProviderSwitcherPointerRebuild = nil
        }
        self.providerSwitcherPointerInteractionMenuID = menuID
    }

    private func finishProviderSwitcherPointerInteraction(in menu: NSMenu) {
        let menuID = ObjectIdentifier(menu)
        guard self.providerSwitcherPointerInteractionMenuID == menuID else { return }
        self.providerSwitcherPointerInteractionMenuID = nil
        guard let pending = self.pendingProviderSwitcherPointerRebuild,
              pending.menu === menu
        else {
            self.pendingProviderSwitcherPointerRebuild = nil
            return
        }
        self.pendingProviderSwitcherPointerRebuild = nil
        self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: pending.provider)
    }

    private func clearProviderSwitcherPointerInteraction(in menu: NSMenu? = nil) {
        if let menu,
           self.providerSwitcherPointerInteractionMenuID != ObjectIdentifier(menu)
        {
            return
        }
        self.providerSwitcherPointerInteractionMenuID = nil
        self.pendingProviderSwitcherPointerRebuild = nil
    }

    @discardableResult
    private func selectProviderSwitcherSegment(at index: Int, menu: NSMenu) -> Bool {
        guard let switcherView = menu.items.first?.view as? ProviderSwitcherView,
              switcherView.handleKeyboardSelection(at: index)
        else {
            return false
        }
        return true
    }
}
