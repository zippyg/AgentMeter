import Foundation

enum ClaudeStatusLineUsageCacheError: LocalizedError, Sendable {
    case missing(URL)
    case missingModificationDate(URL)
    case stale(URL, TimeInterval)
    case invalid(URL)

    var errorDescription: String? {
        switch self {
        case let .missing(url):
            "Claude status-line usage cache is missing at \(url.path)."
        case let .missingModificationDate(url):
            "Claude status-line usage cache has no modification date at \(url.path)."
        case let .stale(url, age):
            "Claude status-line usage cache is stale at \(url.path) (age \(Int(age))s)."
        case let .invalid(url):
            "Claude status-line usage cache is invalid at \(url.path)."
        }
    }
}

enum ClaudeStatusLineUsageCache {
    static let overridePathEnvironmentKey = "AGENTMETER_CLAUDE_STATUSLINE_CACHE"
    static let maxAge: TimeInterval = 10 * 60

    static func cacheURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[self.overridePathEnvironmentKey]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        let home = environment["HOME"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".usage-cache.json")
    }

    static func isFresh(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        fileManager: FileManager = .default)
        -> Bool
    {
        (try? self.modificationDate(
            environment: environment,
            now: now,
            fileManager: fileManager)) != nil
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        fileManager: FileManager = .default)
        throws -> ClaudeUsageSnapshot
    {
        let cacheURL = self.cacheURL(environment: environment)
        let updatedAt = try self.modificationDate(
            environment: environment,
            now: now,
            fileManager: fileManager)
        let data: Data
        do {
            data = try Data(contentsOf: cacheURL)
        } catch {
            throw ClaudeStatusLineUsageCacheError.missing(cacheURL)
        }
        let usage = try ClaudeOAuthUsageFetcher.decodeUsageResponse(data)
        return try self.snapshot(from: usage, updatedAt: updatedAt, cacheURL: cacheURL)
    }

    private static func modificationDate(
        environment: [String: String],
        now: Date,
        fileManager: FileManager)
        throws -> Date
    {
        let cacheURL = self.cacheURL(environment: environment)
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            throw ClaudeStatusLineUsageCacheError.missing(cacheURL)
        }
        let attributes = try fileManager.attributesOfItem(atPath: cacheURL.path)
        guard let modifiedAt = attributes[.modificationDate] as? Date else {
            throw ClaudeStatusLineUsageCacheError.missingModificationDate(cacheURL)
        }
        let age = max(0, now.timeIntervalSince(modifiedAt))
        guard age <= self.maxAge else {
            throw ClaudeStatusLineUsageCacheError.stale(cacheURL, age)
        }
        return modifiedAt
    }

    private static func snapshot(
        from usage: OAuthUsageResponse,
        updatedAt: Date,
        cacheURL: URL)
        throws -> ClaudeUsageSnapshot
    {
        let primary = self.window(usage.fiveHour, minutes: 5 * 60)
            ?? self.window(usage.sevenDay, minutes: 7 * 24 * 60)
            ?? self.window(usage.sevenDayOAuthApps, minutes: 7 * 24 * 60)
            ?? self.window(usage.sevenDaySonnet, minutes: 7 * 24 * 60)
            ?? self.window(usage.sevenDayOpus, minutes: 7 * 24 * 60)
        guard let primary else {
            throw ClaudeStatusLineUsageCacheError.invalid(cacheURL)
        }
        let secondary = self.window(usage.sevenDay, minutes: 7 * 24 * 60)
        let modelSpecific = self.window(
            usage.sevenDaySonnet ?? usage.sevenDayOpus,
            minutes: 7 * 24 * 60)
        return ClaudeUsageSnapshot(
            primary: primary,
            secondary: secondary,
            opus: modelSpecific,
            extraRateWindows: self.extraRateWindows(from: usage),
            providerCost: self.extraUsageCost(usage.extraUsage, updatedAt: updatedAt),
            updatedAt: updatedAt,
            accountEmail: nil,
            accountOrganization: nil,
            loginMethod: "Claude status-line cache",
            rawText: nil)
    }

    private static func window(_ window: OAuthUsageWindow?, minutes: Int) -> RateWindow? {
        guard let utilization = window?.utilization else { return nil }
        let resetDate = ClaudeOAuthUsageFetcher.parseISO8601Date(window?.resetsAt)
        return RateWindow(
            usedPercent: utilization,
            windowMinutes: minutes,
            resetsAt: resetDate,
            resetDescription: resetDate.map(self.formatResetDate))
    }

    private static func extraRateWindows(from usage: OAuthUsageResponse) -> [NamedRateWindow] {
        guard let routines = self.window(usage.sevenDayRoutines, minutes: 7 * 24 * 60) else {
            return []
        }
        return [NamedRateWindow(id: "claude-routines", title: "Daily Routines", window: routines)]
    }

    private static func extraUsageCost(_ extra: OAuthExtraUsage?, updatedAt: Date) -> ProviderCostSnapshot? {
        guard let extra, extra.isEnabled == true,
              let used = extra.usedCredits,
              let limit = extra.monthlyLimit
        else { return nil }
        let currency = extra.currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderCostSnapshot(
            used: used / 100,
            limit: limit / 100,
            currencyCode: (currency?.isEmpty ?? true) ? "USD" : currency!,
            period: "Monthly cap",
            resetsAt: nil,
            updatedAt: updatedAt)
    }

    private static func formatResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d 'at' h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
