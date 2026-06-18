import CoreGraphics
import Foundation
import Testing
@testable import AgentMeter

struct MenuBarVisibilityWatcherTests {
    @Test
    func `does not flag intentionally hidden status item`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: false,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 0)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `materialized menu-extra item is treated as present so recovery is vetoed`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isInMenuExtraRegion: true,
            buttonWidth: 24)

        #expect(MenuBarVisibilityWatcher.statusItemAppearsMaterialized(snapshot))
    }

    @Test
    func `windowless item is not treated as materialized so real recovery still runs`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 0)

        #expect(!MenuBarVisibilityWatcher.statusItemAppearsMaterialized(snapshot))
    }

    @Test
    func `item outside the menu-extra region is not treated as materialized`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isInMenuExtraRegion: false,
            buttonWidth: 24)

        #expect(!MenuBarVisibilityWatcher.statusItemAppearsMaterialized(snapshot))
    }

    @Test
    func `flags visible item without attached window`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `flags visible item without button`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: false,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 0)

        #expect(MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `flags visible item with zero width`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 0)

        #expect(MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `does not flag zero height backing window without corroborating block`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 57,
            windowHeight: 0)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
        #expect(!MenuBarVisibilityWatcher.isDisplacedSnapshot(snapshot: snapshot))
    }

    @Test
    func `allows visible item attached to a screen with width`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `menu extra region accepts item pinned against right screen edge`() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        #expect(MenuBarVisibilityWatcher.isFrameInVisibleMenuExtraRegion(
            frame: CGRect(x: 1892, y: 1058, width: 28, height: 22),
            screenFrame: screenFrame))
        #expect(MenuBarVisibilityWatcher.isFrameInVisibleMenuExtraRegion(
            frame: CGRect(x: 1760, y: 1058, width: 28, height: 22),
            screenFrame: screenFrame))
    }

    @Test
    func `menu extra region rejects item outside screen or away from menu bar`() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        #expect(!MenuBarVisibilityWatcher.isFrameInVisibleMenuExtraRegion(
            frame: CGRect(x: 1930, y: 1058, width: 28, height: 22),
            screenFrame: screenFrame))
        #expect(!MenuBarVisibilityWatcher.isFrameInVisibleMenuExtraRegion(
            frame: CGRect(x: 1760, y: 900, width: 28, height: 22),
            screenFrame: screenFrame))
    }

    @Test
    func `window probe matches autosave name and reports display bounds`() {
        let snapshots = MenuBarStatusItemWindowProbe.snapshots(
            matching: ["codexbar-merged"],
            windowInfo: [[
                kCGWindowName as String: "codexbar-merged",
                kCGWindowOwnerName as String: "Control Center",
                kCGWindowIsOnscreen as String: true,
                kCGWindowBounds as String: [
                    "X": 1680,
                    "Y": 0,
                    "Width": 70,
                    "Height": 24,
                ],
            ]],
            displayBounds: [CGRect(x: 0, y: 0, width: 2056, height: 1329)])

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.name == "codexbar-merged")
        #expect(snapshots.first?.ownerName == "Control Center")
        #expect(snapshots.first?.isOnscreen == true)
        #expect(snapshots.first?.isWithinDisplayBounds == true)
    }

    @Test
    func `window probe detects offscreen status item by bounds`() {
        let snapshots = MenuBarStatusItemWindowProbe.snapshots(
            matching: ["codexbar-merged"],
            windowInfo: [[
                kCGWindowName as String: "codexbar-merged",
                kCGWindowOwnerName as String: "Control Center",
                kCGWindowIsOnscreen as String: true,
                kCGWindowBounds as String: [
                    "X": 2023,
                    "Y": 0,
                    "Width": 71,
                    "Height": 24,
                ],
            ]],
            displayBounds: [CGRect(x: 0, y: 0, width: 2056, height: 1329)])

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.isOnscreen == true)
        #expect(snapshots.first?.isWithinDisplayBounds == false)
    }

    @Test
    func `window probe identifies Tahoe Control Center blocked proxy geometry`() {
        let snapshot = MenuBarStatusItemWindowSnapshot(
            name: "codexbar-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 0, y: -22, width: 76, height: 22),
            isOnscreen: true,
            displayBounds: nil)

        #expect(snapshot.isTahoeBlockedProxy)
    }

    @Test
    func `window probe accepts localized Control Centre owner name`() {
        let snapshot = MenuBarStatusItemWindowSnapshot(
            name: "com.zain.agentmeter.mac",
            ownerName: "Control Centre",
            bounds: CGRect(x: 0, y: -22, width: 76, height: 22),
            isOnscreen: true,
            displayBounds: nil)

        #expect(snapshot.isTahoeBlockedProxy)
    }

    @Test
    func `detects missing materialized window for visible autosave name`() {
        let missingNames = MenuBarVisibilityWatcher.missingVisibleWindowAutosaveNames(
            visibleAutosaveNames: ["com.zain.agentmeter.statusitem.v5-merged"],
            windowSnapshots: [])

        #expect(missingNames == ["com.zain.agentmeter.statusitem.v5-merged"])
    }

    @Test
    func `does not report missing autosave name when window is onscreen within display`() {
        let snapshots = [
            MenuBarStatusItemWindowSnapshot(
                name: "com.zain.agentmeter.statusitem.v5-merged",
                ownerName: "Control Centre",
                bounds: CGRect(x: 1266, y: 0, width: 28, height: 30),
                isOnscreen: true,
                displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        ]

        let missingNames = MenuBarVisibilityWatcher.missingVisibleWindowAutosaveNames(
            visibleAutosaveNames: ["com.zain.agentmeter.statusitem.v5-merged"],
            windowSnapshots: snapshots)

        #expect(missingNames.isEmpty)
    }

    @Test
    func `reports onscreen proxy outside display as missing materialized window`() {
        let snapshots = [
            MenuBarStatusItemWindowSnapshot(
                name: "com.zain.agentmeter.statusitem.v5-merged",
                ownerName: "Control Centre",
                bounds: CGRect(x: -654, y: 0, width: 28, height: 30),
                isOnscreen: true,
                displayBounds: nil),
        ]

        let missingNames = MenuBarVisibilityWatcher.missingVisibleWindowAutosaveNames(
            visibleAutosaveNames: ["com.zain.agentmeter.statusitem.v5-merged"],
            windowSnapshots: snapshots)

        #expect(missingNames == ["com.zain.agentmeter.statusitem.v5-merged"])
    }

    @Test
    func `window probe does not classify generic offscreen manager placement as Tahoe proxy`() {
        let snapshot = MenuBarStatusItemWindowSnapshot(
            name: "codexbar-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 2023, y: 0, width: 71, height: 24),
            isOnscreen: true,
            displayBounds: nil)

        #expect(!snapshot.isTahoeBlockedProxy)
    }

    @Test
    func `window probe does not classify stale hidden Control Center record as Tahoe proxy`() {
        let snapshot = MenuBarStatusItemWindowSnapshot(
            name: "codexbar-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 0, y: -22, width: 76, height: 22),
            isOnscreen: false,
            displayBounds: nil)

        #expect(!snapshot.isTahoeBlockedProxy)
    }

    @Test
    func `allows visible item attached to a detached screen`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `classifies detached live item as displaced but not blocked`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
        #expect(MenuBarVisibilityWatcher.isDisplacedSnapshot(snapshot: snapshot))
    }

    @Test
    func `classifies stale screen live item as displaced but not blocked`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
        #expect(MenuBarVisibilityWatcher.isDisplacedSnapshot(snapshot: snapshot))
    }

    @Test
    func `allows non main screen live item`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: true,
            isOnMainScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
        #expect(!MenuBarVisibilityWatcher.isDisplacedSnapshot(snapshot: snapshot))
    }

    @Test
    func `allows off main frame live item`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: true,
            isOnMainScreen: true,
            isInMainScreenFrame: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
        #expect(!MenuBarVisibilityWatcher.isDisplacedSnapshot(snapshot: snapshot))
    }

    @Test
    func `allows edge placed live item`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: true,
            isOnMainScreen: true,
            isInMainScreenFrame: true,
            isInMenuExtraRegion: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
        #expect(!MenuBarVisibilityWatcher.isDisplacedSnapshot(snapshot: snapshot))
    }

    @Test
    func `guidance shows once then repeats after a day`() throws {
        let defaults = try #require(UserDefaults(suiteName: "MenuBarVisibilityWatcherTests"))
        defaults.removePersistentDomain(forName: "MenuBarVisibilityWatcherTests")
        let now = Date(timeIntervalSince1970: 1000)

        #expect(MenuBarVisibilityWatcher.shouldShowGuidance(defaults: defaults, now: now))

        MenuBarVisibilityWatcher.markGuidanceShown(defaults: defaults, now: now)

        #expect(!MenuBarVisibilityWatcher.shouldShowGuidance(
            defaults: defaults,
            now: now.addingTimeInterval(MenuBarVisibilityWatcher.guidanceRepeatInterval - 1)))
        #expect(MenuBarVisibilityWatcher.shouldShowGuidance(
            defaults: defaults,
            now: now.addingTimeInterval(MenuBarVisibilityWatcher.guidanceRepeatInterval)))
    }

    @Test
    func `startup guidance triggers for blocked visible snapshot`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldSurfaceStartupGuidance(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [blocked]))
    }

    @Test
    func `startup guidance accepts detached Tahoe proxy corroborated by Control Center geometry`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let detachedProxy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 76)
        let blockedWindow = MenuBarStatusItemWindowSnapshot(
            name: "codexbar-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 0, y: -22, width: 76, height: 22),
            isOnscreen: true,
            displayBounds: nil)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: detachedProxy))
        #expect(MenuBarVisibilityWatcher.shouldSurfaceStartupGuidance(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [detachedProxy],
            windowSnapshots: [blockedWindow],
            detectTahoeBlockedProxy: true))
    }

    @Test
    func `startup guidance accepts Tahoe proxy even when AppKit reports attached zero height window`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let attachedZeroHeight = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: true,
            buttonWidth: 76,
            windowHeight: 0)
        let blockedWindow = MenuBarStatusItemWindowSnapshot(
            name: "com.zain.agentmeter.statusitem.v5-merged",
            ownerName: "Control Center",
            bounds: CGRect(x: 0, y: -22, width: 76, height: 22),
            isOnscreen: true,
            displayBounds: nil)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: attachedZeroHeight))
        #expect(MenuBarVisibilityWatcher.shouldSurfaceStartupGuidance(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [attachedZeroHeight],
            windowSnapshots: [blockedWindow],
            detectTahoeBlockedProxy: true))
    }

    @Test
    func `startup guidance ignores detached live item without Tahoe proxy corroboration`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let managed = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldSurfaceStartupGuidance(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [managed],
            detectTahoeBlockedProxy: true))
    }

    @Test
    func `startup guidance ignores live item attached to a stale screen`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let managed = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldSurfaceStartupGuidance(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [managed]))
    }

    @Test
    func `startup guidance triggers when one split status item is blocked`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldSurfaceStartupGuidance(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [healthy, blocked]))
    }

    @Test
    func `startup guidance ignores stale checks`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldSurfaceStartupGuidance(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(MenuBarVisibilityWatcher.startupFreshnessInterval + 1),
            snapshots: [blocked]))
    }

    @Test
    func `startup guidance ignores healthy visible snapshot`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldSurfaceStartupGuidance(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [healthy]))
    }

    @Test
    func `screen change guidance triggers for blocked status item without display count change`() {
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldSurfaceScreenChangeGuidance(snapshots: [blocked]))
    }

    @Test
    func `manager parked item with live window is not blocked`() {
        let managed = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.hasAnyBlockedVisibleSnapshot([managed]))
        #expect(MenuBarVisibilityWatcher.hasAnyDisplacedVisibleSnapshot([managed]))
    }

    @Test
    func `manager parked item with live window on stale screen is not blocked`() {
        let managed = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.hasAnyBlockedVisibleSnapshot([managed]))
        #expect(MenuBarVisibilityWatcher.hasAnyDisplacedVisibleSnapshot([managed]))
    }

    @Test
    func `item without window is blocked regardless of screen state`() {
        // A missing window cannot be caused by a manager parking the item; it signals
        // a genuine system block and must surface guidance.
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.hasAnyBlockedVisibleSnapshot([blocked]))
        #expect(!MenuBarVisibilityWatcher.hasAnyDisplacedVisibleSnapshot([blocked]))
    }

    @Test
    func `healthy item is neither blocked nor displaced`() {
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.hasAnyBlockedVisibleSnapshot([healthy]))
        #expect(!MenuBarVisibilityWatcher.hasAnyDisplacedVisibleSnapshot([healthy]))
    }
}
