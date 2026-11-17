import CodexBarCore
import Foundation

extension StatusItemController {
    private nonisolated static let menuBarCountdownRefreshEpsilon: TimeInterval = 0.05

    func scheduleMenuBarCountdownRefreshIfNeeded(now: Date = .init()) {
        self.menuBarCountdownRefreshTask?.cancel()
        self.menuBarCountdownRefreshTask = nil

        let legacyCountdown = self.settings.menuBarShowsBrandIconWithPercent &&
            self.settings.menuBarDisplayMode == .resetTime && self.settings.resetTimeDisplayStyle == .countdown
        let hasPool = !self.usagePoolPresentation.model.results.isEmpty || self.usagePoolPresentation.codexAccounts.count > 1
        guard legacyCountdown || hasPool else { return }

        let resetDates = self.menuBarCountdownProviders().compactMap { provider in
            self.menuBarMetricWindow(
                for: provider,
                snapshot: self.store.snapshot(for: provider))?.resetsAt
        }
        let legacyDelay = legacyCountdown ? Self.menuBarCountdownRefreshDelay(resetDates: resetDates, now: now) : nil
        let poolDelay = hasPool ? Self.usagePoolRefreshDelay(
            accounts: self.usagePoolPresentation.codexAccounts, now: now) : nil
        guard let delay = [legacyDelay, poolDelay].compactMap({ $0 }).min() else { return }

        self.menuBarCountdownRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.menuBarCountdownRefreshTask = nil
            self.refreshUsagePoolPresentation()
            self.updateIcons()
        }
    }

    nonisolated static func usagePoolRefreshDelay(accounts: [UsagePoolForecast.Account], now: Date) -> TimeInterval {
        let nextReset = accounts.flatMap { account in
            [account.session?.resetsAt, account.weekly?.resetsAt].compactMap { $0 }
        }.filter { $0 > now }.map { $0.timeIntervalSince(now) + Self.menuBarCountdownRefreshEpsilon }.min()
        return min(60, nextReset ?? 60)
    }

    nonisolated static func menuBarCountdownRefreshDelay(
        resetDates: [Date],
        now: Date)
        -> TimeInterval?
    {
        resetDates.compactMap { resetDate -> TimeInterval? in
            let remaining = resetDate.timeIntervalSince(now)
            guard remaining > 0 else { return nil }
            let displayedMinutes = ceil(remaining / 60)
            let nextBoundaryRemaining = max(0, displayedMinutes - 1) * 60
            return max(
                self.menuBarCountdownRefreshEpsilon,
                remaining - nextBoundaryRemaining + self.menuBarCountdownRefreshEpsilon)
        }.min()
    }

    private func menuBarCountdownProviders() -> [UsageProvider] {
        if self.shouldMergeIcons {
            return [self.primaryProviderForUnifiedIcon()]
        }
        return UsageProvider.allCases.filter(self.isVisible)
    }

    #if DEBUG
    func _test_isMenuBarCountdownRefreshScheduled() -> Bool {
        self.menuBarCountdownRefreshTask != nil
    }
    #endif
}
