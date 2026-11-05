import CodexBarCore
import Foundation

extension UsageStore {
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
            guard let accounts = self.claudeSwapAccounts else {
                if hadFeed { self.snapshots.removeValue(forKey: .claude) }
                return false
            }
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
