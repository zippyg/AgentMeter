import CodexBarCore
import Foundation

extension UsageStore {
    func tokenSnapshot(for provider: UsageProvider) -> CostUsageTokenSnapshot? {
        self.tokenSnapshots[provider]
    }

    func tokenError(for provider: UsageProvider) -> String? {
        self.tokenErrors[provider]
    }

    func tokenLastAttemptAt(for provider: UsageProvider) -> Date? {
        self.lastTokenFetchAt[provider]
    }

    @discardableResult
    func hydrateCachedTokenSnapshots(
        now: Date = Date(), directory: URL = SharedCostUsage.directory,
        codexHomePaths: [String]? = nil) -> Task<Void, Never>?
    {
        guard self.sessionIsActive else { return nil }
        guard self.settings.costUsageEnabled else { return nil }
        // Own daily counters are small and already attributed. Show them while the full
        // transcript scan waits behind other providers on the serial scan executor.
        Task { @MainActor [weak self] in
            let sources = await Task.detached(priority: .utility) {
                Self.readOwnCostSources(directory: directory, now: now)
            }.value
            guard let self, self.sessionIsActive, self.settings.costUsageEnabled else { return }
            self.cachedOwnCostSources = sources
        }
        guard self.settings.enabledProvidersOrdered(metadataByProvider: self.providerMetadata).contains(.codex) else {
            return nil
        }

        guard let homes = try? codexHomePaths ?? self.settings.codexCostHomePaths(environment: self.environmentBase)
        else { return nil }
        let scope = self.tokenCostScope(for: .codex)
        let historyDays = self.settings.costUsageHistoryDays
        return Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.tokenSnapshots[.codex] == nil else { return }
            guard let snapshot = await self.costUsageFetcher.loadCachedCodexTokenSnapshot(
                now: now,
                historyDays: historyDays,
                codexHomePaths: homes)
            else {
                return
            }
            guard self.settings.costUsageEnabled,
                  self.sessionIsActive,
                  self.isEnabled(.codex),
                  self.tokenCostScope(for: .codex) == scope,
                  self.tokenSnapshots[.codex] == nil
            else {
                return
            }
            self.tokenSnapshots[.codex] = snapshot
            self.tokenErrors[.codex] = nil
        }
    }

    func isTokenRefreshInFlight(for provider: UsageProvider) -> Bool {
        self.tokenRefreshInFlight.contains(provider)
    }

    func tokenCostScope(for provider: UsageProvider) -> String {
        guard provider == .codex else { return provider.rawValue }
        // Local usage history belongs to this Mac, independent of the selected login.
        let homes = try? self.settings.codexCostHomePaths(environment: self.environmentBase)
        return "codex:mac:\(homes?.joined(separator: "|") ?? "unreadable")"
    }

    func tokenSnapshot(
        fromProviderSnapshot snapshot: UsageSnapshot?,
        provider: UsageProvider)
        -> CostUsageTokenSnapshot?
    {
        switch provider {
        case .openai:
            snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot()
        case .mistral:
            snapshot?.mistralUsage?.toCostUsageTokenSnapshot(historyDays: self.settings.costUsageHistoryDays)
        default:
            nil
        }
    }

    nonisolated static func tokenCostRequiresProviderSnapshot(_ provider: UsageProvider) -> Bool {
        switch provider {
        case .mistral, .openai:
            true
        default:
            false
        }
    }

    nonisolated static func costUsageCacheDirectory(
        fileManager: FileManager = .default) -> URL
    {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cost-usage", isDirectory: true)
    }

    func clearCostUsageCache() async -> String? {
        let errorMessage: String? = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let cacheDirs = [
                Self.costUsageCacheDirectory(fileManager: fm),
            ]

            for cacheDir in cacheDirs {
                do {
                    try fm.removeItem(at: cacheDir)
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain, error.code == NSFileNoSuchFileError { continue }
                    return error.localizedDescription
                }
            }
            return nil
        }.value

        guard errorMessage == nil else { return errorMessage }

        self.tokenSnapshots.removeAll()
        self.tokenErrors.removeAll()
        self.lastTokenFetchAt.removeAll()
        self.lastTokenFetchScope.removeAll()
        self.tokenFailureGates[.codex]?.reset()
        self.tokenFailureGates[.claude]?.reset()
        return nil
    }

    nonisolated static func tokenCostNoDataMessage(for provider: UsageProvider) -> String {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.noDataMessage()
    }
}
