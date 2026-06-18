import AppKit
import CodexBarCore
import Foundation

struct StatusItemVisibilitySnapshot: Equatable {
    let isVisible: Bool
    let hasButton: Bool
    let hasWindow: Bool
    let hasScreen: Bool
    let isOnCurrentScreen: Bool
    let isOnMainScreen: Bool
    let isInMainScreenFrame: Bool
    let isInMenuExtraRegion: Bool
    let buttonWidth: CGFloat
    let windowHeight: CGFloat

    init(
        isVisible: Bool,
        hasButton: Bool,
        hasWindow: Bool,
        hasScreen: Bool,
        isOnCurrentScreen: Bool = true,
        isOnMainScreen: Bool = true,
        isInMainScreenFrame: Bool = true,
        isInMenuExtraRegion: Bool = true,
        buttonWidth: CGFloat,
        windowHeight: CGFloat = 24)
    {
        self.isVisible = isVisible
        self.hasButton = hasButton
        self.hasWindow = hasWindow
        self.hasScreen = hasScreen
        self.isOnCurrentScreen = isOnCurrentScreen
        self.isOnMainScreen = isOnMainScreen
        self.isInMainScreenFrame = isInMainScreenFrame
        self.isInMenuExtraRegion = isInMenuExtraRegion
        self.buttonWidth = buttonWidth
        self.windowHeight = windowHeight
    }
}

extension StatusItemVisibilitySnapshot: CustomStringConvertible {
    var description: String {
        "visible=\(self.isVisible),button=\(self.hasButton),window=\(self.hasWindow),"
            + "screen=\(self.hasScreen),currentScreen=\(self.isOnCurrentScreen),"
            + "mainScreen=\(self.isOnMainScreen),"
            + "mainFrame=\(self.isInMainScreenFrame),"
            + "menuExtraRegion=\(self.isInMenuExtraRegion),"
            + "width=\(String(format: "%.1f", Double(self.buttonWidth))),"
            + "height=\(String(format: "%.1f", Double(self.windowHeight)))"
    }
}

@MainActor
func isStatusItemBlocked(_ item: NSStatusItem) -> Bool {
    MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: MenuBarVisibilityWatcher.visibilitySnapshot(item))
}

enum MenuBarVisibilityWatcher {
    static let guidanceShownKey = "hasShownTahoeAllowListGuidance"
    static let guidanceLastShownAtKey = "tahoeAllowListGuidanceLastShownAt"
    static let guidanceRepeatInterval: TimeInterval = 24 * 60 * 60
    static let startupFreshnessInterval: TimeInterval = 10
    static let startupCheckDelay: TimeInterval = 6
    static let watchdogInterval: Duration = .seconds(10)
    static let screenChangeCheckDelay: Duration = .milliseconds(750)
    static let menuExtraVerticalBandPadding: CGFloat = 44
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.MenuBarSettings")!

    @MainActor
    static func visibilitySnapshot(_ item: NSStatusItem) -> StatusItemVisibilitySnapshot {
        let screen = item.button?.window?.screen
        let windowFrame = item.button?.window?.frame
        let windowHeight = item.button?.window?.frame.size.height ?? 0
        return StatusItemVisibilitySnapshot(
            isVisible: item.isVisible,
            hasButton: item.button != nil,
            hasWindow: item.button?.window != nil,
            hasScreen: screen != nil,
            isOnCurrentScreen: screen.map(self.isCurrentScreen) ?? false,
            isOnMainScreen: screen.map(self.isMainScreen) ?? false,
            isInMainScreenFrame: windowFrame.map(self.isInMainScreenFrame) ?? false,
            isInMenuExtraRegion: windowFrame.map { frame in
                self.isInMenuExtraRegion(frame: frame, screen: screen)
            } ?? false,
            buttonWidth: item.button?.frame.size.width ?? 0,
            windowHeight: windowHeight)
    }

    @MainActor
    private static func isCurrentScreen(_ screen: NSScreen) -> Bool {
        let screenNumber = self.screenNumber(screen)
        return NSScreen.screens.contains { candidate in
            if let screenNumber, let candidateNumber = self.screenNumber(candidate) {
                return candidateNumber == screenNumber
            }
            return candidate === screen
        }
    }

    @MainActor
    private static func isMainScreen(_ screen: NSScreen) -> Bool {
        guard let mainScreen = NSScreen.main else { return true }
        let screenNumber = self.screenNumber(screen)
        let mainScreenNumber = self.screenNumber(mainScreen)
        if let screenNumber, let mainScreenNumber {
            return screenNumber == mainScreenNumber
        }
        return screen === mainScreen
    }

    @MainActor
    private static func isInMainScreenFrame(_ frame: CGRect) -> Bool {
        guard let mainFrame = NSScreen.main?.frame else { return true }
        return mainFrame.intersects(frame) && mainFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private static func isInMenuExtraRegion(frame: CGRect, screen: NSScreen?) -> Bool {
        guard let screenFrame = screen?.frame ?? NSScreen.main?.frame else { return true }
        return self.isFrameInVisibleMenuExtraRegion(frame: frame, screenFrame: screenFrame)
    }

    static func isFrameInVisibleMenuExtraRegion(frame: CGRect, screenFrame: CGRect) -> Bool {
        guard frame.width > 0,
              frame.height >= 0,
              screenFrame.intersects(frame)
        else {
            return false
        }
        let verticalBand = max(self.menuExtraVerticalBandPadding, frame.height + 12)
        let isHorizontallyOnScreen = frame.midX >= screenFrame.minX && frame.midX <= screenFrame.maxX
        let isNearTopMenuBar = frame.midY >= screenFrame.maxY - verticalBand
            && frame.midY <= screenFrame.maxY + verticalBand
        return isHorizontallyOnScreen && isNearTopMenuBar
    }

    private static func screenNumber(_ screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    static func isBlockedSnapshot(snapshot: StatusItemVisibilitySnapshot) -> Bool {
        guard snapshot.isVisible else { return false }
        guard snapshot.hasButton else { return true }
        return !snapshot.hasWindow || snapshot.buttonWidth <= 0
    }

    static func isDisplacedSnapshot(snapshot: StatusItemVisibilitySnapshot) -> Bool {
        guard snapshot.isVisible,
              snapshot.hasButton,
              snapshot.hasWindow,
              snapshot.buttonWidth > 0,
              snapshot.windowHeight > 0
        else {
            return false
        }
        return !snapshot.hasScreen
            || !snapshot.isOnCurrentScreen
    }

    static func hasBlockedVisibleSnapshots(_ snapshots: [StatusItemVisibilitySnapshot]) -> Bool {
        let visibleItems = snapshots.filter(\.isVisible)
        guard !visibleItems.isEmpty else { return false }
        return visibleItems.allSatisfy { snapshot in
            self.isBlockedSnapshot(snapshot: snapshot)
        }
    }

    static func hasAnyBlockedVisibleSnapshot(_ snapshots: [StatusItemVisibilitySnapshot]) -> Bool {
        snapshots.contains { snapshot in
            snapshot.isVisible && self.isBlockedSnapshot(snapshot: snapshot)
        }
    }

    static func hasAnyDisplacedVisibleSnapshot(_ snapshots: [StatusItemVisibilitySnapshot]) -> Bool {
        snapshots.contains { snapshot in
            self.isDisplacedSnapshot(snapshot: snapshot)
        }
    }

    static func hasAnySystemBlockCandidate(
        snapshots: [StatusItemVisibilitySnapshot],
        windowSnapshots: [MenuBarStatusItemWindowSnapshot] = [],
        detectTahoeBlockedProxy: Bool = false)
        -> Bool
    {
        if self.hasAnyBlockedVisibleSnapshot(snapshots) {
            return true
        }
        return detectTahoeBlockedProxy && windowSnapshots.contains(where: \.isTahoeBlockedProxy)
    }

    static func missingVisibleWindowAutosaveNames(
        visibleAutosaveNames: [String],
        windowSnapshots: [MenuBarStatusItemWindowSnapshot])
        -> [String]
    {
        let materializedNames = Set(windowSnapshots
            .filter { $0.isOnscreen && $0.isWithinDisplayBounds }
            .map(\.name))
        return visibleAutosaveNames
            .filter { !materializedNames.contains($0) }
    }

    /// Whether AppKit itself reports the status item as a materialized, on-screen menu-bar window.
    /// Used to veto window recovery when the CoreGraphics name probe is unreliable (recent macOS
    /// redacts window names), so a healthy item is not recreated every watchdog tick.
    static func statusItemAppearsMaterialized(_ snapshot: StatusItemVisibilitySnapshot) -> Bool {
        snapshot.hasWindow && snapshot.hasScreen && snapshot.isInMenuExtraRegion
    }

    @MainActor
    static func visibilitySnapshots(_ items: [NSStatusItem]) -> [StatusItemVisibilitySnapshot] {
        items.map { item in
            self.visibilitySnapshot(item)
        }
    }

    @MainActor
    static func hasBlockedVisibleStatusItems(_ items: [NSStatusItem]) -> Bool {
        self.hasBlockedVisibleSnapshots(self.visibilitySnapshots(items))
    }

    static func shouldSurfaceStartupGuidance(
        appLaunchedAt: Date,
        now: Date = Date(),
        snapshots: [StatusItemVisibilitySnapshot],
        windowSnapshots: [MenuBarStatusItemWindowSnapshot] = [],
        detectTahoeBlockedProxy: Bool = false)
        -> Bool
    {
        guard now.timeIntervalSince(appLaunchedAt) <= self.startupFreshnessInterval else { return false }
        return self.hasAnySystemBlockCandidate(
            snapshots: snapshots,
            windowSnapshots: windowSnapshots,
            detectTahoeBlockedProxy: detectTahoeBlockedProxy)
    }

    static func shouldSurfaceScreenChangeGuidance(snapshots: [StatusItemVisibilitySnapshot]) -> Bool {
        self.hasAnyBlockedVisibleSnapshot(snapshots)
    }

    static func shouldShowGuidance(defaults: UserDefaults, now: Date = Date()) -> Bool {
        guard defaults.bool(forKey: self.guidanceShownKey) else { return true }
        let lastShownAt = defaults.double(forKey: self.guidanceLastShownAtKey)
        guard lastShownAt > 0 else { return false }
        return now.timeIntervalSince1970 - lastShownAt >= self.guidanceRepeatInterval
    }

    static func markGuidanceShown(defaults: UserDefaults, now: Date = Date()) {
        defaults.set(true, forKey: self.guidanceShownKey)
        defaults.set(now.timeIntervalSince1970, forKey: self.guidanceLastShownAtKey)
    }

    @MainActor
    static func presentGuidance(
        defaults: UserDefaults,
        now: Date = Date(),
        openURL: (URL) -> Void = { NSWorkspace.shared.open($0) })
    {
        self.markGuidanceShown(defaults: defaults, now: now)

        let alert = NSAlert()
        alert.messageText = "\(AgentMeterProductIdentity.displayName) can't show its menu bar icon"
        alert.informativeText = L(
            "macOS Tahoe can block menu bar apps in System Settings → Menu Bar → Allow in the Menu Bar. "
                + "\(AgentMeterProductIdentity.displayName) is running, but macOS may be hiding its icon. "
                + "Open Menu Bar settings and turn \(AgentMeterProductIdentity.displayName) on.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Menu Bar Settings"))
        alert.addButton(withTitle: L("Dismiss"))

        if alert.runModal() == .alertFirstButtonReturn {
            openURL(self.settingsURL)
        }
    }
}

extension StatusItemController {
    func startMenuBarVisibilityWatchdog() {
        guard !SettingsStore.isRunningTests else { return }
        self.menuBarVisibilityWatchdogTask?.cancel()
        self.menuBarVisibilityWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: MenuBarVisibilityWatcher.watchdogInterval)
                } catch {
                    return
                }
                self?.refreshNativeMenuBarVisibilityFromWatchdog()
            }
        }
    }

    private func refreshNativeMenuBarVisibilityFromWatchdog() {
        let snapshots = MenuBarVisibilityWatcher.visibilitySnapshots(self.startupVisibilityStatusItems)
        let windowSnapshots = self.statusItemWindowSnapshots()
        let signature = snapshots.map(\.description).joined(separator: " | ")
        let needsUserGuidance = MenuBarVisibilityWatcher.hasAnyBlockedVisibleSnapshot(snapshots)
        let changed = self.lastMenuBarVisibilityWatchdogSignature != signature
        self.lastMenuBarVisibilityWatchdogSignature = signature
        if self.recoverMissingStatusItemWindowsIfNeeded(
            reason: "watchdog",
            windowSnapshots: windowSnapshots)
        {
            return
        }
        if changed || needsUserGuidance {
            self.writeStatusItemDiagnostics(reason: "periodic-visibility-watchdog")
        }
        self.surfaceMenuBarVisibilityGuidanceIfNeeded(
            reason: "watchdog",
            snapshots: snapshots,
            windowSnapshots: windowSnapshots,
            now: Date())
    }

    func scheduleStartupStatusItemVisibilityCheck(appLaunchedAt: Date = Date()) {
        guard !SettingsStore.isRunningTests else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + MenuBarVisibilityWatcher.startupCheckDelay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkStartupStatusItemVisibility(appLaunchedAt: appLaunchedAt)
            }
        }
    }

    private func checkStartupStatusItemVisibility(appLaunchedAt: Date, now: Date = Date()) {
        self.writeStatusItemDiagnostics(reason: "startup-visibility-check")
        let snapshots = MenuBarVisibilityWatcher.visibilitySnapshots(self.startupVisibilityStatusItems)
        let windowSnapshots = self.statusItemWindowSnapshots()
        if self.recoverMissingStatusItemWindowsIfNeeded(
            reason: "startup",
            windowSnapshots: windowSnapshots)
        {
            return
        }
        guard MenuBarVisibilityWatcher.shouldSurfaceStartupGuidance(
            appLaunchedAt: appLaunchedAt,
            now: now,
            snapshots: snapshots,
            windowSnapshots: windowSnapshots,
            detectTahoeBlockedProxy: self.canDetectTahoeBlockedProxy)
        else {
            return
        }

        self.menuLogger.error(
            "Status item failed to materialize or remained detached",
            metadata: [
                "snapshots": snapshots.map(\.description).joined(separator: " | "),
                "windows": self.statusItemWindowDiagnosticsDescription(windowSnapshots),
            ])
        self.surfaceMenuBarVisibilityGuidanceIfNeeded(
            reason: "startup",
            snapshots: snapshots,
            windowSnapshots: windowSnapshots,
            now: now)
    }

    @objc func handleScreenParametersDidChange(_: Notification) {
        let previousScreenCount = max(
            self.pendingScreenChangePreviousCount ?? self.lastKnownScreenCount,
            self.lastKnownScreenCount)
        let currentScreenCount = NSScreen.screens.count
        self.pendingScreenChangePreviousCount = previousScreenCount
        self.lastKnownScreenCount = currentScreenCount
        self.scheduleScreenChangeStatusItemVisibilityCheck(
            previousScreenCount: previousScreenCount,
            currentScreenCount: currentScreenCount)
    }

    private func scheduleScreenChangeStatusItemVisibilityCheck(
        previousScreenCount: Int,
        currentScreenCount: Int)
    {
        guard !SettingsStore.isRunningTests else { return }
        self.screenChangeVisibilityTask?.cancel()
        self.screenChangeVisibilityTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: MenuBarVisibilityWatcher.screenChangeCheckDelay)
            } catch {
                return
            }
            self?.checkScreenChangeStatusItemVisibility(
                previousScreenCount: previousScreenCount,
                currentScreenCount: currentScreenCount)
        }
    }

    private func checkScreenChangeStatusItemVisibility(previousScreenCount: Int, currentScreenCount: Int) {
        self.pendingScreenChangePreviousCount = nil
        self.writeStatusItemDiagnostics(reason: "screen-change-visibility-check")
        let settledCurrentScreenCount = NSScreen.screens.count
        self.lastKnownScreenCount = settledCurrentScreenCount
        let snapshots = MenuBarVisibilityWatcher.visibilitySnapshots(self.startupVisibilityStatusItems)
        let windowSnapshots = self.statusItemWindowSnapshots()
        if self.recoverMissingStatusItemWindowsIfNeeded(
            reason: "screen-change",
            windowSnapshots: windowSnapshots)
        {
            return
        }
        if MenuBarVisibilityWatcher.shouldSurfaceScreenChangeGuidance(snapshots: snapshots) {
            self.menuLogger.error(
                "Display configuration changed and status item appears blocked",
                metadata: [
                    "previousScreenCount": "\(previousScreenCount)",
                    "currentScreenCount": "\(settledCurrentScreenCount)",
                    "capturedScreenCount": "\(currentScreenCount)",
                    "snapshots": snapshots.map(\.description).joined(separator: " | "),
                    "windows": self.statusItemWindowDiagnosticsDescription(),
                ])
            self.surfaceMenuBarVisibilityGuidanceIfNeeded(
                reason: "screen-change",
                snapshots: snapshots,
                windowSnapshots: windowSnapshots,
                now: Date())
        }
    }

    private func surfaceMenuBarVisibilityGuidanceIfNeeded(
        reason: String,
        snapshots: [StatusItemVisibilitySnapshot],
        windowSnapshots: [MenuBarStatusItemWindowSnapshot],
        now: Date)
    {
        let hasSystemBlockCandidate = MenuBarVisibilityWatcher.hasAnySystemBlockCandidate(
            snapshots: snapshots,
            windowSnapshots: windowSnapshots,
            detectTahoeBlockedProxy: self.canDetectTahoeBlockedProxy)
        guard hasSystemBlockCandidate else { return }
        guard #available(macOS 26.0, *),
              MenuBarVisibilityWatcher.shouldShowGuidance(defaults: self.settings.userDefaults, now: now)
        else { return }
        self.writeStatusItemDiagnostics(reason: "\(reason)-visibility-guidance")
        MenuBarVisibilityWatcher.presentGuidance(defaults: self.settings.userDefaults, now: now)
    }

    private var startupVisibilityStatusItems: [NSStatusItem] {
        self.visibilityRecoveryStatusItems
    }

    private var canDetectTahoeBlockedProxy: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    private func statusItemWindowSnapshots() -> [MenuBarStatusItemWindowSnapshot] {
        let names = Set(self.startupVisibilityStatusItems.compactMap { item in
            item.autosaveName.isEmpty ? nil : item.autosaveName
        })
        return MenuBarStatusItemWindowProbe.snapshots(matching: names)
    }

    private func statusItemWindowDiagnosticsDescription(
        _ snapshots: [MenuBarStatusItemWindowSnapshot]? = nil)
        -> String
    {
        let snapshots = snapshots ?? self.statusItemWindowSnapshots()
        guard !snapshots.isEmpty else { return "none" }
        return snapshots.map(\.description).joined(separator: " | ")
    }

    private func visibleStatusItemAutosaveNames() -> [String] {
        self.startupVisibilityStatusItems.compactMap { item in
            guard item.isVisible, !item.autosaveName.isEmpty else { return nil }
            return item.autosaveName
        }
    }

    private func recoverMissingStatusItemWindowsIfNeeded(
        reason: String,
        windowSnapshots: [MenuBarStatusItemWindowSnapshot])
        -> Bool
    {
        let missingNames = MenuBarVisibilityWatcher.missingVisibleWindowAutosaveNames(
            visibleAutosaveNames: self.visibleStatusItemAutosaveNames(),
            windowSnapshots: windowSnapshots)
        guard !missingNames.isEmpty else { return false }
        return self.recoverMissingMergedStatusItemWindow(
            reason: reason,
            missingAutosaveNames: missingNames,
            windowDiagnostics: self.statusItemWindowDiagnosticsDescription(windowSnapshots))
    }
}
