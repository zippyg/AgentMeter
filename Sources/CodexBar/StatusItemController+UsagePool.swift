import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    func attachUsagePool(to item: NSStatusItem) {
        item.menu = nil
        item.button?.target = self
        item.button?.action = #selector(self.toggleUsagePool(_:))
    }

    @objc func toggleUsagePool(_ sender: Any?) {
        self.showUsagePool(sender)
    }

    private func showUsagePool(_ sender: Any?, forQA: Bool = false) {
        guard !self.hasPreparedForAppShutdown else { return }
        if self.usagePoolPanel?.isShown == true {
            self.usagePoolPanel?.performClose(sender)
            return
        }
        // The click on the status button that made the panel resign key must not reopen it. Only that
        // exact click is ignored: a later click, or the keyboard shortcut, opens the panel at once.
        let dismissingClick = self.usagePoolDismissingClick
        self.usagePoolDismissingClick = nil
        if UsagePoolPanel.isDismissingClick(NSApp.currentEvent, dismissingClick: dismissingClick) { return }
        guard let button = sender as? NSStatusBarButton ?? self.statusItem.button else { return }
        // Opening always reflects claude-swap's current login, even if a change event was missed.
        if !SettingsStore.isRunningTests { self.store.reloadUsagePoolClaudeCache() }
        self.refreshUsagePoolPresentation()
        let panel = self.makeUsagePoolPanel()
        self.usagePoolPanel = panel
        panel.onClose = { [weak self, weak panel] dismissingClick in
            guard let self, let panel, self.usagePoolPanel === panel else { return }
            self.usagePoolPanel = nil
            self.usagePoolDismissingClick = dismissingClick
        }
        let available = UsagePoolPanel.anchor(button.bounds, in: button)
            .map { UsagePoolPanel.availableHeight(under: $0.anchor, in: $0.visible) } ?? 680
        let root = UsagePoolPopoverView(
            state: self.usagePoolPresentation,
            maxHeight: min(680, available),
            refresh: { [weak self] in self?.refreshNow() },
            settings: { [weak self] in
                self?.usagePoolPanel?.performClose(nil)
                self?.showSettingsGeneral()
            },
            privacyChanged: { [weak self] in self?.settings.hidePersonalInfo = $0 })
        let host = UsagePoolKeyView(rootView: root)
        host.handleKey = { [weak self] event in self?.handleUsagePoolKey(event) ?? false }
        host.sizingOptions = [.intrinsicContentSize]
        host.onIntrinsicSizeChange = { [weak panel, weak host] in
            guard let panel, let host else { return }
            panel.fit(height: host.intrinsicContentSize.height)
        }
        panel.handleKey = host.handleKey
        // One layout pass measures the content, so the panel opens at its final height.
        host.frame = NSRect(x: 0, y: 0, width: 380, height: min(680, available))
        host.layoutSubtreeIfNeeded()
        panel.setContent(host, size: NSSize(width: 380, height: host.fittingSize.height))
        if !forQA { NSApp.activate(ignoringOtherApps: true) }
        panel.show(relativeTo: button.bounds, of: button, makeKey: !forQA)
        if !forQA {
            panel.makeFirstResponder(host)
        } else {
            fputs("AgentMeter QA pool window: \(panel.windowNumber)\n", stderr)
        }
    }

    /// QA only: AGENTMETER_QA_POPOVER_TAB=overview|claude|codex|analytics opens after startup
    /// without activation, clicks or synthesized keys. Release builds also require AGENTMETER_QA_ALLOW=1.
    /// Unset or invalid values have no effect.
    static func qaPopoverTab(environment: [String: String]) -> UsagePoolViewModel.Tab? {
        #if !DEBUG
        guard environment["AGENTMETER_QA_ALLOW"] == "1" else { return nil }
        #endif
        guard let value = environment["AGENTMETER_QA_POPOVER_TAB"]?.lowercased() else { return nil }
        return UsagePoolViewModel.Tab.allCases.first { $0.rawValue.lowercased() == value }
    }

    /// QA only, alongside the tab: AGENTMETER_QA_ANALYTICS_RANGE=today|7d|30d|month picks the analytics range.
    static func qaAnalyticsRange(environment: [String: String]) -> AllAccountsDashboardModel.Window? {
        guard self.qaPopoverTab(environment: environment) != nil,
              let value = environment["AGENTMETER_QA_ANALYTICS_RANGE"]?.lowercased() else { return nil }
        if value == "month" { return .month }
        return AllAccountsDashboardModel.Window.allCases.first { $0.rawValue.lowercased() == value }
    }

    /// QA only, alongside the tab: AGENTMETER_QA_POPOVER_SEQUENCE=claude,analytics,reopen:analytics,... runs
    /// one step every AGENTMETER_QA_STEP_SECONDS (default 8): a tab name switches the open panel, and
    /// reopen:<tab> closes it and opens it again on that tab. Each step prints its window number.
    static func qaPopoverSequence(environment: [String: String])
        -> (steps: [(reopen: Bool, tab: UsagePoolViewModel.Tab)], interval: Double)
    {
        guard self.qaPopoverTab(environment: environment) != nil,
              let value = environment["AGENTMETER_QA_POPOVER_SEQUENCE"] else { return ([], 8) }
        let steps = value.lowercased().split(separator: ",").compactMap { item -> (reopen: Bool, tab: UsagePoolViewModel.Tab)? in
            let reopen = item.hasPrefix("reopen:")
            let name = reopen ? item.dropFirst("reopen:".count) : item[...]
            return UsagePoolViewModel.Tab.allCases.first { $0.rawValue.lowercased() == name }.map { (reopen, $0) }
        }
        let interval = environment["AGENTMETER_QA_STEP_SECONDS"].flatMap(Double.init).map { max(1, $0) } ?? 8
        return (steps, interval)
    }

    private func runQAPopoverSequence(_ sequence: (steps: [(reopen: Bool, tab: UsagePoolViewModel.Tab)], interval: Double)) {
        for (index, step) in sequence.steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + sequence.interval * Double(index + 1)) { [weak self] in
                guard let self, !self.hasPreparedForAppShutdown else { return }
                if step.reopen { self.usagePoolPanel?.performClose(nil) }
                self.usagePoolPresentation.tab = step.tab
                if step.reopen || self.usagePoolPanel == nil { self.showUsagePool(nil, forQA: true) }
                fputs("AgentMeter QA step \(index + 1): \(step.reopen ? "reopen " : "")\(step.tab.rawValue) window "
                    + "\(self.usagePoolPanel?.windowNumber ?? 0)\n", stderr)
            }
        }
    }

    func scheduleQAPopoverIfRequested() {
        guard !SettingsStore.isRunningTests,
              let tab = Self.qaPopoverTab(environment: ProcessInfo.processInfo.environment) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.hasPreparedForAppShutdown else { return }
            if let range = Self.qaAnalyticsRange(environment: ProcessInfo.processInfo.environment) {
                self.usagePoolPresentation.analyticsWindow = range
            }
            self.usagePoolPresentation.tab = tab
            self.showUsagePool(nil, forQA: true)
            self.runQAPopoverSequence(Self.qaPopoverSequence(environment: ProcessInfo.processInfo.environment))
        }
        // QA evidence for the banked reset list: the source's own count and each credit's status and expiry.
        // No identifiers, tokens or account details are printed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, let credits = self.store.snapshot(for: .codex)?.codexResetCredits else {
                fputs("AgentMeter QA resets: no reset credit data\n", stderr)
                return
            }
            let rows = (credits.credits ?? []).map { credit in
                "\(credit.status ?? "unknown") expires \(credit.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")"
            }
            fputs("AgentMeter QA resets: available_count \(credits.availableCount.map(String.init) ?? "none"); "
                + "\(rows.joined(separator: "; ")); shown \(self.usagePoolPresentation.model.bankedResetCount)\n", stderr)
        }
        // QA evidence for the Analytics coverage lines, which sit below the fold: counts only, no paths.
        DispatchQueue.main.asyncAfter(deadline: .now() + 50) { [weak self] in
            guard let self else { return }
            let lines = self.usagePoolPresentation.scanStatus.map(UsagePoolPresentation.scanStatusText)
            fputs("AgentMeter QA scan: \(lines.isEmpty ? "no scan yet" : lines.joined(separator: " | "))\n", stderr)
        }
    }

    func refreshUsagePoolPresentation(now: Date = Date()) {
        self.usagePoolPresentation.hideNames = self.settings.hidePersonalInfo
        self.usagePoolPresentation.refreshing = self.store.isRefreshing
        self.usagePoolPresentation.update(
            accounts: self.store.isEnabled(.claude) ? self.store.usagePoolClaudeAccounts : [],
            codex: self.store.isEnabled(.codex) ? self.store.snapshot(for: .codex) : nil,
            sources: self.store.allAccountsUsageSources(now: now),
            claudeSnapshot: self.store.isEnabled(.claude) ? self.store.snapshot(for: .claude) : nil,
            labels: self.store.claudeSubscriptionLabels(), accountKeyGroups: Array(ClaudeSwapUsage.accountKeys().values), now: now,
            codexCredits: self.store.isEnabled(.codex)
                ? self.store.codexConsumerProjection(surface: .liveCard, now: now).credits?.snapshot : nil,
            creditsPurchaseURL: self.store.openAIDashboard?.creditsPurchaseURL
                ?? self.store.metadata(for: .codex).dashboardURL,
            codexAccounts: self.store.isEnabled(.codex) ? self.store.usagePoolCodexSnapshots() : [])
        if let button = self.statusItem.button { self.applyUsagePoolMenuBarTooltip(to: button) }
        for item in self.statusItems.values {
            if let button = item.button { self.applyUsagePoolMenuBarTooltip(to: button) }
        }
    }

    func handleUsagePoolKey(_ event: NSEvent) -> Bool {
        self.usagePoolPresentation.handleKey(
            event, refresh: { self.refreshNow() },
            close: { self.usagePoolPanel?.performClose(nil) }, settings: { self.showSettingsGeneral() })
    }

    func applyUsagePoolMenuBarTooltip(to button: NSStatusBarButton) {
        let title = self.usagePoolPresentation.model.menuBarText
        let spokenTitle = title.replacingOccurrences(of: " •", with: ", a Codex reset expires within 24 hours")
        button.setAccessibilityValue("Next action: \(spokenTitle)")
        button.toolTip = "AgentMeter · \(title)"
    }
}

/// Hosts the pool view. The panel's key monitor handles keys first; these overrides cover
/// events delivered straight to the view.
final class UsagePoolKeyView: NSHostingView<UsagePoolPopoverView> {
    var handleKey: ((NSEvent) -> Bool)?
    /// Tab changes and refreshes change the content height; the panel follows on the next turn.
    var onIntrinsicSizeChange: (() -> Void)?
    private var sizeChangePending = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard self.onIntrinsicSizeChange != nil, !self.sizeChangePending else { return }
        self.sizeChangePending = true
        // Resizing the window inside SwiftUI's layout pass would re-enter it.
        DispatchQueue.main.async { [weak self] in
            self?.sizeChangePending = false
            self?.onIntrinsicSizeChange?()
        }
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    // A click in the panel while another app is frontmost acts at once instead of only focusing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        if self.handleKey?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if self.handleKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
