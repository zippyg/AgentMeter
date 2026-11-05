import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    func startAutomaticBackgroundWork(reason: String) {
        guard self.startupBehavior.automaticallyStartsBackgroundWork, self.sessionIsActive else { return }
        TTYCommandRunner.resumeActiveProcessesAfterSessionActivation()
        self.hydrateCachedTokenSnapshots()
        self.detectVersions()
        self.updateProviderRuntimes()
        Task { @MainActor [weak self] in
            self?.schedulePathDebugInfoRefresh()
        }
        LoginShellPathCache.shared.captureOnce { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePathDebugInfoRefresh()
            }
        }
        Task { @MainActor [weak self] in
            await self?.refreshHistoricalDatasetIfNeeded()
        }
        Task { await self.refresh() }
        self.startTimer()
        self.startTokenTimer()
    }

    func configureSessionActivityMonitoring() {
        self.sessionActivityMonitor?.start { [weak self] active, reason in
            self?.handleSessionActivityChanged(active: active, reason: reason)
        }
    }

    func handleSessionActivityChanged(active: Bool, reason: String) {
        guard self.sessionIsActive != active else { return }
        self.sessionIsActive = active
        self.sessionActivityGeneration &+= 1
        if active {
            self.scheduleSessionActivationRefresh(reason: reason)
        } else {
            self.quiesceInactiveSession(reason: reason)
        }
    }

    private func scheduleSessionActivationRefresh(reason: String) {
        self.sessionActivationTask?.cancel()
        let generation = self.sessionActivityGeneration
        self.sessionActivationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.sessionIsActive,
                  generation == self.sessionActivityGeneration
            else { return }
            self.startAutomaticBackgroundWork(reason: reason)
        }
    }

    func quiesceInactiveSession(reason: String) {
        self.timerTask?.cancel()
        self.timerTask = nil
        self.tokenTimerTask?.cancel()
        self.tokenTimerTask = nil
        self.tokenRefreshSequenceTask?.cancel()
        self.tokenRefreshSequenceTask = nil
        self.versionDetectionTask?.cancel()
        self.versionDetectionTask = nil
        self.memoryPressureReliefTask?.cancel()
        self.memoryPressureReliefTask = nil
        self.startupConnectivityRetryTask?.cancel()
        self.startupConnectivityRetryTask = nil
        self.startupConnectivityRetryNeeded = false
        self.startupConnectivityRetryRefreshActive = false
        self.storageRefreshTask?.cancel()
        self.storageRefreshTask = nil
        self.storageRefreshGeneration &+= 1
        self.storageRefreshInFlightSignature = nil
        self.storageRefreshInFlightRequestKey = nil
        self.pathDebugRefreshTask?.cancel()
        self.pathDebugRefreshTask = nil
        self.codexPlanHistoryBackfillTask?.cancel()
        self.codexPlanHistoryBackfillTask = nil
        self.sessionActivationTask?.cancel()
        self.sessionActivationTask = nil
        self.invalidateOpenAIDashboardRefreshTask()
        self.providerRefreshTaskGeneration &+= 1
        self.providerRefreshWaiterGeneration &+= 1
        for states in self.providerRefreshTasks.values {
            for state in states {
                state.cancelTask()
            }
        }
        self.providerRefreshTasks.removeAll()
        self.latestProviderRefreshGenerations.removeAll()
        self.providerRefreshCounts.removeAll()
        self.refreshingProviders.removeAll()
        self.tokenRefreshInFlight.removeAll()
        self.stopProviderRuntimes()
        self.terminateTTYProcessesForSessionQuiesce()
        self.providerLogger.info(
            "Quiesced inactive user session",
            metadata: ["reason": reason])
    }

    func stopProviderRuntimes() {
        for (provider, runtime) in self.providerRuntimes {
            let context = ProviderRuntimeContext(provider: provider, settings: self.settings, store: self)
            runtime.stop(context: context)
        }
    }
}
