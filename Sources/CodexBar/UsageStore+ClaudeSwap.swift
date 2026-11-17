import CodexBarCore
import Foundation

extension UsageStore {
    /// Read the switcher's existing cache during its normal refresh, with no extra provider polling.
    static func readUsagePoolClaudeCache(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> [UsagePoolForecast.Account]
    {
        let root = home.appendingPathComponent(".claude-swap-backup")
        do {
            var accounts = try UsagePoolClaudeCache.accounts(
                usage: Data(contentsOf: root.appendingPathComponent("cache/usage.json")),
                sequence: Data(contentsOf: root.appendingPathComponent("sequence.json")),
                umbrella: Data(contentsOf: root.appendingPathComponent("umbrella.json")),
                umbrellaState: try? Data(contentsOf: root.appendingPathComponent("umbrella-state.json")), now: now)
            let resets = ClaudeSwapLimitResets.cached(home: home, now: now)
            for index in accounts.indices { accounts[index].claudeLimitResets = resets[accounts[index].id] }
            return accounts
        } catch { return [] }
    }

    /// Re-reads the switcher's files whenever its state folder changes, so the active login follows a
    /// switch within a moment. No provider polling: these are the same local files read at refresh.
    func startClaudeSwapStateWatch(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard self.claudeSwapStateWatcher == nil else { return }
        self.claudeSwapStateWatcher = ClaudeSwapStateWatcher(
            directory: home.appendingPathComponent(".claude-swap-backup")) { [weak self] in
            Task { @MainActor [weak self] in self?.reloadUsagePoolClaudeCache(home: home) }
        }
    }

    func reloadUsagePoolClaudeCache(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard self.isEnabled(.claude) else { return }
        self.usagePoolClaudeAccounts = Self.readUsagePoolClaudeCache(home: home)
    }

    private func startClaudeGrantRefresh() {
        guard (!SettingsStore.isRunningTests || self._test_claudeGrantRefresh != nil),
              self.claudeGrantRefreshTask == nil else { return }
        let manual = ProviderInteractionContext.current == .userInitiated
        let fetch = self._test_claudeGrantRefresh
        self.claudeGrantRefreshTask = Task { [weak self] in
            if let fetch {
                await fetch()
            } else {
                await ClaudeSwapLimitResets.refresh(home: FileManager.default.homeDirectoryForCurrentUser, manual: manual)
                self?.reloadUsagePoolClaudeCache()
            }
            self?.claudeGrantRefreshTask = nil
        }
    }

    /// A present but failing feed stays separate from the CLI login's legacy provider state.
    func refreshClaudeSwapAccounts(generation: UInt64?) async -> Bool {
        do {
            let accounts: [AgentMeterProviderSnapshot]? = if let fetch = self._test_claudeSwapFetch {
                try await fetch()
            } else if SettingsStore.isRunningTests {
                nil
            } else {
                try await ClaudeSwapUsage.fetch()
            }
            guard self.isCurrentProviderRefreshGeneration(.claude, generation: generation) else { return true }
            let hadFeed = self.claudeSwapAccounts != nil
            self.claudeSwapAccounts = accounts?.isEmpty == false ? accounts : nil
            self.usagePoolClaudeAccounts = SettingsStore.isRunningTests ? [] : Self.readUsagePoolClaudeCache()
            guard let accounts = self.claudeSwapAccounts else {
                if hadFeed { self.snapshots.removeValue(forKey: .claude) }
                return false
            }
            self.startClaudeGrantRefresh()
            // Only the explicitly active account may supply the single-provider icon/legacy widget.
            self.snapshots[.claude] = accounts.first { $0.isActiveCLI == true && $0.status == .ok }?
                .claudeSwapUsageSnapshot
            self.errors[.claude] = nil
            self.lastSourceLabels[.claude] = "claude-swap"
            self.failureGates[.claude]?.reset()
            self.persistWidgetSnapshot(reason: "claude-swap")
            self.persistUsageExport()
            for account in accounts where account.status == .ok {
                guard let accountKey = account.accountID else { continue }
                guard self.isCurrentProviderRefreshGeneration(.claude, generation: generation) else { return true }
                await self.recordPlanUtilizationHistorySample(
                    provider: .claude,
                    snapshot: account.claudeSwapUsageSnapshot,
                    accountKeyOverride: accountKey,
                    shouldUpdatePreferredAccountKey: false,
                    shouldAdoptUnscopedHistory: false,
                    now: account.updatedAt)
            }
            return true
        } catch {
            guard self.isCurrentProviderRefreshGeneration(.claude, generation: generation) else { return true }
            let now = Date()
            let message = "claude-swap feed unavailable. Retry refresh."
            self.usagePoolClaudeAccounts = SettingsStore.isRunningTests ? [] : Self.readUsagePoolClaudeCache()
            self.claudeSwapAccounts = self.claudeSwapAccounts?.map {
                $0.withStatus(
                    $0.status == .unavailable ? .unavailable : .stale,
                    staleAfter: now,
                    lastError: message,
                    clearCLIActivity: true)
            } ?? [AgentMeterProviderSnapshot(
                id: "claude:cswap:unavailable",
                displayName: "Claude",
                providerID: "claude",
                windows: [],
                source: AgentMeterSourceDescriptor(confidence: .local, label: "claude-swap"),
                status: .error,
                updatedAt: now,
                staleAfter: now,
                lastError: message)]
            self.snapshots.removeValue(forKey: .claude)
            self.errors[.claude] = message
            self.persistWidgetSnapshot(reason: "claude-swap-error")
            return true
        }
    }

    func claudeSwapSnapshot(_ snapshot: AgentMeterSnapshot, nextRefreshAt: Date?) -> AgentMeterSnapshot {
        guard self.enabledProvidersForDisplay().contains(.claude), let accounts = self.claudeSwapAccounts else {
            return snapshot
        }
        return AgentMeterSnapshot(
            snapshotSequence: snapshot.snapshotSequence,
            generatedAt: snapshot.generatedAt,
            producer: snapshot.producer,
            providers: snapshot.providers.filter { $0.usageProviderID != "claude" } + accounts.map {
                $0.withStatus($0.status, nextRefreshAt: nextRefreshAt, lastError: $0.lastError)
            })
    }
}
