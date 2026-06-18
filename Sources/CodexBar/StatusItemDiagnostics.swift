import AppKit
import CodexBarCore
import Foundation

struct StatusItemDiagnosticsPayload: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let reason: String
    let bundleIdentifier: String
    let displayName: String
    let mergeIcons: Bool
    let enabledProviders: [String]
    let launchedFromCodexShell: Bool
    let xpcServiceName: String?
    let launchAtLogin: Bool
    let loginItemStatus: String
    let items: [StatusItemDiagnosticsItem]
}

struct StatusItemDiagnosticsItem: Codable, Equatable {
    let identity: String
    let provider: String?
    let autosaveName: String
    let isVisible: Bool
    let hasButton: Bool
    let buttonWidth: Double
    let buttonHeight: Double
    let statusItemLength: Double
    let hasImage: Bool
    let imageWidth: Double?
    let imageHeight: Double?
    let imageIsTemplate: Bool?
    let imagePosition: String
    let titleLength: Int
    let toolTip: String?
    let accessibilityIdentifier: String?
    let hasWindow: Bool
    let hasScreen: Bool
    let isOnMainScreen: Bool
    let isInMainScreenFrame: Bool
    let isInMenuExtraRegion: Bool
    let isBlocked: Bool
    let isDisplaced: Bool
    let windowX: Double?
    let windowY: Double?
    let windowWidth: Double?
    let windowHeight: Double?
    let windowProbe: [String]
}

@MainActor
enum StatusItemDiagnosticsWriter {
    static var fileURLOverrideForTesting: URL?

    static func fileURL() -> URL {
        if let override = self.fileURLOverrideForTesting {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("AgentMeter", isDirectory: true)
            .appendingPathComponent("status-item-diagnostics.json")
    }

    static func save(_ payload: StatusItemDiagnosticsPayload) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            let url = self.fileURL()
            try AgentMeterFileSecurity.ensurePrivateDirectory(
                url.deletingLastPathComponent(),
                repairExistingPermissions: self.fileURLOverrideForTesting == nil)
            try data.write(to: url, options: .atomic)
            try AgentMeterFileSecurity.applyPrivateFilePermissions(url)
        } catch {
            CodexBarLog.logger(LogCategories.app).warning(
                "Failed to write status item diagnostics: \(error.localizedDescription)")
        }
    }
}

extension StatusItemController {
    func writeStatusItemDiagnostics(reason: String) {
        let items = self.statusItemDiagnosticsItems()
        let env = ProcessInfo.processInfo.environment
        let launchedFromCodexShell = env["CODEX_SHELL"] != nil
            || env["CODEX_THREAD_ID"] != nil
            || env["CODEX_INTERNAL_ORIGINATOR_OVERRIDE"] != nil
        let payload = StatusItemDiagnosticsPayload(
            schemaVersion: 3,
            generatedAt: Date(),
            reason: reason,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? AgentMeterProductIdentity.bundleIdentifier,
            displayName: AgentMeterProductIdentity.displayName,
            mergeIcons: self.shouldMergeIcons,
            enabledProviders: self.store.enabledProvidersForDisplay().map(\.rawValue),
            launchedFromCodexShell: launchedFromCodexShell,
            xpcServiceName: env["XPC_SERVICE_NAME"],
            launchAtLogin: self.settings.launchAtLogin,
            loginItemStatus: LaunchAtLoginManager.currentStatusDescription(),
            items: items)
        StatusItemDiagnosticsWriter.save(payload)
    }

    private func statusItemDiagnosticsItems() -> [StatusItemDiagnosticsItem] {
        var entries: [(identity: StatusItemIdentity, item: NSStatusItem)] = [
            (.merged, self.statusItem),
        ]
        for provider in self.statusItems.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let item = self.statusItems[provider] {
                entries.append((.provider(provider), item))
            }
        }

        let names = Set(entries.compactMap { entry in
            entry.item.autosaveName.isEmpty ? nil : entry.item.autosaveName
        })
        let windowSnapshots = Dictionary(grouping: MenuBarStatusItemWindowProbe.snapshots(matching: names), by: \.name)

        return entries.map { entry in
            self.statusItemDiagnosticsItem(
                identity: entry.identity,
                item: entry.item,
                windowSnapshots: windowSnapshots[entry.item.autosaveName] ?? [])
        }
    }

    private func statusItemDiagnosticsItem(
        identity: StatusItemIdentity,
        item: NSStatusItem,
        windowSnapshots: [MenuBarStatusItemWindowSnapshot])
        -> StatusItemDiagnosticsItem
    {
        let snapshot = MenuBarVisibilityWatcher.visibilitySnapshot(item)
        let button = item.button
        let image = button?.image
        let windowFrame = button?.window?.frame
        let materializedWindow = windowSnapshots.first { window in
            window.isOnscreen && window.isWithinDisplayBounds
        }
        let effectiveWindowFrame = materializedWindow?.bounds ?? windowFrame
        let effectiveHasWindow = snapshot.hasWindow || materializedWindow != nil
        let effectiveHasScreen = snapshot.hasScreen || materializedWindow?.displayBounds != nil
        let effectiveInMainFrame = materializedWindow.map(\.isWithinDisplayBounds)
            ?? snapshot.isInMainScreenFrame
        let effectiveInMenuExtraRegion = materializedWindow.map { $0.isOnscreen && $0.isWithinDisplayBounds }
            ?? snapshot.isInMenuExtraRegion
        return StatusItemDiagnosticsItem(
            identity: identity.diagnosticsName,
            provider: identity.diagnosticsProvider,
            autosaveName: item.autosaveName,
            isVisible: item.isVisible,
            hasButton: button != nil,
            buttonWidth: Double(button?.frame.size.width ?? 0),
            buttonHeight: Double(button?.frame.size.height ?? 0),
            statusItemLength: Double(item.length),
            hasImage: image != nil,
            imageWidth: image.map { Double($0.size.width) },
            imageHeight: image.map { Double($0.size.height) },
            imageIsTemplate: image.map(\.isTemplate),
            imagePosition: button.map { String(describing: $0.imagePosition) } ?? "none",
            titleLength: button?.title.count ?? 0,
            toolTip: button?.toolTip,
            accessibilityIdentifier: button?.accessibilityIdentifier(),
            hasWindow: effectiveHasWindow,
            hasScreen: effectiveHasScreen,
            isOnMainScreen: snapshot.isOnMainScreen,
            isInMainScreenFrame: effectiveInMainFrame,
            isInMenuExtraRegion: effectiveInMenuExtraRegion,
            isBlocked: MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot),
            isDisplaced: MenuBarVisibilityWatcher.isDisplacedSnapshot(snapshot: snapshot),
            windowX: effectiveWindowFrame.map { Double($0.origin.x) },
            windowY: effectiveWindowFrame.map { Double($0.origin.y) },
            windowWidth: effectiveWindowFrame.map { Double($0.size.width) },
            windowHeight: effectiveWindowFrame.map { Double($0.size.height) },
            windowProbe: windowSnapshots.map(\.description).sorted())
    }
}

extension StatusItemController.StatusItemIdentity {
    fileprivate var diagnosticsName: String {
        switch self {
        case .merged:
            "merged"
        case let .provider(provider):
            "provider-\(provider.rawValue)"
        }
    }

    fileprivate var diagnosticsProvider: String? {
        switch self {
        case .merged:
            nil
        case let .provider(provider):
            provider.rawValue
        }
    }
}
