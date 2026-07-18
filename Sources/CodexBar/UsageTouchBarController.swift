import AppKit
import CodexBarCore
import Observation

/// Provides an app-wide macOS Touch Bar that surfaces live usage for the
/// primary coding assistants (Claude, Codex, and Cursor).
///
/// AgentMeter is a menu-bar agent with no persistent key window, so the Touch
/// Bar is installed directly on `NSApp` (`NSResponder.touchBar`). macOS shows an
/// app's Touch Bar only while that app is frontmost, so these controls appear
/// when AgentMeter is the active application (for example while its menu or a
/// window is in focus) on Macs equipped with a Touch Bar. Each provider button
/// shows the most-constrained usage lane and tapping it triggers a refresh.
@MainActor
final class UsageTouchBarController: NSObject {
    private let store: UsageStore
    private let settings: SettingsStore

    /// Providers shown on the Touch Bar, in display order.
    private let providers: [UsageProvider] = [.claude, .codex, .cursor]

    private var touchBar: NSTouchBar?
    private var providerButtons: [UsageProvider: NSButton] = [:]

    init(store: UsageStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        super.init()
    }

    /// Builds the Touch Bar, installs it as the application-wide Touch Bar, and
    /// begins observing usage changes so the labels stay current.
    func install() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.customizationIdentifier = Self.customizationIdentifier
        bar.defaultItemIdentifiers = self.defaultItemIdentifiers
        bar.customizationAllowedItemIdentifiers = self.defaultItemIdentifiers
        self.touchBar = bar
        NSApp.touchBar = bar

        self.observeStoreChanges()
        self.refreshLabels()
    }

    // MARK: - Identifiers

    private static let customizationIdentifier = NSTouchBar.CustomizationIdentifier(
        "com.agentmeter.touchbar.usage")

    private static func providerItemIdentifier(_ provider: UsageProvider)
        -> NSTouchBarItem.Identifier
    {
        NSTouchBarItem.Identifier("com.agentmeter.touchbar.provider.\(provider.rawValue)")
    }

    private static let refreshItemIdentifier = NSTouchBarItem.Identifier(
        "com.agentmeter.touchbar.refresh")

    private var defaultItemIdentifiers: [NSTouchBarItem.Identifier] {
        var identifiers = self.providers.map(Self.providerItemIdentifier)
        identifiers.append(.flexibleSpace)
        identifiers.append(Self.refreshItemIdentifier)
        return identifiers
    }

    // MARK: - Observation

    private func observeStoreChanges() {
        withObservationTracking {
            _ = self.store.iconObservationToken
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeStoreChanges()
                self.refreshLabels()
            }
        }
    }

    private func refreshLabels() {
        for provider in self.providers {
            guard let button = self.providerButtons[provider] else { continue }
            button.title = self.displayText(for: provider)
        }
    }

    // MARK: - Text

    private func displayText(for provider: UsageProvider) -> String {
        let name = self.shortName(for: provider)
        guard let snapshot = self.store.snapshot(for: provider) else {
            return "\(name) —"
        }

        if let percent = self.mostConstrainedUsedPercent(in: snapshot) {
            return "\(name) \(Int(percent.rounded()))%"
        }

        if let cost = snapshot.providerCost {
            let amount = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            return "\(name) \(amount)"
        }

        return "\(name) —"
    }

    private func mostConstrainedUsedPercent(in snapshot: UsageSnapshot) -> Double? {
        let windows = [snapshot.primary, snapshot.secondary, snapshot.tertiary]
            .compactMap(\.self)
        guard !windows.isEmpty else { return nil }
        return windows.map(\.usedPercent).max()
    }

    private func shortName(for provider: UsageProvider) -> String {
        switch provider {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .cursor:
            return "Cursor"
        default:
            return self.store.metadata(for: provider).displayName
        }
    }

    // MARK: - Actions

    @objc private func handleRefreshTapped(_ sender: Any?) {
        Task { @MainActor in
            await self.store.refresh()
        }
    }
}

extension UsageTouchBarController: NSTouchBarDelegate {
    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem?
    {
        if identifier == Self.refreshItemIdentifier {
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(
                image: NSImage(
                    systemSymbolName: "arrow.clockwise",
                    accessibilityDescription: "Refresh usage") ?? NSImage(),
                target: self,
                action: #selector(self.handleRefreshTapped(_:)))
            item.view = button
            item.customizationLabel = "Refresh"
            return item
        }

        for provider in self.providers where identifier == Self.providerItemIdentifier(provider) {
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(
                title: self.displayText(for: provider),
                target: self,
                action: #selector(self.handleRefreshTapped(_:)))
            button.bezelStyle = .rounded
            self.providerButtons[provider] = button
            item.view = button
            item.customizationLabel = self.shortName(for: provider)
            return item
        }

        return nil
    }
}
