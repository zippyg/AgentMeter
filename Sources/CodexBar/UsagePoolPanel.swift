import AppKit

/// The pool window, presented like the macOS 26 menu-bar extras: an arrowless rounded glass panel
/// hanging under the status item. One glass surface owns the whole window, so there is no second
/// popover material behind it and no separately drawn arrow.
@MainActor
class UsagePoolPanel: NSPanel {
    /// Called once per close. `dismissingClick` is the event number of the in-app mouse-down that took
    /// focus away, so the status button can ignore exactly that click instead of a time window.
    var onClose: ((_ dismissingClick: Int?) -> Void)?
    /// Sees key events before any focused control, so Tab and the shortcuts keep working after a click
    /// moves focus into the period picker or a disclosure group.
    var handleKey: ((NSEvent) -> Bool)?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    static let cornerRadius: CGFloat = 20
    static let gapBelowMenuBar: CGFloat = 6

    var isShown: Bool { self.isVisible }

    init() {
        // Non-activating: the first click inside lands on its control instead of only activating the app.
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.isFloatingPanel = true
        self.level = .popUpMenu
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.becomesKeyOnlyIfNeeded = false
        self.animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Wraps `content` in the single surface: Liquid Glass on macOS 26, a solid window fill when
    /// Reduce Transparency is on, and the popover material on older systems.
    func setContent(_ content: NSView, size: NSSize) {
        content.translatesAutoresizingMaskIntoConstraints = true
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]
        let surface: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView(frame: content.frame)
            solid.wantsLayer = true
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            solid.layer?.cornerRadius = Self.cornerRadius
            solid.layer?.cornerCurve = .continuous
            solid.layer?.masksToBounds = true
            solid.addSubview(content)
            surface = solid
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = content
            glass.autoresizingMask = [.width, .height]
            // The glass composites after the window server has measured the shadow, so on its own the
            // shadow takes the full rectangle and leaves dark wedges outside the rounded corners. A
            // near-invisible rounded fill under it gives the shadow the right shape from the first frame.
            let backing = NSView(frame: content.frame)
            backing.wantsLayer = true
            backing.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.02).cgColor
            backing.layer?.cornerRadius = Self.cornerRadius
            backing.layer?.cornerCurve = .continuous
            backing.layer?.masksToBounds = true
            backing.addSubview(glass)
            surface = backing
        } else {
            let material = NSVisualEffectView(frame: content.frame)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = Self.cornerRadius
            material.layer?.cornerCurve = .continuous
            material.layer?.masksToBounds = true
            material.addSubview(content)
            surface = material
        }
        self.contentView = surface
        self.setContentSize(size)
    }

    /// The screen rect of `rect` in `view` and the visible frame of its screen.
    static func anchor(_ rect: NSRect, in view: NSView) -> (anchor: NSRect, visible: NSRect?)? {
        guard let window = view.window else { return nil }
        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        return (anchor, screen?.visibleFrame)
    }

    /// Room between the gap under the menu bar and the Dock (or screen bottom), less an 8pt margin.
    static func availableHeight(under anchor: NSRect, in visible: NSRect?) -> CGFloat {
        guard let visible else { return .greatestFiniteMagnitude }
        let top = min(anchor.minY, visible.maxY) - Self.gapBelowMenuBar
        return max(160, top - visible.minY - 8)
    }

    /// Resizes to the content's height while keeping the top edge pinned under the menu bar.
    func fit(height: CGFloat) {
        let height = height.rounded()
        guard height > 0, abs(height - self.frame.height) >= 0.5 else { return }
        var frame = self.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        self.setFrame(frame, display: true)
        self.refreshShadow()
    }

    /// The window server takes the shadow's shape from the window's alpha at the moment it is asked.
    /// Asked before the glass has drawn, it sees a full rectangle and leaves dark wedges in the rounded
    /// corners, so draw first and ask again on the next turn of the run loop.
    private func refreshShadow() {
        self.displayIfNeeded()
        self.invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.display()
            self.invalidateShadow()
        }
    }

    /// Hangs the panel under `rect` in `view`, centred on it and kept inside the screen's visible frame.
    func show(relativeTo rect: NSRect, of view: NSView, makeKey: Bool) {
        if let (anchor, visible) = Self.anchor(rect, in: view) {
            self.setFrameOrigin(Self.origin(for: self.frame.size, under: anchor, in: visible))
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            self.setFrameOrigin(NSPoint(x: frame.maxX - self.frame.width - 8, y: frame.maxY - self.frame.height - Self.gapBelowMenuBar))
        }
        if makeKey { self.makeKeyAndOrderFront(nil) } else { self.orderFrontRegardless() }
        self.refreshShadow()
        self.installMonitors()
    }

    static func origin(for size: NSSize, under anchor: NSRect, in visible: NSRect?) -> NSPoint {
        var x = anchor.midX - size.width / 2
        if let visible {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        let top = min(anchor.minY, visible?.maxY ?? anchor.minY) - Self.gapBelowMenuBar
        // Never below the Dock: the content is sized to fit, and this guards any rounding left over.
        let y = max(top - size.height, (visible?.minY ?? -.greatestFiniteMagnitude) + 8)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    override func performClose(_ sender: Any?) {
        self.close(dismissingClick: nil)
    }

    private func close(dismissingClick: Int?) {
        guard self.isVisible else { return }
        self.removeMonitors()
        self.orderOut(nil)
        self.onClose?(dismissingClick)
    }

    override func resignKey() {
        super.resignKey()
        // Clicking another app or window dismisses the panel, as a menu would. Remember which in-app
        // click did it: if it was the status button, its action must not reopen the panel.
        let event = NSApp.currentEvent
        let isMouseDown = event.map { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains($0.type) } ?? false
        self.close(dismissingClick: isMouseDown ? event?.eventNumber : nil)
    }

    /// True when `event` belongs to the click recorded as `dismissingClick` (its down or its up).
    static func isDismissingClick(_ event: NSEvent?, dismissingClick: Int?) -> Bool {
        guard let event, let dismissingClick,
              [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
              .contains(event.type) else { return false }
        return event.eventNumber == dismissingClick
    }

    override func cancelOperation(_ sender: Any?) {
        self.performClose(sender)
    }

    private func installMonitors() {
        self.removeMonitors()
        self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self || (event.window == nil && self.isKeyWindow) else { return event }
            return self.handleKey?(event) == true ? nil : event
        }
        // Global monitors only see other apps' events, so clicks inside AgentMeter are untouched.
        self.outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            // Other apps' clicks can never reach our status button, so there is nothing to ignore later.
            self?.close(dismissingClick: nil)
        }
    }

    private func removeMonitors() {
        for monitor in [self.outsideClickMonitor, self.keyMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        self.outsideClickMonitor = nil
        self.keyMonitor = nil
    }
}
